import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const TZ = 'America/Sao_Paulo'
type Row = Record<string, unknown>
type Scope = 'BLACKSHEEP' | 'SABRINA' | null
type ReceivableCursor = { start_at: string; appointment_id: string }

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function clean(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function uuid(value: unknown, code: string): string {
  const id = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error(code)
  return id
}

function decodeReceivableCursor(value: unknown): ReceivableCursor | null {
  const raw = clean(value)
  if (!raw) return null
  try {
    const normalized = raw.replaceAll('-', '+').replaceAll('_', '/')
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')
    const parsed = JSON.parse(atob(padded)) as Row
    const startAt = clean(parsed?.start_at)
    const appointmentId = uuid(parsed?.appointment_id, 'FINANCE_CURSOR_INVALID')
    if (!startAt || !Number.isFinite(Date.parse(startAt))) throw new Error('FINANCE_CURSOR_INVALID')
    return { start_at: new Date(startAt).toISOString(), appointment_id: appointmentId }
  } catch {
    throw new Error('FINANCE_CURSOR_INVALID')
  }
}

function encodeReceivableCursor(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null
  const cursor = value as Row
  const startAt = clean(cursor.start_at)
  const appointmentId = clean(cursor.appointment_id)
  if (!startAt || !appointmentId) return null
  return btoa(JSON.stringify({ start_at: startAt, appointment_id: appointmentId }))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/g, '')
}

function month(value: unknown): string {
  const raw = clean(value) ?? ''
  if (!/^\d{4}-\d{2}$/.test(raw)) throw new Error('FINANCE_MONTH_INVALID')
  const [year, mon] = raw.split('-').map(Number)
  if (year < 2000 || mon < 1 || mon > 12) throw new Error('FINANCE_MONTH_INVALID')
  return raw
}

function monthFromInstant(value: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) throw new Error('FINANCE_PERIOD_INVALID')
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: TZ, year: 'numeric', month: '2-digit' }).formatToParts(parsed)
  const year = parts.find((part) => part.type === 'year')?.value
  const mon = parts.find((part) => part.type === 'month')?.value
  if (!year || !mon) throw new Error('FINANCE_PERIOD_INVALID')
  return `${year}-${mon}`
}

function selectedMonth(url: URL): string {
  const direct = clean(url.searchParams.get('month'))
  if (direct) return month(direct)
  const from = clean(url.searchParams.get('from')) ?? clean(url.searchParams.get('start_at'))
  const to = clean(url.searchParams.get('to')) ?? clean(url.searchParams.get('end_at'))
  if (!from || !to || !Number.isFinite(Date.parse(from)) || !Number.isFinite(Date.parse(to)) || Date.parse(to) <= Date.parse(from)) {
    throw new Error('FINANCE_PERIOD_INVALID')
  }
  return monthFromInstant(from)
}

function scope(value: unknown): Scope {
  const raw = clean(value)
  if (!raw || raw.toUpperCase() === 'ALL') return null
  const normalized = raw.toUpperCase()
  if (normalized !== 'BLACKSHEEP' && normalized !== 'SABRINA') throw new Error('FINANCE_OPERATION_SCOPE_INVALID')
  return normalized
}

function amount(value: unknown): number {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error('MANUAL_RECEIPT_AMOUNT_INVALID')
  return Math.round(parsed * 100) / 100
}

function refundAmount(value: unknown): number {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error('MANUAL_REFUND_AMOUNT_INVALID')
  return Math.round(parsed * 100) / 100
}

function paidAt(value: unknown): string | null {
  const raw = clean(value)
  if (!raw) return null
  const parsed = Date.parse(raw)
  if (!Number.isFinite(parsed)) throw new Error('MANUAL_RECEIPT_PAID_AT_INVALID')
  return new Date(parsed).toISOString()
}

function refundPaidAt(value: unknown): string | null {
  const raw = clean(value)
  if (!raw) return null
  const parsed = Date.parse(raw)
  if (!Number.isFinite(parsed)) throw new Error('MANUAL_REFUND_PAID_AT_INVALID')
  return new Date(parsed).toISOString()
}

function authorshipEvidence(req: Request) {
  const ip = (req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0] ?? '').trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  if (!ip || !userAgent || !requestId) throw new Error('MANUAL_REFUND_EVIDENCE_REQUIRED')
  return { ip, userAgent, requestId }
}

function csvCell(value: unknown): string {
  let raw = value == null ? '' : String(value)
  if (/^[=+\-@]/.test(raw)) raw = `'${raw}`
  return `"${raw.replaceAll('"', '""')}"`
}

function moneyBr(value: unknown): string {
  const parsed = Number(value ?? 0)
  return (Number.isFinite(parsed) ? parsed : 0).toFixed(2).replace('.', ',')
}

function nfseCsv(rows: Row[]): string {
  const header = ['Data', 'Código', 'Cliente', 'CPF/CNPJ', 'Endereço', 'E-mail', 'Serviço', 'Status atendimento', 'Valor contratado', 'Liquidado no contrato', 'Saldo a receber', 'Situação financeira', 'Forma de pagamento', 'Operação']
  const lines = rows.map((row) => [
    row.date,
    row.public_code,
    row.client,
    row.cpf_cnpj,
    row.address,
    row.email,
    row.service,
    row.appointment_status,
    moneyBr(row.value),
    moneyBr(row.contract_settled),
    moneyBr(row.outstanding),
    row.financial_status,
    row.payment_method,
    row.operation,
  ].map(csvCell).join(';'))
  return `\uFEFF${header.map(csvCell).join(';')}\r\n${lines.join('\r\n')}\r\n`
}

async function requirePermission(req: Request, permission: 'FINANCE_VIEW' | 'FINANCE_MANAGE') {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
  return admin
}

async function readRpc(name: string, args: Row) {
  const client = adminClient()
  const { data, error } = await client.rpc(name, args)
  if (error) throw new Error(error.message)
  return data
}

async function monthClose(adminId: string, selected: string, operationScope: Scope) {
  return await readRpc('service_admin_finance_month_close', {
    p_month: `${selected}-01`,
    p_operation_scope: operationScope,
    p_admin_id: adminId,
  }) as Row
}

async function manualReceipts(adminId: string, selected: string, operationScope: Scope) {
  return await readRpc('service_admin_list_manual_receipts', {
    p_month: `${selected}-01`,
    p_operation_scope: operationScope,
    p_admin_id: adminId,
  }) as { month?: string; operation_scope?: string | null; timezone?: string; receipts?: Row[] }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const url = new URL(req.url)

    if (req.method === 'GET') {
      const admin = await requirePermission(req, 'FINANCE_VIEW')
      const action = clean(url.searchParams.get('action'))?.toLowerCase()
      if (!action) throw new Error('FINANCE_ACTION_REQUIRED')
      const operationScope = scope(url.searchParams.get('operation_scope'))

      if (action === 'month_close' || action === 'closing') {
        const selected = selectedMonth(url)
        const data = await monthClose(admin.adminId, selected, operationScope)
        if (action === 'closing') return json({ ...data, services: [] })
        return json(data)
      }

      if (action === 'receivables') {
        const search = clean(url.searchParams.get('search'))
        const requestedLimit = Number(url.searchParams.get('limit') ?? 30)
        const limit = Number.isInteger(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 100) : 30
        const cursor = decodeReceivableCursor(url.searchParams.get('cursor'))
        const data = await readRpc('service_admin_list_receivable_appointments_page', {
          p_search: search,
          p_operation_scope: operationScope,
          p_cursor_start_at: cursor?.start_at ?? null,
          p_cursor_appointment_id: cursor?.appointment_id ?? null,
          p_limit: limit,
          p_admin_id: admin.adminId,
        }) as { appointments?: Row[]; has_more?: boolean; next_cursor?: Row | null }
        const appointments = Array.isArray(data?.appointments) ? data.appointments : []
        const nextCursor = data?.has_more ? encodeReceivableCursor(data.next_cursor) : null
        if (url.searchParams.has('month') || url.searchParams.has('limit') || url.searchParams.has('cursor')) {
          return json({ appointments, has_more: data?.has_more === true, next_cursor: nextCursor })
        }
        const receivables = appointments.map((row) => ({
          appointment_id: row.appointment_id,
          public_code: row.public_code,
          customer_id: row.customer_id,
          customer_name: row.customer_name,
          service: row.service_name,
          start_at: row.start_at,
          operation_scope: row.operation_scope,
          commercial_value: row.commercial_value,
          balance: row.remaining_due,
        }))
        return json({ operation_scope: operationScope, search, receivables, has_more: data?.has_more === true, next_cursor: nextCursor })
      }

      if (action === 'manual_receipts' || action === 'receipts') {
        const selected = selectedMonth(url)
        const data = await manualReceipts(admin.adminId, selected, operationScope)
        if (action === 'manual_receipts') return json(data)
        const receipts = (Array.isArray(data?.receipts) ? data.receipts : []).map((row) => ({
          id: row.transaction_id,
          appointment_id: row.appointment_id,
          public_code: row.public_code,
          customer_id: row.customer_id,
          customer_name: row.customer_name,
          service: row.service_name,
          operation_scope: row.operation_scope,
          amount: row.amount,
          method: row.method,
          method_label: row.method === 'PIX' ? 'Pix' : row.method === 'CASH' ? 'Dinheiro' : row.method,
          registered_at: row.paid_at,
          registered_by_admin_id: row.created_by_admin_id,
          registered_by: row.registered_by,
          updated_at: row.paid_at,
          reversed: row.editable === false || row.status === 'REFUNDED',
        }))
        return json({ month: data.month, operation_scope: data.operation_scope, timezone: data.timezone, receipts })
      }

      if (action === 'pending_refunds') {
        const data = await readRpc('service_admin_finance_pending_refunds', {
          p_operation_scope: operationScope,
          p_admin_id: admin.adminId,
        }) as { refunds?: Row[] } | null
        return json({ operation_scope: operationScope, refunds: Array.isArray(data?.refunds) ? data.refunds : [] })
      }

      if (action === 'nfse_export' || action === 'export') {
        const selected = selectedMonth(url)
        const data = await readRpc('service_admin_finance_nfse_export', {
          p_month: `${selected}-01`,
          p_operation_scope: operationScope,
          p_admin_id: admin.adminId,
        }) as { rows?: Row[] } | null
        const rows = Array.isArray(data?.rows) ? data.rows : []
        const suffix = operationScope === 'BLACKSHEEP' ? 'blacksheep' : operationScope === 'SABRINA' ? 'sabrina-pierri' : 'todas'
        return new Response(nfseCsv(rows), {
          status: 200,
          headers: {
            ...corsHeaders,
            'content-type': 'text/csv; charset=utf-8',
            'content-disposition': `attachment; filename="nfse-${selected}-${suffix}.csv"`,
            'cache-control': 'no-store',
          },
        })
      }

      return json({ error: { code: 'NOT_FOUND' } }, 404)
    }

    const admin = await requirePermission(req, 'FINANCE_MANAGE')
    const body = await req.json().catch(() => ({})) as Row
    const rawAction = clean(body.action) ?? ''
    const oldFacade = clean(url.searchParams.get('action'))?.toLowerCase() === 'manual_receipt'
    const action = oldFacade
      ? rawAction.toUpperCase() === 'CREATE' ? 'record_manual_receipt'
        : rawAction.toUpperCase() === 'EDIT' ? 'edit_manual_receipt'
          : rawAction.toUpperCase() === 'REVERSE' ? 'reverse_manual_receipt'
            : rawAction
      : rawAction
    const client = adminClient()

    if (action === 'record_manual_receipt') {
      const { data, error } = await client.rpc('service_admin_record_manual_receipt', {
        p_appointment_id: uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID'),
        p_method: clean(body.method),
        p_amount: amount(body.amount),
        p_paid_at: paidAt(body.paid_at),
        p_notes: clean(body.notes),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(oldFacade ? { result: data } : data, 201)
    }

    if (action === 'edit_manual_receipt') {
      const transactionId = body.transaction_id ?? body.payment_transaction_id
      const { data, error } = await client.rpc('service_admin_edit_manual_receipt', {
        p_transaction_id: uuid(transactionId, 'MANUAL_RECEIPT_ID_INVALID'),
        p_method: clean(body.method),
        p_amount: amount(body.amount),
        p_paid_at: paidAt(body.paid_at),
        p_notes: clean(body.notes),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(oldFacade ? { result: data } : data)
    }

    if (action === 'reverse_manual_receipt') {
      const transactionId = body.transaction_id ?? body.payment_transaction_id
      const reason = clean(body.reason) ?? (oldFacade ? 'Estorno manual confirmado na Gestão' : null)
      const { data, error } = await client.rpc('service_admin_reverse_manual_receipt', {
        p_transaction_id: uuid(transactionId, 'MANUAL_RECEIPT_ID_INVALID'),
        p_reason: reason,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(oldFacade ? { result: data } : data)
    }

    if (action === 'record_manual_refund') {
      const evidence = authorshipEvidence(req)
      const reference = clean(body.reference)
      if (!reference) throw new Error('MANUAL_REFUND_EVIDENCE_REQUIRED')
      const method = clean(body.method)?.toUpperCase()
      if (method !== 'CASH' && method !== 'PIX') throw new Error('MANUAL_REFUND_METHOD_INVALID')
      const { data, error } = await client.rpc('service_admin_record_cancellation_manual_refund', {
        p_policy_action_id: uuid(body.policy_action_id, 'POLICY_ACTION_ID_INVALID'),
        p_method: method,
        p_cash_amount: refundAmount(body.amount),
        p_reference: reference,
        p_paid_at: refundPaidAt(body.paid_at),
        p_admin_id: admin.adminId,
        p_ip: evidence.ip,
        p_user_agent: evidence.userAgent,
        p_request_id: evidence.requestId,
      })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }

    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_FINANCE_MINIMAL_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.endsWith('_NOT_FOUND') || code === 'APPOINTMENT_NOT_FOUND' ? 404
      : code === 'MANUAL_RECEIPT_ALREADY_REVERSED' || code === 'MANUAL_RECEIPT_EXCEEDS_BALANCE' || code === 'MANUAL_RECEIPT_APPOINTMENT_CLOSED' || code === 'MANUAL_REFUND_EXCEEDS_OFF_GATEWAY_AMOUNT' || code === 'CANCELLATION_REFUND_NOT_PENDING' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})