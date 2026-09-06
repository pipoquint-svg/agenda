import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const MAX_PERIOD_DAYS = 366
const MAX_PAGE_SIZE = 100
const FETCH_PAGE_SIZE = 1000
const MAX_FETCH_PAGES = 100

const chargeSettledStatuses = new Set(['APPROVED', 'PARTIALLY_REFUNDED', 'REFUNDED'])
const refundSettledStatuses = new Set(['APPROVED', 'REFUNDED'])

const allowedTransactionTypes = new Set(['CHARGE', 'REFUND'])
const allowedStatuses = new Set(['PENDING', 'APPROVED', 'REJECTED', 'EXPIRED', 'REFUNDED', 'PARTIALLY_REFUNDED'])
const allowedPurposes = new Set(['CONTRACT', 'RESCHEDULE_PENALTY', 'CANCELLATION_PENALTY'])
const allowedMethods = new Set(['PIX', 'CARD', 'CASH', 'TRANSFER', 'CREDIT', 'COURTESY', 'OTHER'])
const allowedProviders = new Set(['MERCADO_PAGO', 'INFINITEPAY', 'MANUAL'])

type TransactionRow = {
  id: string
  appointment_id: string
  transaction_type: string
  method: string
  provider: string
  provider_payment_id: string | null
  status: string
  contract_amount_settled: number | string | null
  payment_discount_amount: number | string | null
  cash_amount: number | string | null
  parent_transaction_id: string | null
  paid_at: string | null
  created_by_admin_id: string | null
  notes: string | null
  created_at: string
  updated_at: string
  idempotency_key: string | null
  requested_percentage: number | string | null
  policy_action_id: string | null
  payment_purpose: string
  balance_collection_id: string | null
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function money(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? Math.round(parsed * 100) / 100 : 0
}

function roundMoney(value: number): number {
  return Math.round(value * 100) / 100
}

function uuid(value: unknown, code = 'ID_INVALID'): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error(code)
  return next
}

function parsePeriod(url: URL): { from: string; to: string; fromMs: number; toMs: number } {
  const fromRaw = url.searchParams.get('from') ?? url.searchParams.get('start_at') ?? ''
  const toRaw = url.searchParams.get('to') ?? url.searchParams.get('end_at') ?? ''
  if (!fromRaw || !toRaw) throw new Error('FINANCE_PERIOD_REQUIRED')

  const fromMs = Date.parse(fromRaw)
  const toMs = Date.parse(toRaw)
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs <= fromMs) throw new Error('FINANCE_PERIOD_INVALID')
  if (toMs - fromMs > MAX_PERIOD_DAYS * 24 * 60 * 60 * 1000) throw new Error('FINANCE_PERIOD_TOO_LARGE')

  return { from: new Date(fromMs).toISOString(), to: new Date(toMs).toISOString(), fromMs, toMs }
}

function optionalEnum(url: URL, name: string, allowed: Set<string>): string | null {
  const raw = url.searchParams.get(name)
  if (!raw) return null
  const value = raw.trim().toUpperCase()
  if (!allowed.has(value)) throw new Error(`FINANCE_${name.toUpperCase()}_INVALID`)
  return value
}

function positiveInt(raw: string | null, fallback: number, max: number, code: string): number {
  if (!raw) return fallback
  const parsed = Number(raw)
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > max) throw new Error(code)
  return parsed
}

function occurredAt(row: TransactionRow): string {
  return row.paid_at ?? row.created_at
}

function inPeriod(row: TransactionRow, fromMs: number, toMs: number): boolean {
  const value = Date.parse(occurredAt(row))
  return Number.isFinite(value) && value >= fromMs && value < toMs
}

async function fetchRowsByDateField(
  client: ReturnType<typeof adminClient>,
  field: 'created_at' | 'paid_at',
  from: string,
  to: string,
): Promise<TransactionRow[]> {
  const rows: TransactionRow[] = []
  for (let page = 0; page < MAX_FETCH_PAGES; page += 1) {
    const start = page * FETCH_PAGE_SIZE
    const end = start + FETCH_PAGE_SIZE - 1
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,payment_discount_amount,cash_amount,parent_transaction_id,paid_at,created_by_admin_id,notes,created_at,updated_at,idempotency_key,requested_percentage,policy_action_id,payment_purpose,balance_collection_id')
      .eq('is_test', false)
      .gte(field, from)
      .lt(field, to)
      .order(field, { ascending: true })
      .order('id', { ascending: true })
      .range(start, end)

    if (error) throw new Error(`FINANCE_TRANSACTIONS_QUERY_FAILED:${error.message}`)
    const chunk = (data ?? []) as TransactionRow[]
    rows.push(...chunk)
    if (chunk.length < FETCH_PAGE_SIZE) return rows
  }
  throw new Error('FINANCE_PERIOD_RESULT_TOO_LARGE')
}

async function fetchPeriodTransactions(
  client: ReturnType<typeof adminClient>,
  period: { from: string; to: string; fromMs: number; toMs: number },
): Promise<TransactionRow[]> {
  const [createdRows, paidRows] = await Promise.all([
    fetchRowsByDateField(client, 'created_at', period.from, period.to),
    fetchRowsByDateField(client, 'paid_at', period.from, period.to),
  ])

  const unique = new Map<string, TransactionRow>()
  for (const row of [...createdRows, ...paidRows]) unique.set(row.id, row)
  return Array.from(unique.values()).filter((row) => inPeriod(row, period.fromMs, period.toMs))
}

function addBreakdown(
  target: Map<string, { charge_cash: number; refund_cash: number }>,
  key: string,
  transactionType: string,
  amount: number,
) {
  const current = target.get(key) ?? { charge_cash: 0, refund_cash: 0 }
  if (transactionType === 'CHARGE') current.charge_cash += amount
  if (transactionType === 'REFUND') current.refund_cash += amount
  target.set(key, current)
}

function serializeBreakdown(target: Map<string, { charge_cash: number; refund_cash: number }>) {
  return Array.from(target.entries())
    .map(([key, value]) => ({ key, charge_cash: roundMoney(value.charge_cash), refund_cash: roundMoney(value.refund_cash), net_cash: roundMoney(value.charge_cash - value.refund_cash) }))
    .sort((a, b) => a.key.localeCompare(b.key))
}

async function financeSummary(req: Request, url: URL): Promise<Response> {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')

  const period = parsePeriod(url)
  const client = adminClient()
  const transactions = await fetchPeriodTransactions(client, period)

  let grossCashReceived = 0
  let refundedCash = 0
  let grossContractSettled = 0
  let refundedContract = 0
  let discountsGranted = 0
  let penaltiesCashReceived = 0
  let pendingChargeCount = 0
  let pendingChargeCash = 0
  let approvedChargeCount = 0
  let approvedRefundCount = 0

  const byMethod = new Map<string, { charge_cash: number; refund_cash: number }>()
  const byProvider = new Map<string, { charge_cash: number; refund_cash: number }>()

  for (const row of transactions) {
    const cash = money(row.cash_amount)
    const contract = money(row.contract_amount_settled)
    const discount = money(row.payment_discount_amount)
    const isChargeSettled = row.transaction_type === 'CHARGE' && chargeSettledStatuses.has(row.status)
    const isRefundSettled = row.transaction_type === 'REFUND' && refundSettledStatuses.has(row.status)

    if (isChargeSettled) {
      approvedChargeCount += 1
      grossCashReceived += cash
      addBreakdown(byMethod, row.method, row.transaction_type, cash)
      addBreakdown(byProvider, row.provider, row.transaction_type, cash)
      if (row.payment_purpose === 'CONTRACT') {
        grossContractSettled += contract
        discountsGranted += discount
      } else {
        penaltiesCashReceived += cash
      }
    }

    if (isRefundSettled) {
      approvedRefundCount += 1
      refundedCash += cash
      addBreakdown(byMethod, row.method, row.transaction_type, cash)
      addBreakdown(byProvider, row.provider, row.transaction_type, cash)
      if (row.payment_purpose === 'CONTRACT') refundedContract += contract
    }

    if (row.transaction_type === 'CHARGE' && row.status === 'PENDING') {
      pendingChargeCount += 1
      pendingChargeCash += cash
    }
  }
  const { data: balanceReport, error: balanceError } = await client.rpc('service_finance_customer_balance_report', {
    p_from: period.from,
    p_to: period.to,
  })
  if (balanceError) throw new Error(`FINANCE_BALANCE_REPORT_FAILED:${balanceError.message}`)

  return json({
    range: { from: period.from, to: period.to },
    cash: {
      gross_received: roundMoney(grossCashReceived),
      refunded: roundMoney(refundedCash),
      net_received: roundMoney(grossCashReceived - refundedCash),
      operational_penalties_received: roundMoney(penaltiesCashReceived),
    },
    contract: {
      gross_settled: roundMoney(grossContractSettled),
      refunded: roundMoney(refundedContract),
      net_settled_delta: roundMoney(grossContractSettled - refundedContract),
      payment_discounts_granted: roundMoney(discountsGranted),
    },
    pending: {
      charge_count: pendingChargeCount,
      charge_cash_amount: roundMoney(pendingChargeCash),
    },
    activity: {
      transaction_count: transactions.length,
      approved_charge_count: approvedChargeCount,
      approved_refund_count: approvedRefundCount,
    },
    by_method: serializeBreakdown(byMethod).map(({ key, ...values }) => ({ method: key, ...values })),
    by_provider: serializeBreakdown(byProvider).map(({ key, ...values }) => ({ provider: key, ...values })),
    customer_balance: balanceReport,
    accounting: {
      customer_balance_classification: 'LIABILITY_NOT_REVENUE',
      note: 'Customer balance is presented separately from cash and contract settlement.',
    },
  })
}

async function financeTransactions(req: Request, url: URL): Promise<Response> {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')

  const period = parsePeriod(url)
  const page = positiveInt(url.searchParams.get('page'), 1, 100000, 'FINANCE_PAGE_INVALID')
  const limit = positiveInt(url.searchParams.get('limit'), 50, MAX_PAGE_SIZE, 'FINANCE_LIMIT_INVALID')
  const transactionType = optionalEnum(url, 'transaction_type', allowedTransactionTypes)
  const status = optionalEnum(url, 'status', allowedStatuses)
  const paymentPurpose = optionalEnum(url, 'payment_purpose', allowedPurposes)
  const method = optionalEnum(url, 'method', allowedMethods)
  const provider = optionalEnum(url, 'provider', allowedProviders)
  const appointmentId = url.searchParams.get('appointment_id') ? uuid(url.searchParams.get('appointment_id'), 'APPOINTMENT_ID_INVALID') : null

  const client = adminClient()
  let transactions = await fetchPeriodTransactions(client, period)
  transactions = transactions.filter((row) =>
    (!transactionType || row.transaction_type === transactionType) &&
    (!status || row.status === status) &&
    (!paymentPurpose || row.payment_purpose === paymentPurpose) &&
    (!method || row.method === method) &&
    (!provider || row.provider === provider) &&
    (!appointmentId || row.appointment_id === appointmentId)
  )
  transactions.sort((a, b) => Date.parse(occurredAt(b)) - Date.parse(occurredAt(a)) || b.id.localeCompare(a.id))

  const total = transactions.length
  const offset = (page - 1) * limit
  const pageRows = transactions.slice(offset, offset + limit)
  const appointmentIds = Array.from(new Set(pageRows.map((row) => row.appointment_id)))

  const appointmentById = new Map<string, Record<string, unknown>>()
  if (appointmentIds.length) {
    const { data, error } = await client
      .from('appointments')
      .select('id,public_code,primary_customer_id,service_name_snapshot,start_at,status,financial_status')
      .in('id', appointmentIds)
    if (error) throw new Error(`FINANCE_APPOINTMENTS_QUERY_FAILED:${error.message}`)
    for (const row of data ?? []) appointmentById.set(String(row.id), row as Record<string, unknown>)
  }

  const customerIds = Array.from(new Set(Array.from(appointmentById.values()).map((row) => row.primary_customer_id).filter(Boolean).map(String)))
  const customerById = new Map<string, Record<string, unknown>>()
  if (customerIds.length) {
    const { data, error } = await client.from('customers').select('id,name').in('id', customerIds)
    if (error) throw new Error(`FINANCE_CUSTOMERS_QUERY_FAILED:${error.message}`)
    for (const row of data ?? []) customerById.set(String(row.id), row as Record<string, unknown>)
  }

  return json({
    range: { from: period.from, to: period.to },
    filters: { transaction_type: transactionType, status, payment_purpose: paymentPurpose, method, provider, appointment_id: appointmentId },
    pagination: { page, limit, total, total_pages: total === 0 ? 0 : Math.ceil(total / limit) },
    transactions: pageRows.map((row) => {
      const appointment = appointmentById.get(row.appointment_id)
      const customerId = appointment?.primary_customer_id ? String(appointment.primary_customer_id) : null
      const customer = customerId ? customerById.get(customerId) : null
      return {
        id: row.id,
        occurred_at: occurredAt(row),
        appointment_id: row.appointment_id,
        appointment: appointment ? {
          public_code: appointment.public_code ?? null,
          service_name: appointment.service_name_snapshot ?? null,
          start_at: appointment.start_at ?? null,
          status: appointment.status ?? null,
          financial_status: appointment.financial_status ?? null,
        } : null,
        customer: customer ? { id: customer.id ?? customerId, name: customer.name ?? null } : null,
        transaction_type: row.transaction_type,
        payment_purpose: row.payment_purpose,
        method: row.method,
        provider: row.provider,
        provider_payment_id: row.provider_payment_id,
        status: row.status,
        contract_amount_settled: money(row.contract_amount_settled),
        payment_discount_amount: money(row.payment_discount_amount),
        cash_amount: money(row.cash_amount),
        requested_percentage: row.requested_percentage == null ? null : Number(row.requested_percentage),
        parent_transaction_id: row.parent_transaction_id,
        policy_action_id: row.policy_action_id,
        balance_collection_id: row.balance_collection_id,
        created_by_admin_id: row.created_by_admin_id,
        notes: row.notes,
        paid_at: row.paid_at,
        created_at: row.created_at,
        updated_at: row.updated_at,
      }
    }),
  })
}

async function refundFacade(req: Request): Promise<Response> {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')

  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const policyActionId = uuid(body.policy_action_id, 'POLICY_ACTION_ID_INVALID')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  if (!supabaseUrl) throw new Error('MISSING_ENV_SUPABASE_URL')

  const authorization = req.headers.get('authorization') ?? ''
  const apikey = req.headers.get('apikey') ?? ''
  const requestId = req.headers.get('x-request-id') ?? crypto.randomUUID()
  if (!authorization) throw new Error('ADMIN_AUTH_REQUIRED')

  const upstream = await fetch(`${supabaseUrl}/functions/v1/admin-appointment-actions`, {
    method: 'POST',
    headers: {
      authorization,
      ...(apikey ? { apikey } : {}),
      'content-type': 'application/json',
      'x-request-id': requestId,
      'user-agent': req.headers.get('user-agent') ?? 'admin-finance-refund-facade',
    },
    body: JSON.stringify({ action: 'PROCESS_REFUND', policy_action_id: policyActionId }),
  })

  const payload = await upstream.text()
  return new Response(payload, {
    status: upstream.status,
    headers: { ...corsHeaders, 'content-type': upstream.headers.get('content-type') ?? 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  const url = new URL(req.url)
  const normalizedPath = url.pathname.replace(/\/+$/, '')
  const isTransactions = normalizedPath.endsWith('/admin-finance/transactions')
  const isRefund = normalizedPath.endsWith('/admin-finance/refund')
  const isRoot = normalizedPath.endsWith('/admin-finance')

  try {
    if (req.method === 'GET' && isRoot) return await financeSummary(req, url)
    if (req.method === 'GET' && isTransactions) return await financeTransactions(req, url)
    if (req.method === 'POST' && isRefund) return await refundFacade(req)
    if (!isRoot && !isTransactions && !isRefund) return json({ error: { code: 'NOT_FOUND' } }, 404)
    return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_FINANCE_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.startsWith('MISSING_ENV_') || code === 'REAL_CHARGES_DISABLED' || code === 'MERCADO_PAGO_ENV_INVALID' ? 503
      : code === 'FINANCE_PERIOD_RESULT_TOO_LARGE' ? 413
      : 400
    return json({ error: { code } }, status)
  }
})