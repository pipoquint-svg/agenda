import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, normalizeGoogleEvent, refreshAccessToken } from '../_shared/google.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const INTERNAL_CALL_TIMEOUT_MS = 20_000

type MutationScope = 'THIS' | 'SERIES'

type GoogleEvent = Record<string, any> & {
  id?: string
  etag?: string
  summary?: string
  status?: string
  start?: { dateTime?: string; date?: string; timeZone?: string }
  end?: { dateTime?: string; date?: string; timeZone?: string }
  recurringEventId?: string
  originalStartTime?: { dateTime?: string; date?: string }
}

type EventRow = {
  id: string
  google_calendar_id: string
  google_event_id: string
  recurring_event_id: string | null
  original_start_at: string | null
  original_start_date: string | null
  etag: string | null
  status: string
  summary: string | null
  is_all_day: boolean
  start_at: string | null
  end_at: string | null
  start_date: string | null
  end_date: string | null
  transparency: string | null
  self_response_status: string | null
  managed_by_agenda: boolean
  agenda_appointment_id: string | null
  bs_source: string | null
}

type CalendarRow = {
  id: string
  google_calendar_id: string
  google_connection_id: string
  name: string
  timezone: string | null
  access_role: string | null
  is_active: boolean
}

type ConnectionRow = {
  id: string
  refresh_token_ciphertext: string | null
  status: string
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function clean(value: unknown): string | null {
  const text = typeof value === 'string' ? value.trim() : ''
  return text || null
}

function uuid(value: unknown, code: string): string {
  const text = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) {
    throw new Error(code)
  }
  return text
}

function parseScope(value: unknown, recurring: boolean): MutationScope {
  const scope = (clean(value) ?? 'THIS').toUpperCase()
  if (scope !== 'THIS' && scope !== 'SERIES') throw new Error('EXTERNAL_BLOCK_SCOPE_INVALID')
  if (scope === 'SERIES' && !recurring) throw new Error('EXTERNAL_BLOCK_NOT_RECURRING')
  return scope
}

function requiredIso(value: unknown, code: string): string {
  const text = clean(value)
  if (!text) throw new Error(code)
  const date = new Date(text)
  if (Number.isNaN(date.getTime())) throw new Error(code)
  return date.toISOString()
}

function timedRange(event: GoogleEvent, code: string): { start: string; end: string } {
  const start = event.start?.dateTime
  const end = event.end?.dateTime
  if (typeof start !== 'string' || typeof end !== 'string') throw new Error(code)
  const startMs = Date.parse(start)
  const endMs = Date.parse(end)
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) throw new Error(code)
  return { start, end }
}

function writableRole(role: string | null): boolean {
  return role === 'writer' || role === 'owner'
}

async function loadContext(eventId: string) {
  const client = adminClient()
  const { data: event, error: eventError } = await client
    .from('google_calendar_events')
    .select('id,google_calendar_id,google_event_id,recurring_event_id,original_start_at,original_start_date,etag,status,summary,is_all_day,start_at,end_at,start_date,end_date,transparency,self_response_status,managed_by_agenda,agenda_appointment_id,bs_source')
    .eq('id', eventId)
    .maybeSingle()
  if (eventError || !event) throw new Error('EXTERNAL_BLOCK_NOT_FOUND')

  const typedEvent = event as EventRow
  if (typedEvent.managed_by_agenda || typedEvent.agenda_appointment_id) throw new Error('EXTERNAL_BLOCK_NOT_EXTERNAL')

  const { data: allocations, error: allocationError } = await client
    .from('resource_allocations')
    .select('id,resource_id')
    .eq('google_calendar_event_id', typedEvent.id)
    .eq('allocation_type', 'EXTERNAL_BLOCK')
    .eq('status', 'EXTERNAL_ACTIVE')
    .limit(20)
  if (allocationError || !allocations?.length) throw new Error('EXTERNAL_BLOCK_NOT_ACTIVE')

  const { data: calendar, error: calendarError } = await client
    .from('google_calendars')
    .select('id,google_calendar_id,google_connection_id,name,timezone,access_role,is_active')
    .eq('id', typedEvent.google_calendar_id)
    .maybeSingle()
  if (calendarError || !calendar) throw new Error('EXTERNAL_BLOCK_CALENDAR_NOT_FOUND')

  const typedCalendar = calendar as CalendarRow
  const { data: connection, error: connectionError } = await client
    .from('google_connections')
    .select('id,refresh_token_ciphertext,status')
    .eq('id', typedCalendar.google_connection_id)
    .maybeSingle()
  if (connectionError || !connection) throw new Error('EXTERNAL_BLOCK_CONNECTION_NOT_FOUND')

  return {
    client,
    event: typedEvent,
    calendar: typedCalendar,
    connection: connection as ConnectionRow,
    allocations,
  }
}

async function accessToken(connection: ConnectionRow): Promise<string> {
  if (connection.status !== 'ACTIVE' || !connection.refresh_token_ciphertext) {
    throw new Error('EXTERNAL_BLOCK_GOOGLE_RECONNECT_REQUIRED')
  }
  try {
    const refreshToken = await decryptRefreshToken(connection.refresh_token_ciphertext)
    return (await refreshAccessToken(refreshToken)).access_token
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_TOKEN_REFRESH_FAILED'
    if (code === 'GOOGLE_RECONNECT_REQUIRED') {
      await adminClient().from('google_connections').update({
        status: 'RECONNECT_REQUIRED',
        last_error: code,
        updated_at: new Date().toISOString(),
      }).eq('id', connection.id)
      throw new Error('EXTERNAL_BLOCK_GOOGLE_RECONNECT_REQUIRED')
    }
    throw error
  }
}

function googleEventUrl(calendarId: string, eventId: string): string {
  return `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`
}

async function getGoogleEvent(calendarId: string, eventId: string, token: string): Promise<GoogleEvent> {
  try {
    return await googleJson<GoogleEvent>(googleEventUrl(calendarId, eventId), token)
  } catch (error) {
    const status = (error as Error & { status?: number }).status
    if (status === 404) throw new Error('EXTERNAL_BLOCK_PROVIDER_NOT_FOUND')
    if (status === 403) throw new Error('EXTERNAL_BLOCK_READ_ONLY')
    throw error
  }
}

async function patchGoogleEvent(
  calendarId: string,
  eventId: string,
  token: string,
  etag: string | undefined,
  body: Record<string, unknown>,
): Promise<GoogleEvent> {
  const endpoint = new URL(googleEventUrl(calendarId, eventId))
  endpoint.searchParams.set('sendUpdates', 'none')
  try {
    return await googleJson<GoogleEvent>(endpoint.toString(), token, {
      method: 'PATCH',
      headers: etag ? { 'if-match': etag } : undefined,
      body: JSON.stringify(body),
    })
  } catch (error) {
    const status = (error as Error & { status?: number }).status
    if (status === 412) throw new Error('EXTERNAL_BLOCK_CONFLICT')
    if (status === 404) throw new Error('EXTERNAL_BLOCK_PROVIDER_NOT_FOUND')
    if (status === 403) throw new Error('EXTERNAL_BLOCK_READ_ONLY')
    throw error
  }
}

async function deleteGoogleEvent(
  calendarId: string,
  eventId: string,
  token: string,
  etag: string | undefined,
): Promise<void> {
  const endpoint = new URL(googleEventUrl(calendarId, eventId))
  endpoint.searchParams.set('sendUpdates', 'none')
  try {
    await googleJson<void>(endpoint.toString(), token, {
      method: 'DELETE',
      headers: etag ? { 'if-match': etag } : undefined,
    })
  } catch (error) {
    const status = (error as Error & { status?: number }).status
    if (status === 412) throw new Error('EXTERNAL_BLOCK_CONFLICT')
    if (status === 404 || status === 410) throw new Error('EXTERNAL_BLOCK_PROVIDER_NOT_FOUND')
    if (status === 403) throw new Error('EXTERNAL_BLOCK_READ_ONLY')
    throw error
  }
}

async function applyProviderEventLocally(
  client: ReturnType<typeof adminClient>,
  internalCalendarId: string,
  providerEvent: GoogleEvent,
): Promise<void> {
  const normalized = normalizeGoogleEvent(providerEvent)
  if (!normalized.p_google_event_id) throw new Error('EXTERNAL_BLOCK_PROVIDER_EVENT_INVALID')
  const { error } = await client.rpc('upsert_google_calendar_event', {
    p_google_calendar_id: internalCalendarId,
    ...normalized,
  })
  if (error) throw new Error('EXTERNAL_BLOCK_LOCAL_APPLY_FAILED')
}

async function applyDeletedOccurrenceLocally(
  client: ReturnType<typeof adminClient>,
  event: EventRow,
): Promise<void> {
  const { error } = await client.rpc('upsert_google_calendar_event', {
    p_google_calendar_id: event.google_calendar_id,
    p_google_event_id: event.google_event_id,
    p_status: 'cancelled',
    p_summary: event.summary,
    p_is_all_day: event.is_all_day,
    p_start_at: event.start_at,
    p_end_at: event.end_at,
    p_start_date: event.start_date,
    p_end_date: event.end_date,
    p_transparency: event.transparency,
    p_self_response_status: event.self_response_status,
    p_recurring_event_id: event.recurring_event_id,
    p_original_start_at: event.original_start_at,
    p_original_start_date: event.original_start_date,
    p_etag: null,
    p_google_updated_at: new Date().toISOString(),
    p_managed_by_agenda: false,
    p_agenda_appointment_id: null,
    p_bs_source: event.bs_source,
    p_normalized_payload: {
      id: event.google_event_id,
      status: 'cancelled',
      recurringEventId: event.recurring_event_id,
      originalStartTime: event.original_start_at ? { dateTime: event.original_start_at } : null,
    },
  })
  if (error) throw new Error('EXTERNAL_BLOCK_LOCAL_DELETE_APPLY_FAILED')
}

async function invokeFullSync(calendarId: string): Promise<boolean> {
  const base = Deno.env.get('SUPABASE_URL')?.replace(/\/$/, '')
  const secret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim()
  if (!base || !secret) return false

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), INTERNAL_CALL_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/google-sync`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
      body: JSON.stringify({ google_calendar_id: calendarId, force_full: true }),
      signal: controller.signal,
    })
    return response.ok
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

async function enqueueFullSync(
  client: ReturnType<typeof adminClient>,
  calendarId: string,
  discriminator: string,
): Promise<boolean> {
  const { error } = await client.rpc('enqueue_google_calendar_sync', {
    p_google_calendar_id: calendarId,
    p_idempotency_key: `google-external-admin:${calendarId}:${discriminator}`,
    p_payload_json: { source: 'ADMIN_EXTERNAL_BLOCK_MUTATION', force_full: true },
  })
  return !error
}

async function reconcileAfterProviderMutation(
  client: ReturnType<typeof adminClient>,
  calendarId: string,
  discriminator: string,
  localApply: (() => Promise<void>) | null,
): Promise<{ syncImmediate: boolean; syncQueued: boolean }> {
  if (localApply) {
    try {
      await localApply()
      return { syncImmediate: true, syncQueued: false }
    } catch {
      // O Google já é a fonte de verdade. Se o espelho local falhar, reconciliamos
      // por sync e não induzimos o operador a repetir uma mutação já aceita pelo provider.
    }
  }

  const syncImmediate = await invokeFullSync(calendarId)
  if (syncImmediate) return { syncImmediate: true, syncQueued: false }
  const syncQueued = await enqueueFullSync(client, calendarId, discriminator)
  return { syncImmediate: false, syncQueued }
}

function detailResponse(
  event: EventRow,
  calendar: CalendarRow,
  connection: ConnectionRow,
  resourceCount: number,
) {
  const roleWritable = calendar.is_active && writableRole(calendar.access_role)
  const connectionWritable = connection.status === 'ACTIVE' && Boolean(connection.refresh_token_ciphertext)
  const writable = roleWritable && connectionWritable
  return {
    id: event.id,
    summary: event.summary,
    start_at: event.start_at,
    end_at: event.end_at,
    start_date: event.start_date,
    end_date: event.end_date,
    is_all_day: event.is_all_day,
    recurring: Boolean(event.recurring_event_id),
    recurring_event_id: event.recurring_event_id,
    calendar_name: calendar.name,
    calendar_timezone: calendar.timezone ?? 'America/Sao_Paulo',
    writable,
    timed_edit_supported: writable && !event.is_all_day,
    delete_supported: writable,
    resource_count: resourceCount,
    write_blocker: !roleWritable
      ? 'EXTERNAL_BLOCK_READ_ONLY'
      : !connectionWritable
        ? 'EXTERNAL_BLOCK_GOOGLE_RECONNECT_REQUIRED'
        : null,
  }
}

function mutationAuditSnapshot(event: EventRow) {
  return {
    summary: event.summary,
    start_at: event.start_at,
    end_at: event.end_at,
    recurring_event_id: event.recurring_event_id,
  }
}

async function auditRequested(
  client: ReturnType<typeof adminClient>,
  adminId: string,
  event: EventRow,
  action: 'UPDATE' | 'DELETE',
  before: Record<string, unknown>,
  requested: Record<string, unknown>,
): Promise<void> {
  const { error } = await client.from('audit_logs').insert({
    admin_user_id: adminId,
    entity_type: 'GOOGLE_CALENDAR_EVENT',
    entity_id: event.id,
    action: action === 'UPDATE' ? 'EXTERNAL_BLOCK_UPDATE_REQUESTED' : 'EXTERNAL_BLOCK_DELETE_REQUESTED',
    before_json: before,
    after_json: requested,
    origin: 'ADMIN',
  })
  if (error) throw new Error('EXTERNAL_BLOCK_AUDIT_FAILED')
}

async function auditSucceededBestEffort(
  client: ReturnType<typeof adminClient>,
  adminId: string,
  event: EventRow,
  action: 'UPDATE' | 'DELETE',
  result: Record<string, unknown>,
): Promise<void> {
  await client.from('audit_logs').insert({
    admin_user_id: adminId,
    entity_type: 'GOOGLE_CALENDAR_EVENT',
    entity_id: event.id,
    action: action === 'UPDATE' ? 'EXTERNAL_BLOCK_UPDATED' : 'EXTERNAL_BLOCK_DELETED',
    after_json: result,
    origin: 'ADMIN',
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const { adminId } = await requireAdminPermission(req, 'AGENDA_MANAGE')
    const url = new URL(req.url)
    const body = req.method === 'POST'
      ? await req.json().catch(() => ({})) as Record<string, unknown>
      : {}
    const eventId = uuid(
      req.method === 'GET' ? url.searchParams.get('google_calendar_event_id') : body.google_calendar_event_id,
      'EXTERNAL_BLOCK_ID_INVALID',
    )
    const context = await loadContext(eventId)

    if (req.method === 'GET') {
      return json(detailResponse(context.event, context.calendar, context.connection, context.allocations.length))
    }

    if (!context.calendar.is_active || !writableRole(context.calendar.access_role)) {
      throw new Error('EXTERNAL_BLOCK_READ_ONLY')
    }

    const action = (clean(body.action) ?? '').toUpperCase()
    if (action !== 'UPDATE' && action !== 'DELETE') throw new Error('EXTERNAL_BLOCK_ACTION_INVALID')
    const scope = parseScope(body.scope, Boolean(context.event.recurring_event_id))
    const token = await accessToken(context.connection)
    const providerCalendarId = context.calendar.google_calendar_id
    const targetEventId = scope === 'SERIES'
      ? context.event.recurring_event_id as string
      : context.event.google_event_id
    const targetProviderEvent = await getGoogleEvent(providerCalendarId, targetEventId, token)
    const before = mutationAuditSnapshot(context.event)

    if (action === 'UPDATE') {
      if (context.event.is_all_day) throw new Error('EXTERNAL_BLOCK_ALL_DAY_EDIT_UNSUPPORTED')
      const summary = typeof body.summary === 'string' ? body.summary.trim().slice(0, 1024) : context.event.summary ?? ''
      if (!summary) throw new Error('EXTERNAL_BLOCK_SUMMARY_REQUIRED')
      const requestedStart = requiredIso(body.start_at, 'EXTERNAL_BLOCK_START_INVALID')
      const requestedEnd = requiredIso(body.end_at, 'EXTERNAL_BLOCK_END_INVALID')
      const requestedStartMs = Date.parse(requestedStart)
      const requestedEndMs = Date.parse(requestedEnd)
      if (requestedEndMs <= requestedStartMs) throw new Error('EXTERNAL_BLOCK_RANGE_INVALID')

      let providerStart = requestedStart
      let providerEnd = requestedEnd
      let providerTimezone = context.calendar.timezone ?? 'America/Sao_Paulo'

      if (scope === 'SERIES') {
        const selectedProviderEvent = await getGoogleEvent(providerCalendarId, context.event.google_event_id, token)
        const selectedRange = timedRange(selectedProviderEvent, 'EXTERNAL_BLOCK_SELECTED_INSTANCE_INVALID')
        const masterRange = timedRange(targetProviderEvent, 'EXTERNAL_BLOCK_SERIES_INVALID')
        const deltaMs = requestedStartMs - Date.parse(selectedRange.start)
        const durationMs = requestedEndMs - requestedStartMs
        const shiftedMasterStartMs = Date.parse(masterRange.start) + deltaMs
        providerStart = new Date(shiftedMasterStartMs).toISOString()
        providerEnd = new Date(shiftedMasterStartMs + durationMs).toISOString()
        providerTimezone = targetProviderEvent.start?.timeZone ?? providerTimezone
      }

      await auditRequested(context.client, adminId, context.event, 'UPDATE', before, {
        summary,
        start_at: requestedStart,
        end_at: requestedEnd,
        scope,
      })

      const updated = await patchGoogleEvent(
        providerCalendarId,
        targetEventId,
        token,
        targetProviderEvent.etag,
        {
          summary,
          start: { dateTime: providerStart, timeZone: providerTimezone },
          end: { dateTime: providerEnd, timeZone: targetProviderEvent.end?.timeZone ?? providerTimezone },
        },
      )

      const reconcile = await reconcileAfterProviderMutation(
        context.client,
        context.calendar.id,
        `${context.event.id}:update:${Date.now()}`,
        scope === 'THIS'
          ? () => applyProviderEventLocally(context.client, context.calendar.id, updated)
          : null,
      )

      await auditSucceededBestEffort(context.client, adminId, context.event, 'UPDATE', {
        summary,
        start_at: requestedStart,
        end_at: requestedEnd,
        scope,
        sync_immediate: reconcile.syncImmediate,
        sync_queued: reconcile.syncQueued,
      })

      return json({
        ok: true,
        action,
        scope,
        sync_immediate: reconcile.syncImmediate,
        sync_queued: reconcile.syncQueued,
      })
    }

    await auditRequested(context.client, adminId, context.event, 'DELETE', before, { scope })
    await deleteGoogleEvent(providerCalendarId, targetEventId, token, targetProviderEvent.etag)

    const reconcile = await reconcileAfterProviderMutation(
      context.client,
      context.calendar.id,
      `${context.event.id}:delete:${Date.now()}`,
      scope === 'THIS'
        ? () => applyDeletedOccurrenceLocally(context.client, context.event)
        : null,
    )

    await auditSucceededBestEffort(context.client, adminId, context.event, 'DELETE', {
      scope,
      sync_immediate: reconcile.syncImmediate,
      sync_queued: reconcile.syncQueued,
    })

    return json({
      ok: true,
      action,
      scope,
      sync_immediate: reconcile.syncImmediate,
      sync_queued: reconcile.syncQueued,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'EXTERNAL_BLOCK_FAILED'
    const status = code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.startsWith('ADMIN_') ? 401
      : code === 'EXTERNAL_BLOCK_NOT_FOUND' || code === 'EXTERNAL_BLOCK_PROVIDER_NOT_FOUND' ? 404
      : code === 'EXTERNAL_BLOCK_READ_ONLY' ? 403
      : code === 'EXTERNAL_BLOCK_CONFLICT' ? 409
      : code === 'EXTERNAL_BLOCK_GOOGLE_RECONNECT_REQUIRED' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
