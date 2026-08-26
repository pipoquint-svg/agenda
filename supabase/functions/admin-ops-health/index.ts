import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}

function countBy(rows: Array<Record<string, unknown>>, keys: string[]): Record<string, number> {
  const result: Record<string, number> = {}
  for (const row of rows) {
    const key = keys.map((field) => String(row[field] ?? 'UNKNOWN')).join(':')
    result[key] = (result[key] ?? 0) + 1
  }
  return result
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'INTEGRATIONS_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const client = adminClient()
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()

    const [
      integrationJobs,
      notificationLogs,
      birthdaySettings,
      birthdayCycles,
      activeServices,
      activePolicies,
      nullScopeServices,
      nullScopeCategories,
    ] = await Promise.all([
      client.from('integration_jobs')
        .select('job_type,status,last_error,created_at,processed_at')
        .gte('created_at', since)
        .order('created_at', { ascending: false })
        .limit(1000),
      client.from('notification_delivery_logs')
        .select('event_key,channel,audience,status,last_error_code,created_at,updated_at')
        .gte('created_at', since)
        .order('created_at', { ascending: false })
        .limit(1000),
      client.from('birthday_automation_settings')
        .select('operation_scope,is_active,send_message,generate_coupon,send_on_birthday,days_before,updated_at')
        .order('operation_scope'),
      client.from('birthday_automation_cycles')
        .select('operation_scope,trigger_kind,target_date,created_at')
        .gte('created_at', since)
        .order('created_at', { ascending: false })
        .limit(1000),
      client.from('services').select('id').eq('is_active', true),
      client.from('service_change_policies').select('service_id'),
      client.from('services').select('id,name,slug,is_active').is('operation_scope', null),
      client.from('categories').select('id,name,slug,is_active').is('operation_scope', null),
    ])

    const failures = [integrationJobs, notificationLogs, birthdaySettings, birthdayCycles, activeServices, activePolicies, nullScopeServices, nullScopeCategories]
      .map((response) => response.error)
      .filter(Boolean)
    if (failures.length > 0) throw new Error('ADMIN_OPS_HEALTH_QUERY_FAILED')

    const jobs = (integrationJobs.data ?? []) as Array<Record<string, unknown>>
    const notifications = (notificationLogs.data ?? []) as Array<Record<string, unknown>>
    const cycles = (birthdayCycles.data ?? []) as Array<Record<string, unknown>>
    const policyIds = new Set((activePolicies.data ?? []).map((row) => String(row.service_id)))
    const activeWithoutPolicy = (activeServices.data ?? []).filter((row) => !policyIds.has(String(row.id))).length

    const recentJobFailures = jobs
      .filter((row) => row.status === 'FAILED')
      .slice(0, 20)
      .map((row) => ({
        job_type: row.job_type,
        error_code: typeof row.last_error === 'string' ? row.last_error.split(':')[0].slice(0, 80) : null,
        created_at: row.created_at,
      }))

    const recentNotificationFailures = notifications
      .filter((row) => row.status === 'FAILED')
      .slice(0, 20)
      .map((row) => ({
        event_key: row.event_key,
        channel: row.channel,
        audience: row.audience,
        error_code: typeof row.last_error_code === 'string' ? row.last_error_code.split(':')[0].slice(0, 80) : null,
        created_at: row.created_at,
      }))

    return json({
      generated_at: new Date().toISOString(),
      window_hours: 24,
      runtime_gates: {
        google_enabled: envEnabled('GOOGLE_INTEGRATION_ENABLED'),
        transactional_email_enabled: envEnabled('TRANSACTIONAL_EMAIL_ENABLED'),
        transactional_email_worker_enabled: envEnabled('TRANSACTIONAL_EMAIL_WORKER_ENABLED'),
        notification_templates_runtime_enabled: envEnabled('NOTIFICATION_TEMPLATES_RUNTIME_ENABLED'),
        real_email_recipients_allowed: envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS'),
        real_charges_allowed: envEnabled('ALLOW_REAL_CHARGES'),
      },
      integration_jobs: {
        counts: countBy(jobs, ['job_type', 'status']),
        pending: jobs.filter((row) => row.status === 'PENDING').length,
        processing: jobs.filter((row) => row.status === 'PROCESSING').length,
        recent_failures: recentJobFailures,
      },
      notifications: {
        counts: countBy(notifications, ['event_key', 'channel', 'status']),
        pending: notifications.filter((row) => row.status === 'PENDING').length,
        recent_failures: recentNotificationFailures,
      },
      birthday: {
        settings: birthdaySettings.data ?? [],
        cycles_last_24h: countBy(cycles, ['operation_scope', 'trigger_kind']),
        total_cycles_last_24h: cycles.length,
      },
      structural_gates: {
        active_services_without_change_policy: activeWithoutPolicy,
        services_without_operation_scope: nullScopeServices.data ?? [],
        categories_without_operation_scope: nullScopeCategories.data ?? [],
      },
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_OPS_HEALTH_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
