import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, normalizeGoogleEvent, refreshAccessToken } from '../_shared/google.ts'
import {
  buildManagedGoogleEvent,
  deterministicAgendaGoogleEventId,
  type ManagedAppointmentDesiredState,
} from '../_shared/managed-event.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

async function mirrorCancelled(
  client: ReturnType<typeof adminClient>,
  calendarId: string,
  eventId: string,
  appointmentId: string,
): Promise<void> {
  const { error } = await client.rpc('upsert_google_calendar_event', {
    p_google_calendar_id: calendarId,
    p_google_event_id: eventId,
    p_status: 'cancelled',
    p_managed_by_agenda: true,
    p_agenda_appointment_id: appointmentId,
    p_bs_source: 'blacksheep_agenda',
    p_normalized_payload: {
      id: eventId,
      status: 'cancelled',
      privateExtendedProperties: {
        bs_source: 'blacksheep_agenda',
        bs_appointment_id: appointmentId,
      },
    },
  })
  if (error) throw new Error(`GOOGLE_MANAGED_MIRROR_CANCEL_FAILED:${error.message}`)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const body = await req.json()
    const appointmentId = body.appointment_id as string | undefined
    const entityVersion = Number(body.entity_version)
    if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
    if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')

    const client = adminClient()
    const { data: desiredData, error: desiredError } = await client.rpc('get_google_appointment_desired_state', {
      p_appointment_id: appointmentId,
    })
    if (desiredError) throw new Error(desiredError.message)
    const desired = desiredData as ManagedAppointmentDesiredState

    if (entityVersion < desired.version) {
      return jsonResponse({ stale: true, current_version: desired.version, appointment_id: appointmentId })
    }
    if (entityVersion > desired.version) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')

    const { data: mirrors, error: mirrorError } = await client
      .from('google_calendar_events')
      .select('id, google_calendar_id, google_event_id, status')
      .eq('agenda_appointment_id', appointmentId)
      .eq('managed_by_agenda', true)
      .neq('status', 'cancelled')
    if (mirrorError) throw new Error('GOOGLE_MANAGED_MIRROR_LOOKUP_FAILED')

    const tokenCache = new Map<string, string>()
    async function calendarRuntime(internalCalendarId: string): Promise<{ remoteId: string; accessToken: string }> {
      const { data: calendar, error: calendarError } = await client
        .from('google_calendars')
        .select('id, google_calendar_id, google_connection_id, is_active')
        .eq('id', internalCalendarId)
        .maybeSingle()
      if (calendarError || !calendar) throw new Error('GOOGLE_CALENDAR_NOT_FOUND')

      let accessToken = tokenCache.get(calendar.google_connection_id)
      if (!accessToken) {
        const { data: connection, error: connectionError } = await client
          .from('google_connections')
          .select('id, refresh_token_ciphertext, status')
          .eq('id', calendar.google_connection_id)
          .maybeSingle()
        if (connectionError || !connection?.refresh_token_ciphertext || connection.status !== 'ACTIVE') {
          throw new Error('GOOGLE_CONNECTION_UNHEALTHY')
        }
        try {
          const refreshToken = await decryptRefreshToken(connection.refresh_token_ciphertext)
          accessToken = (await refreshAccessToken(refreshToken)).access_token
          tokenCache.set(calendar.google_connection_id, accessToken)
        } catch (error) {
          const code = error instanceof Error ? error.message : 'GOOGLE_TOKEN_REFRESH_FAILED'
          if (code === 'GOOGLE_RECONNECT_REQUIRED') {
            await client.from('google_connections').update({
              status: 'RECONNECT_REQUIRED', last_error: code, updated_at: new Date().toISOString(),
            }).eq('id', connection.id)
          }
          throw error
        }
      }
      return { remoteId: calendar.google_calendar_id, accessToken }
    }

    async function removeMirror(mirror: any): Promise<void> {
      const runtime = await calendarRuntime(mirror.google_calendar_id)
      try {
        await googleJson<void>(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(runtime.remoteId)}/events/${encodeURIComponent(mirror.google_event_id)}`,
          runtime.accessToken,
          { method: 'DELETE' },
        )
      } catch (error) {
        const status = (error as Error & { status?: number }).status
        if (status !== 404 && status !== 410) throw error
      }
      await mirrorCancelled(client, mirror.google_calendar_id, mirror.google_event_id, appointmentId)
    }

    if (desired.desired_action === 'ABSENT') {
      for (const mirror of mirrors ?? []) await removeMirror(mirror)
      return jsonResponse({
        stale: false,
        appointment_id: appointmentId,
        version: desired.version,
        desired_action: 'ABSENT',
        removed_events: (mirrors ?? []).length,
      })
    }

    if (!desired.calendar_configured || !desired.google_calendar_id || !desired.remote_calendar_id || !desired.google_connection_id) {
      throw new Error('GOOGLE_WRITE_CALENDAR_NOT_CONFIGURED')
    }

    // If the write target changed, clean up the old managed event first.
    for (const mirror of mirrors ?? []) {
      if (mirror.google_calendar_id !== desired.google_calendar_id) await removeMirror(mirror)
    }

    const currentMirror = (mirrors ?? []).find((mirror: any) => mirror.google_calendar_id === desired.google_calendar_id)
    const runtime = await calendarRuntime(desired.google_calendar_id)
    const eventBody = buildManagedGoogleEvent(desired)
    let remoteEvent: Record<string, any>
    let eventId = currentMirror?.google_event_id as string | undefined

    if (eventId) {
      try {
        remoteEvent = await googleJson<Record<string, any>>(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(runtime.remoteId)}/events/${encodeURIComponent(eventId)}`,
          runtime.accessToken,
          { method: 'PATCH', body: JSON.stringify(eventBody) },
        )
      } catch (error) {
        const status = (error as Error & { status?: number }).status
        if (status !== 404 && status !== 410) throw error
        await mirrorCancelled(client, desired.google_calendar_id, eventId, appointmentId)
        eventId = undefined
        remoteEvent = {}
      }
    } else {
      remoteEvent = {}
    }

    if (!eventId) {
      eventId = deterministicAgendaGoogleEventId(appointmentId)
      const createBody = { id: eventId, ...eventBody }
      try {
        remoteEvent = await googleJson<Record<string, any>>(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(runtime.remoteId)}/events`,
          runtime.accessToken,
          { method: 'POST', body: JSON.stringify(createBody) },
        )
      } catch (error) {
        const status = (error as Error & { status?: number }).status
        if (status !== 409) throw error
        const existing = await googleJson<Record<string, any>>(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(runtime.remoteId)}/events/${encodeURIComponent(eventId)}`,
          runtime.accessToken,
        )
        const existingAppointment = existing.extendedProperties?.private?.bs_appointment_id
        if (existingAppointment !== appointmentId) throw new Error('GOOGLE_EVENT_ID_COLLISION')
        remoteEvent = await googleJson<Record<string, any>>(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(runtime.remoteId)}/events/${encodeURIComponent(eventId)}`,
          runtime.accessToken,
          { method: 'PATCH', body: JSON.stringify(eventBody) },
        )
      }
    }

    const normalized = normalizeGoogleEvent(remoteEvent)
    // The event created by this worker is always managed even if Google returns a sparse response.
    normalized.p_managed_by_agenda = true
    normalized.p_agenda_appointment_id = appointmentId
    normalized.p_bs_source = 'blacksheep_agenda'

    const { error: upsertError } = await client.rpc('upsert_google_calendar_event', {
      p_google_calendar_id: desired.google_calendar_id,
      ...normalized,
    })
    if (upsertError) throw new Error(`GOOGLE_MANAGED_MIRROR_SAVE_FAILED:${upsertError.message}`)

    return jsonResponse({
      stale: false,
      appointment_id: appointmentId,
      version: desired.version,
      desired_action: 'PRESENT',
      google_calendar_id: desired.google_calendar_id,
      google_event_id: normalized.p_google_event_id,
      time_scope: desired.time_scope,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_APPOINTMENT_SYNC_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 400)
  }
})
