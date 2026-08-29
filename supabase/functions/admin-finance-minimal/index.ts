import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

type Row = Record<string, unknown>

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

function month(value: unknown): string {
  const raw = clean(value) ?? ''
  if (!/^\d{4}-\d{2}$/.test(raw)) throw new Error('FINANCE_MONTH_INVALID')
  const [year, mon] = raw.split('-').map(Number)
  if (year < 2000 || mon < 1 || mon > 12) throw new Error('FINANCE_MONTH_INVALID')
  return raw
}

function scope(value: unknown): 'BLACKSHEEP' | 'SABRINA' | null {
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

function paidAt(value: unknown): string | null {
  const raw = clean(value)
  if (!raw) return null
  const parsed = Date.parse(raw)
  if (!Number.isFinite(parsed)) throw new Error('MANUAL_RECEIPT_PAID_AT_INVALID')
  return new Date(parsed).toISOString()
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
  const header = ['Data', 'Cliente', 'CPF/CNPJ', 'Endereço', 'E-mail', 'Serviço', 'Valor', 'Forma de pagamento', 'Operação']
  const lines = rows.map((row) => [
    row.date,
    row.client,
    row.cpf_cnpj,
    row.address,
    row.email,
    row.service,
    moneyBr(row.value),
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const url = new URL(req.url)

    if (req.method === 'GET') {
      const admin = await requirePermission(req, 'FINANCE_VIEW')
      const action = clean(url.searchParams.get('action'))
      if (!action) throw new Error('FINANCE_ACTION_REQUIRED')

      if (action === 'month_close') {
        const selectedMonth = month(url.searchParams.get('month'))
        const operationScope = scope(url.searchParams.get('operation_scope'))
        const data = await readRpc('service_admin_finance_month_close', {
          p_month: `${selectedMonth}-01`,
          p_operation_scope: operationScope,
          p_admin_id: admin.adminId,
        })
        return json(data)
      }

      if (action === 'receivables') {
        const search = clean(url.searchParams.get('search'))
        const requestedLimit = Number(url.searchParams.get('limit') ?? 30)
        const limit = Number.isInteger(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 100) : 30
        const data = await readRpc('service_admin_list_receivable_appointments', {
          p_search: search,
          p_limit: limit,
          p_admin_id: admin.adminId,
        })
        return json(data)
      }

      if (action === 'manual_receipts') {
        const selectedMonth = month(url.searchParams.get('month'))
        const operationScope = scope(url.searchParams.get('operation_scope'))
        const data = await readRpc('service_admin_list_manual_receipts', {
          p_month: `${selectedMonth}-01`,
          p_operation_scope: operationScope,
          p_admin_id: admin.adminId,
        })
        return json(data)
      }

      if (action === 'nfse_export') {
        const selectedMonth = month(url.searchParams.get('month'))
        const operationScope = scope(url.searchParams.get('operation_scope'))
        const data = await readRpc('service_admin_finance_nfse_export', {
          p_month: `${selectedMonth}-01`,
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
            'content-disposition': `attachment; filename="nfse-${selectedMonth}-${suffix}.csv"`,
            'cache-control': 'no-store',
          },
        })
      }

      return json({ error: { code: 'NOT_FOUND' } }, 404)
    }

    const admin = await requirePermission(req, 'FINANCE_MANAGE')
    const body = await req.json().catch(() => ({})) as Row
    const action = clean(body.action)
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
      return json(data, 201)
    }

    if (action === 'edit_manual_receipt') {
      const { data, error } = await client.rpc('service_admin_edit_manual_receipt', {
        p_transaction_id: uuid(body.transaction_id, 'MANUAL_RECEIPT_ID_INVALID'),
        p_method: clean(body.method),
        p_amount: amount(body.amount),
        p_paid_at: paidAt(body.paid_at),
        p_notes: clean(body.notes),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'reverse_manual_receipt') {
      const { data, error } = await client.rpc('service_admin_reverse_manual_receipt', {
        p_transaction_id: uuid(body.transaction_id, 'MANUAL_RECEIPT_ID_INVALID'),
        p_reason: clean(body.reason),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_FINANCE_MINIMAL_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.endsWith('_NOT_FOUND') || code === 'APPOINTMENT_NOT_FOUND' ? 404
      : code === 'MANUAL_RECEIPT_ALREADY_REVERSED' || code === 'MANUAL_RECEIPT_EXCEEDS_BALANCE' || code === 'MANUAL_RECEIPT_APPOINTMENT_CLOSED' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
