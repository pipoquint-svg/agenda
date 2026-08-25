import { adminClient, errorResponse, jsonResponse, requireAdminPermission } from '../_shared/supabase.ts'

const INTERNAL_CALL_TIMEOUT_MS = 20_000

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}

function envPresent(name: string): boolean {
  return Boolean(Deno.env.get(name)?.trim())
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function uuid(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) {
    throw new Error(code)
  }
  return text
}

async function invokeInternal(name: string, body: unknown): Promise<Record<string, unknown>> {
  const base = requiredEnv('SUPABASE_URL').replace(/\/$/, '')
  const secret = requiredEnv('INTEGRATION_INTERNAL_SECRET')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), INTERNAL_CALL_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/${name}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': secret,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
    const text = await response.text()
    if (!response.ok) throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_HTTP_${response.status}`)
    if (!text) return {}
    return JSON.parse(text) as Record<string, unknown>
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_TIMEOUT`)
    throw error
  } finally {
    clearTimeout(timer)
  }
}

async function readModel(req: Request): Promise<Response> {
  await requireAdminPermission(req, 'INTEGRATIONS_VIEW')
  const client = adminClient()

  const [connectionsResult, calendarsResult, mappingsResult, resourcesResult, syncResult] = await Promise.all([
    client.from('google_connections')
      .select('id,account_email,status,last_error,connected_at,updated_at')
      .order('connected_at', { ascending: false }),
    client.from('google_calendars')
      .select('id,google_connection_id,google_calendar_id,name,timezone,access_role,is_primary,is_active,block_all_day_events,ignore_transparent_events,ignore_declined_events')
      .order('name'),
    client.from('google_calendar_resources').select('google_calendar_id,resource_id'),
    client.from('resources').select('id,name,resource_type,is_active').eq('is_active', true).order('name'),
    client.from('google_sync_state')
      .select('google_calendar_id,health_status,last_attempt_at,last_success_at,last_full_sync_at,consecutive_failures,last_error,updated_at'),
  ])

  for (const result of [connectionsResult, calendarsResult, mappingsResult, resourcesResult, syncResult]) {
    if (result.error) throw new Error('GOOGLE_ADMIN_READ_FAILED')
  }

  const syncByCalendar = new Map((syncResult.data ?? []).map((row: any) => [row.google_calendar_id, row]))
  const mappingsByCalendar = new Map<string, string[]>()
  for (const row of mappingsResult.data ?? []) {
    const list = mappingsByCalendar.get(row.google_calendar_id) ?? []
    list.push(row.resource_id)
    mappingsByCalendar.set(row.google_calendar_id, list)
  }

  const requiredSecrets = [
    'GOOGLE_CLIENT_ID',
    'GOOGLE_CLIENT_SECRET',
    'GOOGLE_REDIRECT_URI',
    'GOOGLE_OAUTH_SUCCESS_URL',
    'GOOGLE_TOKEN_ENCRYPTION_KEY',
    'GOOGLE_ALLOWED_ACCOUNT_EMAIL',
    'GOOGLE_TEST_CALENDAR_PREFIX',
    'GOOGLE_WEBHOOK_URL',
  ]

  return jsonResponse({
    enabled: envEnabled('GOOGLE_INTEGRATION_ENABLED'),
    oauth_ready: requiredSecrets.every(envPresent),
    configuration: Object.fromEntries(requiredSecrets.map((name) => [name.toLowerCase(), envPresent(name)])),
    connections: connectionsResult.data ?? [],
    calendars: (calendarsResult.data ?? []).map((calendar: any) => ({
      ...calendar,
      writable: calendar.access_role === 'writer' || calendar.access_role === 'owner',
      mapped_resource_ids: mappingsByCalendar.get(calendar.id) ?? [],
      sync: syncByCalendar.get(calendar.id) ?? null,
    })),
    resources: resourcesResult.data ?? [],
  })
}

async function manage(req: Request): Promise<Response> {
  const { adminId } = await requireAdminPermission(req, 'INTEGRATIONS_MANAGE')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
  const client = adminClient()

  if (action === 'MAP') {
    const calendarId = uuid(body.google_calendar_id, 'GOOGLE_CALENDAR_ID_INVALID')
    const resourceId = uuid(body.resource_id, 'RESOURCE_ID_INVALID')
    const prefix = requiredEnv('GOOGLE_TEST_CALENDAR_PREFIX')

    const { data: calendar, error } = await client
      .from('google_calendars')
      .select('id,name,access_role,is_active,google_connection_id')
      .eq('id', calendarId)
      .maybeSingle()
    if (error || !calendar || !calendar.is_active) throw new Error('GOOGLE_CALENDAR_NOT_ACTIVE')
    if (!(calendar.access_role === 'writer' || calendar.access_role === 'owner')) throw new Error('GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED')
    if (!calendar.name.toLocaleUpperCase('pt-BR').startsWith(prefix.toLocaleUpperCase('pt-BR'))) {
      throw new Error('GOOGLE_TEST_CALENDAR_PREFIX_REQUIRED')
    }

    const { data, error: mapError } = await client.rpc('service_admin_add_google_calendar_resource_mapping', {
      p_google_calendar_id: calendarId,
      p_resource_id: resourceId,
      p_admin_user_id: adminId,
    })
    if (mapError) throw new Error(mapError.message || 'GOOGLE_CALENDAR_MAPPING_FAILED')
    return jsonResponse({ ok: true, state: data })
  }

  if (action === 'UNMAP') {
    const calendarId = uuid(body.google_calendar_id, 'GOOGLE_CALENDAR_ID_INVALID')
    const resourceId = uuid(body.resource_id, 'RESOURCE_ID_INVALID')
    const reason = typeof body.reason === 'string' && body.reason.trim() ? body.reason.trim() : 'ADMIN_UNMAP'
    const { data, error } = await client.rpc('service_admin_remove_google_calendar_resource_mapping', {
      p_google_calendar_id: calendarId,
      p_resource_id: resourceId,
      p_admin_user_id: adminId,
      p_reason: reason,
    })
    if (error) throw new Error(error.message || 'GOOGLE_CALENDAR_UNMAP_FAILED')
    return jsonResponse({ ok: true, state: data })
  }

  if (action === 'FULL_SYNC' || action === 'WATCH') {
    const calendarId = uuid(body.google_calendar_id, 'GOOGLE_CALENDAR_ID_INVALID')
    const { data: mapping, error: mappingError } = await client
      .from('google_calendar_resources')
      .select('google_calendar_id')
      .eq('google_calendar_id', calendarId)
      .limit(1)
    if (mappingError || !mapping?.length) throw new Error('GOOGLE_CALENDAR_NOT_MAPPED')

    const state = action === 'FULL_SYNC'
      ? await invokeInternal('google-sync', { google_calendar_id: calendarId, force_full: true })
      : await invokeInternal('google-watch', { google_calendar_id: calendarId })

    const { error: auditError } = await client.from('audit_logs').insert({
      admin_user_id: adminId,
      entity_type: 'GOOGLE_CALENDAR',
      entity_id: calendarId,
      action: action === 'FULL_SYNC' ? 'GOOGLE_FULL_SYNC_REQUESTED' : 'GOOGLE_WATCH_REQUESTED',
      after_json: { result: state },
      origin: 'ADMIN',
    })
    if (auditError) throw new Error('GOOGLE_ADMIN_AUDIT_FAILED')
    return jsonResponse({ ok: true, state })
  }

  throw new Error('GOOGLE_ADMIN_ACTION_INVALID')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204 })
  try {
    if (req.method === 'GET') return await readModel(req)
    if (req.method === 'POST') return await manage(req)
    return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'GOOGLE_ADMIN_FAILED'
    const status = code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.startsWith('ADMIN_') ? 401
      : code.startsWith('MISSING_ENV') ? 503
      : 400
    return errorResponse(error, status)
  }
})
