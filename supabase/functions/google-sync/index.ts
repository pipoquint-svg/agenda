import { adminClient, errorResponse, jsonResponse, requireAdmin } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, normalizeGoogleEvent, refreshAccessToken } from '../_shared/google.ts'

async function authorize(req: Request): Promise<void> {
  const internal = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (internal && supplied === internal) return
  await requireAdmin(req)
}

type EventsPage = {
  items?: Record<string, any>[]
  nextPageToken?: string
  nextSyncToken?: string
}

async function performSync(
  internalCalendarId: string,
  accessToken: string,
  googleCalendarId: string,
  syncToken: string | null,
  forceFull: boolean,
): Promise<{ full: boolean; processed: number; nextSyncToken: string }> {
  const client = adminClient()
  const full = forceFull || !syncToken
  if (full) {
    const { error } = await client.rpc('prepare_google_full_sync', { p_google_calendar_id: internalCalendarId })
    if (error) throw new Error(error.message)
  }

  let pageToken: string | undefined
  let nextSyncToken: string | undefined
  let processed = 0

  do {
    const endpoint = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(googleCalendarId)}/events`)
    endpoint.searchParams.set('maxResults', '2500')
    endpoint.searchParams.set('singleEvents', 'true')
    endpoint.searchParams.set('showDeleted', 'true')
    if (!full && syncToken) endpoint.searchParams.set('syncToken', syncToken)
    if (pageToken) endpoint.searchParams.set('pageToken', pageToken)

    const page = await googleJson<EventsPage>(endpoint.toString(), accessToken)
    for (const event of page.items ?? []) {
      const normalized = normalizeGoogleEvent(event)
      if (!normalized.p_google_event_id) continue
      const { error: eventError } = await client.rpc('upsert_google_calendar_event', {
        p_google_calendar_id: internalCalendarId,
        ...normalized,
      })
      if (eventError) throw new Error(`GOOGLE_EVENT_APPLY_FAILED:${eventError.message}`)
      processed += 1
    }

    pageToken = page.nextPageToken
    if (page.nextSyncToken) nextSyncToken = page.nextSyncToken
  } while (pageToken)

  if (!nextSyncToken) throw new Error('GOOGLE_NEXT_SYNC_TOKEN_MISSING')
  return { full, processed, nextSyncToken }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  let calendarId: string | undefined
  try {
    await authorize(req)
    const body = await req.json()
    calendarId = body.google_calendar_id
    const forceFull = body.force_full === true
    if (!calendarId) throw new Error('GOOGLE_CALENDAR_ID_REQUIRED')

    const client = adminClient()
    const { data: calendar, error: calendarError } = await client
      .from('google_calendars')
      .select('id, google_calendar_id, google_connection_id, is_active')
      .eq('id', calendarId)
      .maybeSingle()
    if (calendarError || !calendar || !calendar.is_active) throw new Error('GOOGLE_CALENDAR_NOT_FOUND')

    const { data: connection, error: connectionError } = await client
      .from('google_connections')
      .select('id, refresh_token_ciphertext, status')
      .eq('id', calendar.google_connection_id)
      .maybeSingle()
    if (connectionError || !connection || connection.status !== 'ACTIVE' || !connection.refresh_token_ciphertext) {
      throw new Error('GOOGLE_CONNECTION_UNHEALTHY')
    }

    let accessToken: string
    try {
      const refreshToken = await decryptRefreshToken(connection.refresh_token_ciphertext)
      accessToken = (await refreshAccessToken(refreshToken)).access_token
    } catch (error) {
      const code = error instanceof Error ? error.message : 'GOOGLE_TOKEN_REFRESH_FAILED'
      if (code === 'GOOGLE_RECONNECT_REQUIRED') {
        await client.from('google_connections').update({
          status: 'RECONNECT_REQUIRED',
          last_error: code,
          updated_at: new Date().toISOString(),
        }).eq('id', connection.id)
      }
      throw error
    }

    const { data: syncState } = await client
      .from('google_sync_state')
      .select('sync_token, health_status')
      .eq('google_calendar_id', calendar.id)
      .maybeSingle()

    let runForceFull = forceFull || !syncState?.sync_token || ['NEVER_SYNCED', 'STALE', 'REBUILDING'].includes(syncState?.health_status ?? '')
    let result
    try {
      result = await performSync(calendar.id, accessToken, calendar.google_calendar_id, syncState?.sync_token ?? null, runForceFull)
    } catch (error) {
      const status = (error as Error & { status?: number }).status
      const message = error instanceof Error ? error.message : 'GOOGLE_SYNC_FAILED'
      if (status === 410 && !runForceFull) {
        await client.rpc('mark_google_sync_failure', {
          p_google_calendar_id: calendar.id,
          p_error: 'GOOGLE_SYNC_TOKEN_GONE',
          p_requires_full_sync: true,
        })
        runForceFull = true
        result = await performSync(calendar.id, accessToken, calendar.google_calendar_id, null, true)
      } else {
        await client.rpc('mark_google_sync_failure', {
          p_google_calendar_id: calendar.id,
          p_error: message.slice(0, 1000),
          p_requires_full_sync: status === 410,
        })
        throw error
      }
    }

    const { error: successError } = await client.rpc('mark_google_sync_success', {
      p_google_calendar_id: calendar.id,
      p_sync_token: result.nextSyncToken,
      p_is_full_sync: result.full,
    })
    if (successError) throw new Error('GOOGLE_SYNC_STATE_SAVE_FAILED')

    return jsonResponse({
      google_calendar_id: calendar.id,
      mode: result.full ? 'FULL' : 'INCREMENTAL',
      processed: result.processed,
      health_status: 'HEALTHY',
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_SYNC_FAILED'
    const authFailure = code.startsWith('ADMIN_')
    return errorResponse(error, authFailure ? 401 : 400)
  }
})
