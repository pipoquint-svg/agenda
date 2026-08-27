import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const statuses = new Set(['ACTIVE', 'EXHAUSTED', 'EXPIRED', 'CANCELLED'])

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function uuid(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)) throw new Error(code)
  return text
}

function boundedInt(url: URL, key: string, fallback: number, min: number, max: number): number {
  const raw = url.searchParams.get(key)
  if (!raw) return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`PACKAGES_${key.toUpperCase()}_INVALID`)
  return value
}

function packageIdFromLedgerPath(pathname: string): string | null {
  const match = pathname.match(/\/admin-hour-packages\/([^/]+)\/ledger\/?$/)
  return match ? match[1] : null
}

async function listPackages(req: Request, url: URL): Promise<Response> {
  await requireAdminPermission(req, 'PACKAGES_VIEW')
  const client = adminClient()
  const page = boundedInt(url, 'page', 1, 1, 100000)
  const limit = boundedInt(url, 'limit', 50, 1, 100)
  const customerIdRaw = url.searchParams.get('customer_id')?.trim() ?? ''
  const customerId = customerIdRaw ? uuid(customerIdRaw, 'CUSTOMER_ID_INVALID') : null
  const rawStatus = url.searchParams.get('status')?.trim().toUpperCase() ?? ''
  if (rawStatus && !statuses.has(rawStatus)) throw new Error('PACKAGE_STATUS_INVALID')

  const offset = (page - 1) * limit
  let query = client
    .from('hour_package_balances')
    .select('hour_package_id,customer_id,name,total_minutes,total_seconds,purchased_value,reference_minute_value,ledger_minutes,ledger_seconds,available_minutes,available_seconds,valid_from,valid_until,status', { count: 'exact' })
    .order('valid_until', { ascending: true, nullsFirst: false })
    .range(offset, offset + limit - 1)

  if (customerId) query = query.eq('customer_id', customerId)
  if (rawStatus) query = query.eq('status', rawStatus)

  const { data, error, count } = await query
  if (error) throw new Error('ADMIN_PACKAGES_QUERY_FAILED')

  const customerIds = [...new Set((data ?? []).map((row) => String(row.customer_id)).filter(Boolean))]
  const customerMap = new Map<string, { id: string; name: string | null }>()
  if (customerIds.length) {
    const { data: customers, error: customerError } = await client.from('customers').select('id,name').in('id', customerIds)
    if (customerError) throw new Error('ADMIN_PACKAGES_CUSTOMER_QUERY_FAILED')
    for (const customer of customers ?? []) customerMap.set(String(customer.id), { id: String(customer.id), name: customer.name ?? null })
  }

  const rows = (data ?? []).map((row) => {
    const totalSeconds = Number(row.total_seconds ?? 0)
    const availableSeconds = Number(row.available_seconds ?? 0)
    return {
      id: row.hour_package_id,
      customer_id: row.customer_id,
      customer: customerMap.get(String(row.customer_id)) ?? null,
      name: row.name,
      status: row.status,
      total_minutes: Number(row.total_minutes ?? 0),
      total_seconds: totalSeconds,
      consumed_seconds: Math.max(totalSeconds - availableSeconds, 0),
      available_minutes: Number(row.available_minutes ?? 0),
      available_seconds: availableSeconds,
      purchased_value: Number(row.purchased_value ?? 0),
      reference_minute_value: Number(row.reference_minute_value ?? 0),
      valid_from: row.valid_from,
      valid_until: row.valid_until,
    }
  })

  return json({
    filters: { customer_id: customerId, status: rawStatus || null },
    pagination: { page, limit, total: count ?? rows.length, total_pages: Math.ceil((count ?? rows.length) / limit) },
    packages: rows,
  })
}

async function packageLedger(req: Request, packageIdRaw: string): Promise<Response> {
  await requireAdminPermission(req, 'PACKAGES_VIEW')
  const packageId = uuid(packageIdRaw, 'PACKAGE_ID_INVALID')
  const client = adminClient()

  const [{ data: balance, error: balanceError }, { data: entries, error: entriesError }] = await Promise.all([
    client
      .from('hour_package_balances')
      .select('hour_package_id,customer_id,name,total_seconds,available_seconds,valid_from,valid_until,status')
      .eq('hour_package_id', packageId)
      .maybeSingle(),
    client
      .from('hour_package_statement_entries')
      .select('movement_id,ledger_seq,registered_at,movement_type,movement_label,direction,appointment_id,appointment_code,service_name,service_start_at,service_end_at,nominal_seconds,nominal_time,surcharge_seconds,surcharge_time,is_special_period,special_surcharge_percent,debited_seconds,debited_time,credited_seconds,credited_time,seconds_delta,signed_movement_time,balance_after_seconds,balance_after_time,reason,created_by_admin_id')
      .eq('hour_package_id', packageId)
      .order('ledger_seq', { ascending: true }),
  ])

  if (balanceError) throw new Error('ADMIN_PACKAGE_BALANCE_QUERY_FAILED')
  if (!balance) return json({ error: { code: 'PACKAGE_NOT_FOUND' } }, 404)
  if (entriesError) throw new Error('ADMIN_PACKAGE_LEDGER_QUERY_FAILED')

  return json({
    package: {
      id: balance.hour_package_id,
      customer_id: balance.customer_id,
      name: balance.name,
      status: balance.status,
      total_seconds: Number(balance.total_seconds ?? 0),
      available_seconds: Number(balance.available_seconds ?? 0),
      valid_from: balance.valid_from,
      valid_until: balance.valid_until,
    },
    ledger: (entries ?? []).map((entry) => ({
      ...entry,
      nominal_seconds: Number(entry.nominal_seconds ?? 0),
      surcharge_seconds: Number(entry.surcharge_seconds ?? 0),
      debited_seconds: Number(entry.debited_seconds ?? 0),
      credited_seconds: Number(entry.credited_seconds ?? 0),
      seconds_delta: Number(entry.seconds_delta ?? 0),
      balance_after_seconds: Number(entry.balance_after_seconds ?? 0),
      special_surcharge_percent: Number(entry.special_surcharge_percent ?? 0),
    })),
  })
}

async function rechargePackage(req: Request): Promise<Response> {
  const admin = await requireAdminPermission(req, 'PACKAGES_MANAGE')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
  if (action !== 'RECHARGE') throw new Error('PACKAGE_ACTION_INVALID')

  const customerId = uuid(body.customer_id, 'CUSTOMER_ID_INVALID')
  const hours = Number(body.hours)
  const paidAmount = Number(body.paid_amount)
  if (!Number.isFinite(hours) || hours <= 0 || Math.round(hours * 60) <= 0) throw new Error('PACKAGE_RECHARGE_HOURS_INVALID')
  if (!Number.isFinite(paidAmount) || paidAmount <= 0) throw new Error('PACKAGE_RECHARGE_AMOUNT_INVALID')
  const addedMinutes = Math.round(hours * 60)
  const notes = typeof body.notes === 'string' ? body.notes.trim() || null : null

  const client = adminClient()
  const { data, error } = await client.rpc('service_admin_recharge_hour_package', {
    p_customer_id: customerId,
    p_added_minutes: addedMinutes,
    p_paid_amount: paidAmount,
    p_admin_id: admin.adminId,
    p_notes: notes,
  })
  if (error) throw new Error(error.message || 'PACKAGE_RECHARGE_FAILED')
  return json(data, 201)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const url = new URL(req.url)
    const ledgerPackageId = packageIdFromLedgerPath(url.pathname)
    if (req.method === 'GET' && ledgerPackageId) return await packageLedger(req, ledgerPackageId)
    if (req.method === 'GET' && url.pathname.replace(/\/+$/, '').endsWith('/admin-hour-packages')) return await listPackages(req, url)
    if (req.method === 'POST' && url.pathname.replace(/\/+$/, '').endsWith('/admin-hour-packages')) return await rechargePackage(req)
    if (!['GET', 'POST'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_PACKAGES_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'PACKAGE_NOT_FOUND' || code === 'PACKAGE_CUSTOMER_NOT_FOUND' ? 404 : 400
    return json({ error: { code } }, status)
  }
})
