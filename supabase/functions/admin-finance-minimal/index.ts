import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}

const TZ = 'America/Sao_Paulo'
const FETCH_PAGE_SIZE = 1000
const MAX_FETCH_PAGES = 100
const chargeSettledStatuses = new Set(['APPROVED', 'PARTIALLY_REFUNDED', 'REFUNDED'])
const refundSettledStatuses = new Set(['APPROVED', 'REFUNDED'])

type OperationScope = 'BLACKSHEEP' | 'SABRINA'
type AppointmentRow = {
  id: string
  public_code: string
  primary_customer_id: string | null
  service_id: string | null
  service_name_snapshot: string | null
  start_at: string
  status: string
  commercial_value: number | string | null
  financial_status?: string | null
}
type CustomerRow = { id: string; name: string; cpf_cnpj: string | null; address: string | null; email: string | null }
type ServiceRow = { id: string; name: string; operation_scope: OperationScope | null }
type PaymentRow = {
  id: string
  appointment_id: string
  transaction_type: string
  method: string
  provider: string
  status: string
  contract_amount_settled: number | string | null
  payment_discount_amount: number | string | null
  parent_transaction_id: string | null
  paid_at: string | null
  created_by_admin_id: string | null
  created_at: string
  updated_at: string
  payment_purpose: string
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function money(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? Math.round(parsed * 100) / 100 : 0
}

function clean(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function uuid(value: unknown, code = 'ID_INVALID'): string {
  const next = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error(code)
  return next
}

function period(url: URL) {
  const fromRaw = url.searchParams.get('from') ?? ''
  const toRaw = url.searchParams.get('to') ?? ''
  const fromMs = Date.parse(fromRaw)
  const toMs = Date.parse(toRaw)
  if (!fromRaw || !toRaw || !Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs <= fromMs) throw new Error('FINANCE_PERIOD_INVALID')
  if (toMs - fromMs > 370 * 24 * 60 * 60 * 1000) throw new Error('FINANCE_PERIOD_TOO_LARGE')
  return { from: new Date(fromMs).toISOString(), to: new Date(toMs).toISOString() }
}

function operation(url: URL): OperationScope | null {
  const raw = clean(url.searchParams.get('operation_scope'))?.toUpperCase() ?? null
  if (raw === null || raw === 'ALL') return null
  if (raw !== 'BLACKSHEEP' && raw !== 'SABRINA') throw new Error('FINANCE_OPERATION_INVALID')
  return raw
}

function paymentMethodLabel(method: string) {
  const labels: Record<string, string> = {
    PIX: 'Pix', CARD: 'Cartão', CASH: 'Dinheiro', TRANSFER: 'Transferência', CREDIT: 'Crédito', COURTESY: 'Cortesia', OTHER: 'Outro',
  }
  return labels[method] ?? method
}

function operationLabel(scope: OperationScope | null) {
  return scope === 'SABRINA' ? 'Sabrina Pierri' : scope === 'BLACKSHEEP' ? 'BlackSheep' : ''
}

async function completedAppointments(client: ReturnType<typeof adminClient>, from: string, to: string): Promise<AppointmentRow[]> {
  const rows: AppointmentRow[] = []
  for (let page = 0; page < MAX_FETCH_PAGES; page += 1) {
    const start = page * FETCH_PAGE_SIZE
    const { data, error } = await client
      .from('appointments')
      .select('id,public_code,primary_customer_id,service_id,service_name_snapshot,start_at,status,commercial_value,financial_status')
      .eq('status', 'COMPLETED')
      .gte('start_at', from)
      .lt('start_at', to)
      .order('start_at', { ascending: true })
      .range(start, start + FETCH_PAGE_SIZE - 1)
    if (error) throw new Error(`FINANCE_APPOINTMENTS_QUERY_FAILED:${error.message}`)
    const chunk = (data ?? []) as AppointmentRow[]
    rows.push(...chunk)
    if (chunk.length < FETCH_PAGE_SIZE) return rows
  }
  throw new Error('FINANCE_PERIOD_RESULT_TOO_LARGE')
}

async function customerMap(client: ReturnType<typeof adminClient>, ids: string[]) {
  const map = new Map<string, CustomerRow>()
  for (let offset = 0; offset < ids.length; offset += 200) {
    const chunk = ids.slice(offset, offset + 200)
    if (!chunk.length) continue
    const { data, error } = await client.from('customers').select('id,name,cpf_cnpj,address,email').in('id', chunk)
    if (error) throw new Error(`FINANCE_CUSTOMERS_QUERY_FAILED:${error.message}`)
    for (const row of data ?? []) map.set(String(row.id), row as CustomerRow)
  }
  return map
}

async function serviceMap(client: ReturnType<typeof adminClient>, ids: string[]) {
  const map = new Map<string, ServiceRow>()
  for (let offset = 0; offset < ids.length; offset += 200) {
    const chunk = ids.slice(offset, offset + 200)
    if (!chunk.length) continue
    const { data, error } = await client.from('services').select('id,name,operation_scope').in('id', chunk)
    if (error) throw new Error(`FINANCE_SERVICES_QUERY_FAILED:${error.message}`)
    for (const row of data ?? []) map.set(String(row.id), row as ServiceRow)
  }
  return map
}

async function paymentsForAppointments(client: ReturnType<typeof adminClient>, ids: string[]): Promise<PaymentRow[]> {
  const rows: PaymentRow[] = []
  for (let offset = 0; offset < ids.length; offset += 150) {
    const chunk = ids.slice(offset, offset + 150)
    if (!chunk.length) continue
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,parent_transaction_id,paid_at,created_by_admin_id,created_at,updated_at,payment_purpose')
      .in('appointment_id', chunk)
      .eq('payment_purpose', 'CONTRACT')
    if (error) throw new Error(`FINANCE_PAYMENTS_QUERY_FAILED:${error.message}`)
    rows.push(...((data ?? []) as PaymentRow[]))
  }
  return rows
}

function paymentMethods(payments: PaymentRow[]) {
  const byAppointment = new Map<string, Map<string, number>>()
  for (const row of payments) {
    const settled = row.transaction_type === 'CHARGE' ? chargeSettledStatuses.has(row.status) : refundSettledStatuses.has(row.status)
    if (!settled) continue
    const direction = row.transaction_type === 'REFUND' ? -1 : 1
    const perMethod = byAppointment.get(row.appointment_id) ?? new Map<string, number>()
    perMethod.set(row.method, (perMethod.get(row.method) ?? 0) + direction * money(row.contract_amount_settled))
    byAppointment.set(row.appointment_id, perMethod)
  }
  const result = new Map<string, string>()
  for (const [appointmentId, methods] of byAppointment.entries()) {
    const active = Array.from(methods.entries()).filter(([, amount]) => amount > 0.005).map(([method]) => paymentMethodLabel(method))
    result.set(appointmentId, active.join(' + '))
  }
  return result
}

function contractCoverage(payments: PaymentRow[]) {
  const coverage = new Map<string, number>()
  for (const row of payments) {
    if (row.transaction_type === 'CHARGE' && chargeSettledStatuses.has(row.status)) {
      coverage.set(row.appointment_id, (coverage.get(row.appointment_id) ?? 0) + money(row.contract_amount_settled) + money(row.payment_discount_amount))
    } else if (row.transaction_type === 'REFUND' && refundSettledStatuses.has(row.status)) {
      coverage.set(row.appointment_id, (coverage.get(row.appointment_id) ?? 0) - money(row.contract_amount_settled))
    }
  }
  return coverage
}

async function fiscalRows(client: ReturnType<typeof adminClient>, from: string, to: string, scope: OperationScope | null) {
  const appointments = await completedAppointments(client, from, to)
  const customerIds = Array.from(new Set(appointments.map((row) => row.primary_customer_id).filter((id): id is string => Boolean(id))))
  const serviceIds = Array.from(new Set(appointments.map((row) => row.service_id).filter((id): id is string => Boolean(id))))
  const [customers, services, payments] = await Promise.all([
    customerMap(client, customerIds),
    serviceMap(client, serviceIds),
    paymentsForAppointments(client, appointments.map((row) => row.id)),
  ])
  const methods = paymentMethods(payments)

  return appointments.flatMap((appointment) => {
    const service = appointment.service_id ? services.get(appointment.service_id) : undefined
    const appointmentScope = service?.operation_scope ?? null
    if (scope && appointmentScope !== scope) return []
    const customer = appointment.primary_customer_id ? customers.get(appointment.primary_customer_id) : undefined
    return [{
      appointment_id: appointment.id,
      public_code: appointment.public_code,
      date: appointment.start_at,
      customer: customer?.name ?? '',
      cpf_cnpj: customer?.cpf_cnpj ?? '',
      address: customer?.address ?? '',
      email: customer?.email ?? '',
      service: appointment.service_name_snapshot ?? service?.name ?? '',
      value: money(appointment.commercial_value),
      payment_method: methods.get(appointment.id) ?? '',
      operation_scope: appointmentScope,
      operation: operationLabel(appointmentScope),
    }]
  })
}

function csvCell(value: unknown) {
  const raw = value == null ? '' : String(value)
  const safe = /^[=+\-@]/.test(raw) ? `'${raw}` : raw
  return `"${safe.replaceAll('"', '""')}"`
}

function localDate(value: string) {
  return new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date(value))
}

function fiscalCsv(rows: Awaited<ReturnType<typeof fiscalRows>>) {
  const header = ['Data', 'Cliente', 'CPF/CNPJ', 'Endereço', 'E-mail', 'Serviço', 'Valor', 'Forma de pagamento', 'Operação']
  const body = rows.map((row) => [
    localDate(row.date), row.customer, row.cpf_cnpj, row.address, row.email, row.service, row.value.toFixed(2).replace('.', ','), row.payment_method, row.operation,
  ].map(csvCell).join(';'))
  return `\uFEFF${header.map(csvCell).join(';')}\r\n${body.join('\r\n')}\r\n`
}

async function closing(req: Request, url: URL) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
  const range = period(url)
  const scope = operation(url)
  const rows = await fiscalRows(adminClient(), range.from, range.to, scope)
  return json({
    range,
    operation_scope: scope,
    timezone: TZ,
    service_count: rows.length,
    revenue: Math.round(rows.reduce((sum, row) => sum + row.value, 0) * 100) / 100,
    services: rows,
  })
}

async function exportFiscal(req: Request, url: URL) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
  const range = period(url)
  const scope = operation(url)
  const rows = await fiscalRows(adminClient(), range.from, range.to, scope)
  const month = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit' }).format(new Date(range.from)).slice(0, 7)
  return new Response(fiscalCsv(rows), {
    status: 200,
    headers: {
      ...corsHeaders,
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="servicos-prestados-${month}.csv"`,
      'cache-control': 'no-store',
    },
  })
}

async function manualReceipts(req: Request, url: URL) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
  const range = period(url)
  const scope = operation(url)
  const client = adminClient()
  const { data, error } = await client
    .from('payment_transactions')
    .select('id,appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,parent_transaction_id,paid_at,created_by_admin_id,created_at,updated_at,payment_purpose')
    .eq('provider', 'MANUAL')
    .eq('transaction_type', 'CHARGE')
    .eq('payment_purpose', 'CONTRACT')
    .gte('paid_at', range.from)
    .lt('paid_at', range.to)
    .order('paid_at', { ascending: false })
    .limit(1000)
  if (error) throw new Error(`FINANCE_MANUAL_RECEIPTS_QUERY_FAILED:${error.message}`)
  const payments = (data ?? []) as PaymentRow[]
  const appointmentIds = Array.from(new Set(payments.map((row) => row.appointment_id)))
  const { data: appointmentData, error: appointmentError } = appointmentIds.length
    ? await client.from('appointments').select('id,public_code,primary_customer_id,service_id,service_name_snapshot,start_at,status,commercial_value,financial_status').in('id', appointmentIds)
    : { data: [], error: null }
  if (appointmentError) throw new Error(`FINANCE_APPOINTMENTS_QUERY_FAILED:${appointmentError.message}`)
  const appointments = (appointmentData ?? []) as AppointmentRow[]
  const appointmentMap = new Map(appointments.map((row) => [row.id, row]))
  const customers = await customerMap(client, Array.from(new Set(appointments.map((row) => row.primary_customer_id).filter((id): id is string => Boolean(id)))))
  const services = await serviceMap(client, Array.from(new Set(appointments.map((row) => row.service_id).filter((id): id is string => Boolean(id)))))
  const adminIds = Array.from(new Set(payments.map((row) => row.created_by_admin_id).filter((id): id is string => Boolean(id))))
  const adminNames = new Map<string, string>()
  if (adminIds.length) {
    const { data: admins, error: adminsError } = await client.from('admin_users').select('id,display_name').in('id', adminIds)
    if (adminsError) throw new Error(`FINANCE_ADMINS_QUERY_FAILED:${adminsError.message}`)
    for (const row of admins ?? []) adminNames.set(String(row.id), String(row.display_name ?? ''))
  }
  const ids = payments.map((row) => row.id)
  const reversedIds = new Set<string>()
  if (ids.length) {
    const { data: refunds, error: refundsError } = await client.from('payment_transactions').select('parent_transaction_id').in('parent_transaction_id', ids)
    if (refundsError) throw new Error(`FINANCE_REFUNDS_QUERY_FAILED:${refundsError.message}`)
    for (const row of refunds ?? []) if (row.parent_transaction_id) reversedIds.add(String(row.parent_transaction_id))
  }

  const rows = payments.flatMap((payment) => {
    const appointment = appointmentMap.get(payment.appointment_id)
    const service = appointment?.service_id ? services.get(appointment.service_id) : undefined
    const appointmentScope = service?.operation_scope ?? null
    if (scope && appointmentScope !== scope) return []
    const customer = appointment?.primary_customer_id ? customers.get(appointment.primary_customer_id) : undefined
    return [{
      id: payment.id,
      appointment_id: payment.appointment_id,
      public_code: appointment?.public_code ?? '',
      customer_id: customer?.id ?? null,
      customer_name: customer?.name ?? '',
      service: appointment?.service_name_snapshot ?? service?.name ?? '',
      operation_scope: appointmentScope,
      amount: money(payment.contract_amount_settled),
      method: payment.method,
      method_label: paymentMethodLabel(payment.method),
      registered_at: payment.paid_at ?? payment.created_at,
      registered_by_admin_id: payment.created_by_admin_id,
      registered_by: payment.created_by_admin_id ? adminNames.get(payment.created_by_admin_id) ?? '' : '',
      updated_at: payment.updated_at,
      reversed: payment.status === 'REFUNDED' || reversedIds.has(payment.id),
    }]
  })
  return json({ range, operation_scope: scope, receipts: rows })
}

async function recentAppointmentCandidates(client: ReturnType<typeof adminClient>, search: string | null) {
  const fields = 'id,public_code,primary_customer_id,service_id,service_name_snapshot,start_at,status,commercial_value,financial_status'
  if (!search) {
    const { data, error } = await client.from('appointments').select(fields).not('primary_customer_id', 'is', null).order('start_at', { ascending: false }).limit(300)
    if (error) throw new Error(`FINANCE_RECEIVABLES_QUERY_FAILED:${error.message}`)
    return (data ?? []) as AppointmentRow[]
  }

  const safe = search.replace(/[%_]/g, '').trim()
  const byId = new Map<string, AppointmentRow>()
  const { data: byCode, error: codeError } = await client.from('appointments').select(fields).ilike('public_code', `%${safe}%`).not('primary_customer_id', 'is', null).order('start_at', { ascending: false }).limit(100)
  if (codeError) throw new Error(`FINANCE_RECEIVABLES_QUERY_FAILED:${codeError.message}`)
  for (const row of (byCode ?? []) as AppointmentRow[]) byId.set(row.id, row)

  const { data: matchingCustomers, error: customerError } = await client.from('customers').select('id').ilike('name', `%${safe}%`).limit(50)
  if (customerError) throw new Error(`FINANCE_CUSTOMERS_QUERY_FAILED:${customerError.message}`)
  const customerIds = (matchingCustomers ?? []).map((row) => String(row.id))
  if (customerIds.length) {
    const { data: byCustomer, error } = await client.from('appointments').select(fields).in('primary_customer_id', customerIds).order('start_at', { ascending: false }).limit(150)
    if (error) throw new Error(`FINANCE_RECEIVABLES_QUERY_FAILED:${error.message}`)
    for (const row of (byCustomer ?? []) as AppointmentRow[]) byId.set(row.id, row)
  }
  return Array.from(byId.values())
}

async function receivables(req: Request, url: URL) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
  const scope = operation(url)
  const search = clean(url.searchParams.get('search'))
  const client = adminClient()
  const appointments = await recentAppointmentCandidates(client, search)
  const customers = await customerMap(client, Array.from(new Set(appointments.map((row) => row.primary_customer_id).filter((id): id is string => Boolean(id)))))
  const services = await serviceMap(client, Array.from(new Set(appointments.map((row) => row.service_id).filter((id): id is string => Boolean(id)))))
  const payments = await paymentsForAppointments(client, appointments.map((row) => row.id))
  const coverage = contractCoverage(payments)

  const rows = appointments.flatMap((appointment) => {
    if (appointment.status === 'CANCELLED') return []
    const service = appointment.service_id ? services.get(appointment.service_id) : undefined
    const appointmentScope = service?.operation_scope ?? null
    if (scope && appointmentScope !== scope) return []
    const customer = appointment.primary_customer_id ? customers.get(appointment.primary_customer_id) : undefined
    if (!customer) return []
    const value = money(appointment.commercial_value)
    const balance = Math.max(0, Math.round((value - (coverage.get(appointment.id) ?? 0)) * 100) / 100)
    if (value <= 0 || balance <= 0.005) return []
    return [{
      appointment_id: appointment.id,
      public_code: appointment.public_code,
      customer_id: customer.id,
      customer_name: customer.name,
      service: appointment.service_name_snapshot ?? service?.name ?? '',
      start_at: appointment.start_at,
      operation_scope: appointmentScope,
      commercial_value: value,
      balance,
    }]
  }).sort((a, b) => Date.parse(b.start_at) - Date.parse(a.start_at)).slice(0, 50)

  return json({ operation_scope: scope, search, receivables: rows })
}

function authorship(req: Request) {
  return {
    ip: clean(req.headers.get('x-forwarded-for')) ?? clean(req.headers.get('cf-connecting-ip')) ?? 'edge-function',
    userAgent: clean(req.headers.get('user-agent')) ?? 'admin-finance-minimal',
    requestId: clean(req.headers.get('x-request-id')) ?? crypto.randomUUID(),
  }
}

async function writeManualReceipt(req: Request) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const action = (clean(body.action) ?? '').toUpperCase()
  const client = adminClient()
  const evidence = authorship(req)

  if (action === 'CREATE') {
    const appointmentId = uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID')
    const amount = money(body.amount)
    const method = (clean(body.method) ?? '').toUpperCase()
    const { data, error } = await client.rpc('service_record_manual_contract_payment', {
      p_appointment_id: appointmentId,
      p_admin_id: admin.adminId,
      p_amount: amount,
      p_method: method,
      p_ip: evidence.ip,
      p_user_agent: evidence.userAgent,
      p_request_id: evidence.requestId,
    })
    if (error) throw new Error(error.message)
    return json({ result: data }, 201)
  }

  if (action === 'EDIT') {
    const transactionId = uuid(body.payment_transaction_id, 'PAYMENT_TRANSACTION_ID_INVALID')
    const amount = money(body.amount)
    const method = (clean(body.method) ?? '').toUpperCase()
    const { data, error } = await client.rpc('service_admin_edit_manual_contract_payment', {
      p_payment_transaction_id: transactionId,
      p_admin_id: admin.adminId,
      p_amount: amount,
      p_method: method,
      p_ip: evidence.ip,
      p_user_agent: evidence.userAgent,
      p_request_id: evidence.requestId,
    })
    if (error) throw new Error(error.message)
    return json({ result: data })
  }

  if (action === 'REVERSE') {
    const transactionId = uuid(body.payment_transaction_id, 'PAYMENT_TRANSACTION_ID_INVALID')
    const { data, error } = await client.rpc('service_admin_reverse_manual_contract_payment', {
      p_payment_transaction_id: transactionId,
      p_admin_id: admin.adminId,
      p_ip: evidence.ip,
      p_user_agent: evidence.userAgent,
      p_request_id: evidence.requestId,
    })
    if (error) throw new Error(error.message)
    return json({ result: data })
  }

  throw new Error('MANUAL_PAYMENT_ACTION_INVALID')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  try {
    const url = new URL(req.url)
    const action = clean(url.searchParams.get('action'))?.toLowerCase() ?? 'closing'
    if (req.method === 'GET' && action === 'closing') return await closing(req, url)
    if (req.method === 'GET' && action === 'export') return await exportFiscal(req, url)
    if (req.method === 'GET' && action === 'receipts') return await manualReceipts(req, url)
    if (req.method === 'GET' && action === 'receivables') return await receivables(req, url)
    if (req.method === 'POST' && action === 'manual_receipt') return await writeManualReceipt(req)
    return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_FINANCE_MINIMAL_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'MANUAL_PAYMENT_NOT_FOUND' ? 404
      : code === 'MANUAL_PAYMENT_ALREADY_REVERSED' || code === 'MANUAL_PAYMENT_NOT_EDITABLE' || code === 'MANUAL_PAYMENT_NOT_REVERSIBLE' || code === 'APPOINTMENT_ALREADY_SETTLED' ? 409
      : code === 'FINANCE_PERIOD_RESULT_TOO_LARGE' ? 413
      : 400
    return json({ error: { code } }, status)
  }
})
