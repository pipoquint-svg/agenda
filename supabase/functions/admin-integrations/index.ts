import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

type IntegrationStatus = 'CONNECTED' | 'PENDING' | 'BACKEND_ONLY'

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}

function envPresent(name: string): boolean {
  return Boolean((Deno.env.get(name) ?? '').trim())
}

function boundedInt(url: URL, key: string, fallback: number, min: number, max: number): number {
  const raw = url.searchParams.get(key)
  if (!raw) return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`INTEGRATIONS_${key.toUpperCase()}_INVALID`)
  return value
}

function safeErrorCode(value: unknown): string | null {
  if (typeof value !== 'string' || !value.trim()) return null
  return value.trim().split(':')[0].slice(0, 80)
}

function latestIso(values: unknown[]): string | null {
  const dates = values
    .filter((value): value is string => typeof value === 'string' && !Number.isNaN(Date.parse(value)))
    .sort((a, b) => Date.parse(b) - Date.parse(a))
  return dates[0] ?? null
}

function row(key: string, label: string, status: IntegrationStatus, lastSyncAt: string | null, detail: Record<string, unknown>) {
  return { key, label, status, last_sync_at: lastSyncAt, detail }
}

async function integrationSummary(req: Request): Promise<Response> {
  await requireAdminPermission(req, 'INTEGRATIONS_VIEW')
  const client = adminClient()

  const [connectionsResult, syncResult, kommoResult, jobsResult, notificationsResult] = await Promise.all([
    client.from('google_connections')
      .select('id,status,connected_at,updated_at,last_error')
      .order('connected_at', { ascending: false })
      .limit(20),
    client.from('google_sync_state')
      .select('health_status,last_attempt_at,last_success_at,last_full_sync_at,consecutive_failures')
      .order('updated_at', { ascending: false })
      .limit(100),
    client.from('kommo_integration_settings')
      .select('enabled,operation_scope,pipeline_id,stage_initial_contact_id,stage_awaiting_payment_id,stage_confirmed_id,stage_rescheduled_id,stage_cancelled_id,stage_completed_id,stage_no_show_id,stage_expired_id,booking_mailbox,updated_at')
      .maybeSingle(),
    client.from('integration_jobs')
      .select('job_type,status,processed_at,updated_at')
      .order('updated_at', { ascending: false })
      .limit(500),
    client.from('notification_delivery_logs')
      .select('status,updated_at')
      .order('updated_at', { ascending: false })
      .limit(200),
  ])

  const failures = [connectionsResult.error, syncResult.error, kommoResult.error, jobsResult.error, notificationsResult.error].filter(Boolean)
  if (failures.length) throw new Error('ADMIN_INTEGRATIONS_QUERY_FAILED')

  const googleConnections = connectionsResult.data ?? []
  const googleSync = syncResult.data ?? []
  const googleEnabled = envEnabled('GOOGLE_INTEGRATION_ENABLED')
  const googleReady = [
    'GOOGLE_CLIENT_ID','GOOGLE_CLIENT_SECRET','GOOGLE_REDIRECT_URI','GOOGLE_TOKEN_ENCRYPTION_KEY','GOOGLE_WEBHOOK_URL',
  ].every(envPresent)
  const googleActive = googleConnections.some((item) => item.status === 'ACTIVE')
  const googleLastSync = latestIso(googleSync.flatMap((item) => [item.last_success_at, item.last_full_sync_at]))
  const googleStatus: IntegrationStatus = googleEnabled && googleActive ? 'CONNECTED' : googleReady || googleActive ? 'BACKEND_ONLY' : 'PENDING'

  const mpConfigured = envPresent('MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN') || envPresent('MERCADO_PAGO_ACCESS_TOKEN')
  const mpRealAllowed = envEnabled('ALLOW_REAL_CHARGES')
  const mpJobs = (jobsResult.data ?? []).filter((job) => String(job.job_type ?? '').toUpperCase().includes('PAYMENT') || String(job.job_type ?? '').toUpperCase().includes('MERCADO'))
  const mpLastSync = latestIso(mpJobs.flatMap((job) => [job.processed_at, job.updated_at]))
  const mpStatus: IntegrationStatus = mpConfigured && mpRealAllowed ? 'CONNECTED' : mpConfigured ? 'BACKEND_ONLY' : 'PENDING'

  const kommo = kommoResult.data
  const kommoStagesConfigured = Boolean(
    kommo?.pipeline_id && kommo.stage_initial_contact_id && kommo.stage_awaiting_payment_id && kommo.stage_confirmed_id &&
    kommo.stage_rescheduled_id && kommo.stage_cancelled_id && kommo.stage_completed_id && kommo.stage_no_show_id && kommo.stage_expired_id,
  )
  const kommoConfigured = Boolean(kommoStagesConfigured && kommo?.booking_mailbox && envPresent('KOMMO_ACCESS_TOKEN'))
  const kommoJobs = (jobsResult.data ?? []).filter((job) => String(job.job_type ?? '').toUpperCase().includes('KOMMO'))
  const kommoLastSync = latestIso(kommoJobs.flatMap((job) => [job.processed_at, job.updated_at]))
  const kommoStatus: IntegrationStatus = kommo?.enabled === true && kommoConfigured ? 'CONNECTED' : kommoConfigured || kommoStagesConfigured ? 'BACKEND_ONLY' : 'PENDING'

  const notificationsConfigured = envPresent('RESEND_API_KEY') && envPresent('EMAIL_FROM_BLACKSHEEP')
  const notificationsEnabled = envEnabled('TRANSACTIONAL_EMAIL_ENABLED')
  const notificationLastSync = latestIso((notificationsResult.data ?? []).map((item) => item.updated_at))
  const notificationStatus: IntegrationStatus = notificationsConfigured && notificationsEnabled ? 'CONNECTED' : notificationsConfigured ? 'BACKEND_ONLY' : 'PENDING'

  return json({
    integrations: [
      row('google', 'Google Calendar', googleStatus, googleLastSync, {
        enabled: googleEnabled,
        configured: googleReady,
        active_connection_count: googleConnections.filter((item) => item.status === 'ACTIVE').length,
        unhealthy_calendar_count: googleSync.filter((item) => item.health_status && item.health_status !== 'HEALTHY').length,
      }),
      row('mercado-pago', 'Mercado Pago', mpStatus, mpLastSync, {
        configured: mpConfigured,
        real_charges_allowed: mpRealAllowed,
      }),
      row('kommo', 'Kommo', kommoStatus, kommoLastSync, {
        enabled: kommo?.enabled === true,
        operation_scope: kommo?.operation_scope ?? null,
        pipeline_configured: kommoStagesConfigured,
        booking_mailbox_configured: Boolean(kommo?.booking_mailbox),
      }),
      row('notifications', 'Notificações', notificationStatus, notificationLastSync, {
        configured: notificationsConfigured,
        enabled: notificationsEnabled,
        worker_enabled: envEnabled('TRANSACTIONAL_EMAIL_WORKER_ENABLED'),
        real_recipients_allowed: envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS'),
      }),
    ],
    safety: {
      credentials_exposed: false,
      providers_mutated: false,
    },
    generated_at: new Date().toISOString(),
  })
}

async function syncFailures(req: Request, url: URL): Promise<Response> {
  await requireAdminPermission(req, 'INTEGRATIONS_VIEW')
  const client = adminClient()
  const page = boundedInt(url, 'page', 1, 1, 100000)
  const limit = boundedInt(url, 'limit', 50, 1, 100)
  const offset = (page - 1) * limit

  const { data, error, count } = await client
    .from('integration_jobs')
    .select('id,job_type,entity_type,entity_id,status,attempt_count,max_attempts,last_error,created_at,updated_at,processed_at', { count: 'exact' })
    .eq('status', 'FAILED')
    .order('updated_at', { ascending: false })
    .range(offset, offset + limit - 1)

  if (error) throw new Error('ADMIN_INTEGRATION_FAILURES_QUERY_FAILED')
  const total = count ?? data?.length ?? 0

  return json({
    pagination: { page, limit, total, total_pages: total === 0 ? 0 : Math.ceil(total / limit) },
    failures: (data ?? []).map((item) => ({
      id: item.id,
      integration: String(item.job_type ?? '').split('_')[0]?.toLowerCase() || 'unknown',
      job_type: item.job_type,
      entity_type: item.entity_type,
      entity_id: item.entity_id,
      appointment_id: item.entity_type === 'APPOINTMENT' ? item.entity_id : null,
      error_code: safeErrorCode(item.last_error),
      occurred_at: item.updated_at ?? item.created_at,
      attempt_count: item.attempt_count,
      max_attempts: item.max_attempts,
      retriable: Number(item.attempt_count ?? 0) < Number(item.max_attempts ?? 0),
    })),
    redaction: { raw_provider_errors_included: false, payloads_included: false },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const url = new URL(req.url)
    if (url.pathname.replace(/\/+$/, '').endsWith('/admin-integrations/sync-failures')) return await syncFailures(req, url)
    if (url.pathname.replace(/\/+$/, '').endsWith('/admin-integrations')) return await integrationSummary(req)
    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_INTEGRATIONS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
