import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

type View = 'finance' | 'packages' | 'audit' | 'team' | 'integrations'

const permissionByView: Record<View, string> = {
  finance: 'FINANCE_VIEW',
  packages: 'PACKAGES_VIEW',
  audit: 'AUDIT_VIEW',
  team: 'TEAM_MANAGE',
  integrations: 'INTEGRATIONS_VIEW',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function parseView(url: URL): View {
  const raw = url.searchParams.get('view')?.trim().toLowerCase() ?? ''
  if (!['finance', 'packages', 'audit', 'team', 'integrations'].includes(raw)) {
    throw new Error('ADMIN_READ_VIEW_INVALID')
  }
  return raw as View
}

function boundedInt(url: URL, key: string, fallback: number, min: number, max: number): number {
  const raw = url.searchParams.get(key)
  if (raw == null || raw.trim() === '') return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return value
}

function optionalIso(url: URL, key: string): string | null {
  const raw = url.searchParams.get(key)?.trim() ?? ''
  if (!raw) return null
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

function safeProviderError(value: unknown): string | null {
  if (typeof value !== 'string' || !value.trim()) return null
  return value.trim().split(':')[0].slice(0, 80)
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}

function envPresent(name: string): boolean {
  return Boolean((Deno.env.get(name) ?? '').trim())
}

async function financeView(url: URL) {
  const client = adminClient()
  const limit = boundedInt(url, 'limit', 50, 1, 100)
  const offset = boundedInt(url, 'offset', 0, 0, 10000)
  const startAt = optionalIso(url, 'start_at')
  const endAt = optionalIso(url, 'end_at')

  let query = client
    .from('payment_transactions')
    .select('id,appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,payment_discount_amount,cash_amount,paid_at,created_at,payment_purpose', { count: 'exact' })
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (startAt) query = query.gte('created_at', startAt)
  if (endAt) query = query.lt('created_at', endAt)

  const { data: transactions, error, count } = await query
  if (error) throw new Error('ADMIN_FINANCE_QUERY_FAILED')

  const appointmentIds = [...new Set((transactions ?? []).map((row) => row.appointment_id).filter(Boolean))]
  const appointmentMap = new Map<string, Record<string, unknown>>()
  if (appointmentIds.length) {
    const { data, error: appointmentError } = await client
      .from('appointments')
      .select('id,public_code,status,financial_status,start_at,service_name_snapshot,commercial_value')
      .in('id', appointmentIds)
    if (appointmentError) throw new Error('ADMIN_FINANCE_APPOINTMENT_QUERY_FAILED')
    for (const row of data ?? []) appointmentMap.set(row.id, row)
  }

  const rows = (transactions ?? []).map((row) => ({
    ...row,
    appointment: appointmentMap.get(row.appointment_id) ?? null,
  }))

  const totals = rows.reduce((acc, row) => {
    const amount = Number(row.cash_amount ?? 0)
    if (row.status === 'APPROVED') acc.approved_cash += amount
    if (row.status === 'PENDING') acc.pending_cash += amount
    if (row.status === 'REJECTED') acc.rejected_count += 1
    return acc
  }, { approved_cash: 0, pending_cash: 0, rejected_count: 0 })

  return { view: 'finance', total: count ?? rows.length, limit, offset, totals, rows, generated_at: new Date().toISOString() }
}

async function packagesView(url: URL) {
  const client = adminClient()
  const limit = boundedInt(url, 'limit', 50, 1, 100)
  const offset = boundedInt(url, 'offset', 0, 0, 10000)
  const status = url.searchParams.get('status')?.trim().toUpperCase() ?? ''

  let query = client
    .from('hour_package_balances')
    .select('hour_package_id,customer_id,name,total_seconds,purchased_value,reference_minute_value,ledger_seconds,available_seconds,valid_from,valid_until,status', { count: 'exact' })
    .order('valid_until', { ascending: true, nullsFirst: false })
    .range(offset, offset + limit - 1)

  if (status) query = query.eq('status', status)
  const { data: packages, error, count } = await query
  if (error) throw new Error('ADMIN_PACKAGES_QUERY_FAILED')

  const customerIds = [...new Set((packages ?? []).map((row) => row.customer_id).filter(Boolean))]
  const customerMap = new Map<string, { id: string; name: string }>()
  if (customerIds.length) {
    const { data, error: customerError } = await client.from('customers').select('id,name').in('id', customerIds)
    if (customerError) throw new Error('ADMIN_PACKAGES_CUSTOMER_QUERY_FAILED')
    for (const row of data ?? []) customerMap.set(row.id, row)
  }

  const rows = (packages ?? []).map((row) => ({
    ...row,
    customer: customerMap.get(row.customer_id) ?? null,
  }))

  return { view: 'packages', total: count ?? rows.length, limit, offset, rows, generated_at: new Date().toISOString() }
}

async function auditView(url: URL) {
  const client = adminClient()
  const limit = boundedInt(url, 'limit', 50, 1, 100)
  const offset = boundedInt(url, 'offset', 0, 0, 10000)
  const entityType = url.searchParams.get('entity_type')?.trim().toUpperCase() ?? ''
  const action = url.searchParams.get('action')?.trim().toUpperCase() ?? ''

  let query = client
    .from('audit_logs')
    .select('id,admin_user_id,entity_type,entity_id,action,origin,request_id,created_at', { count: 'exact' })
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (entityType) query = query.eq('entity_type', entityType)
  if (action) query = query.eq('action', action)
  const { data, error, count } = await query
  if (error) throw new Error('ADMIN_AUDIT_QUERY_FAILED')

  return { view: 'audit', total: count ?? data?.length ?? 0, limit, offset, rows: data ?? [], generated_at: new Date().toISOString() }
}

async function teamView() {
  const client = adminClient()
  const [{ data: users, error: usersError }, { data: overrides, error: overridesError }] = await Promise.all([
    client.from('admin_users').select('id,display_name,role,is_active,created_at,updated_at').order('display_name'),
    client.from('admin_user_permissions').select('admin_user_id,permission,is_granted,updated_by_admin_id,updated_at').order('permission'),
  ])
  if (usersError) throw new Error('ADMIN_TEAM_USERS_QUERY_FAILED')
  if (overridesError) throw new Error('ADMIN_TEAM_PERMISSIONS_QUERY_FAILED')

  const byAdmin = new Map<string, unknown[]>()
  for (const row of overrides ?? []) {
    const current = byAdmin.get(row.admin_user_id) ?? []
    current.push({ permission: row.permission, is_granted: row.is_granted, updated_by_admin_id: row.updated_by_admin_id, updated_at: row.updated_at })
    byAdmin.set(row.admin_user_id, current)
  }

  return {
    view: 'team',
    rows: (users ?? []).map((user) => ({ ...user, permission_overrides: byAdmin.get(user.id) ?? [] })),
    generated_at: new Date().toISOString(),
  }
}

async function integrationsView() {
  const client = adminClient()
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
  const [{ data: jobs, error: jobsError }, { data: kommo, error: kommoError }] = await Promise.all([
    client
      .from('integration_jobs')
      .select('job_type,status,attempt_count,max_attempts,last_error,created_at,processed_at')
      .gte('created_at', since)
      .order('created_at', { ascending: false })
      .limit(500),
    client
      .from('kommo_integration_settings')
      .select('enabled,operation_scope,pipeline_id,stage_initial_contact_id,stage_awaiting_payment_id,stage_confirmed_id,stage_rescheduled_id,stage_cancelled_id,stage_completed_id,stage_no_show_id,stage_expired_id,booking_mailbox')
      .maybeSingle(),
  ])
  if (jobsError) throw new Error('ADMIN_INTEGRATIONS_JOBS_QUERY_FAILED')
  if (kommoError) throw new Error('ADMIN_INTEGRATIONS_KOMMO_QUERY_FAILED')

  const summary: Record<string, Record<string, number>> = {}
  const recentFailures: Array<Record<string, unknown>> = []
  for (const job of jobs ?? []) {
    const type = String(job.job_type)
    const state = String(job.status)
    summary[type] ??= {}
    summary[type][state] = (summary[type][state] ?? 0) + 1
    if (state === 'FAILED' && recentFailures.length < 20) {
      recentFailures.push({
        job_type: type,
        attempt_count: job.attempt_count,
        max_attempts: job.max_attempts,
        error_code: safeProviderError(job.last_error),
        created_at: job.created_at,
      })
    }
  }

  const kommoStagesConfigured = Boolean(
    kommo?.pipeline_id && kommo.stage_initial_contact_id && kommo.stage_awaiting_payment_id && kommo.stage_confirmed_id &&
    kommo.stage_rescheduled_id && kommo.stage_cancelled_id && kommo.stage_completed_id && kommo.stage_no_show_id && kommo.stage_expired_id,
  )

  return {
    view: 'integrations',
    providers: {
      email: {
        configured: envPresent('RESEND_API_KEY') && envPresent('EMAIL_FROM_BLACKSHEEP'),
        enabled: envEnabled('TRANSACTIONAL_EMAIL_ENABLED'),
        worker_enabled: envEnabled('TRANSACTIONAL_EMAIL_WORKER_ENABLED'),
      },
      mercado_pago: {
        configured: envPresent('MERCADO_PAGO_ACCESS_TOKEN'),
        real_charges_allowed: envEnabled('ALLOW_REAL_CHARGES'),
      },
      kommo: {
        enabled: kommo?.enabled === true,
        operation_scope: kommo?.operation_scope ?? null,
        pipeline_configured: kommoStagesConfigured,
        booking_mailbox_configured: Boolean(kommo?.booking_mailbox),
      },
      google: {
        enabled: envEnabled('GOOGLE_INTEGRATION_ENABLED'),
        connected_state_not_probed: true,
      },
    },
    jobs_last_24h: summary,
    recent_failures: recentFailures,
    generated_at: new Date().toISOString(),
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const url = new URL(req.url)
    const view = parseView(url)
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, permissionByView[view]))) throw new Error('ADMIN_PERMISSION_DENIED')

    const data = view === 'finance' ? await financeView(url)
      : view === 'packages' ? await packagesView(url)
      : view === 'audit' ? await auditView(url)
      : view === 'team' ? await teamView()
      : await integrationsView()

    return json(data)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_READ_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
