import { adminClient, errorResponse, jsonResponse, requireAdminPermission } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, normalizeGoogleEvent, refreshAccessToken, sha256Hex } from '../_shared/google.ts'
import { managedEventNeedsRepair, type ManagedAppointmentDesiredState } from '../_shared/managed-event.ts'

async function authorize(req: Request): Promise<void> {
  const internal = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (internal && supplied === internal) return
  await requireAdminPermission(req, 'INTEGRATIONS_MANAGE')
}

type EventsPage = {
  items?: Record<string, any>[]
  nextPageToken?: string
  nextSyncToken?: string
}

async function enqueueRepair(
  client: ReturnType<typeof adminClient>,
  appointmentId: string,
  version: number,
  discriminator: string,
): Promise<void> {
  await client.from('integration_jobs').upsert({
    job_type: 'GOOGLE_APPOINTMENT_SYNC',
    entity_type: 'APPOINTMENT',
    entity_id: appointmentId,
    entity_version: version,
    payload_json: { reason: 'GOOGLE_MANAGED_EVENT_DRIFT', discriminator },
    idempotency_key: `google-appointment-repair:${appointmentId}:${version}:${discriminator}`,
  }, { onConflict: 'idempotency_key', ignoreDuplicates: true })
}

async function performSync(
  internalCalendarId: string,
  accessToken: string,
  googleCalendarId: string,
  syncToken: string | null,
  forceFull: boolean,
): Promise<{ full: boolean; processed: number; nextSyncToken: string; repairs: number }> {
  const client = adminClient()
  const full = forceFull || !syncToken
  const syncStartedAt = new Date().toISOString()
  if (full) {
    const { error } = await client.rpc('prepare_google_full_sync', { p_google_calendar_id: internalCalendarId })
    if (error) throw new Error(error.message)
  }

  let pageToken: string | undefined
  let nextSyncToken: string | undefined
  let processed = 0
  let repairs = 0

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

      if (normalized.p_status === 'cancelled' && !normalized.p_agenda_appointment_id) {
        const { data: existing } = await client
          .from('google_calendar_events')
          .select('managed_by_agenda, agenda_appointment_id, bs_source, recurring_event_id, original_start_at, original_start_date')
          .eq('google_calendar_id', internalCalendarId)
          .eq('google_event_id', normalized.p_google_event_id)
          .maybeSingle()
        if (existing?.managed_by_agenda && existing.agenda_appointment_id) {
          normalized.p_managed_by_agenda = true
          normalized.p_agenda_appointment_id = existing.agenda_appointment_id
          normalized.p_bs_source = existing.bs_source ?? 'blacksheep_agenda'
          normalized.p_recurring_event_id = normalized.p_recurring_event_id ?? existing.recurring_event_id
          normalized.p_original_start_at = normalized.p_original_start_at ?? existing.original_start_at
          normalized.p_original_start_date = normalized.p_original_start_date ?? existing.original_start_date
        }
      }

      const { error: eventError } = await client.rpc('upsert_google_calendar_event', {
        p_google_calendar_id: internalCalendarId,
        ...normalized,
      })
      if (eventError) throw new Error(`GOOGLE_EVENT_APPLY_FAILED:${eventError.message}`)
      processed += 1

      if (normalized.p_managed_by_agenda && normalized.p_agenda_appointment_id) {
        const { data: desiredData, error: desiredError } = await client.rpc('get_google_appointment_desired_state', {
          p_appointment_id: normalized.p_agenda_appointment_id,
        })
        if (!desiredError && desiredData) {
          const desired = desiredData as ManagedAppointmentDesiredState
          if (managedEventNeedsRepair(
            { status: normalized.p_status, start_at: normalized.p_start_at, end_at: normalized.p_end_at },
            desired,
          )) {
            const discriminator = normalized.p_etag?.replaceAll('"', '') || normalized.p_google_updated_at || normalized.p_google_event_id
            await enqueueRepair(client, desired.appointment_id, desired.version, discriminator)
            repairs += 1
          }
        }
      }
    }

    pageToken = page.nextPageToken
    if (page.nextSyncToken) nextSyncToken = page.nextSyncToken
  } while (pageToken)

  if (full) {
    const { data: unseen } = await client
      .from('google_calendar_events')
      .select('google_event_id, agenda_appointment_id, last_seen_at')
      .eq('google_calendar_id', internalCalendarId)
      .eq('managed_by_agenda', true)
      .neq('status', 'cancelled')
      .lt('last_seen_at', syncStartedAt)

    for (const mirror of unseen ?? []) {
      if (!mirror.agenda_appointment_id) continue
      const { data: desiredData, error: desiredError } = await client.rpc('get_google_appointment_desired_state', {
        p_appointment_id: mirror.agenda_appointment_id,
      })
      if (desiredError || !desiredData) continue
      const desired = desiredData as ManagedAppointmentDesiredState
      if (desired.desired_action === 'PRESENT') {
        await enqueueRepair(client, desired.appointment_id, desired.version, `missing-${mirror.google_event_id}`)
        repairs += 1
      }
    }
  }

  if (!nextSyncToken) throw new Error('GOOGLE_NEXT_SYNC_TOKEN_MISSING')
  return { full, processed, nextSyncToken, repairs }
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

    const runForceFull = forceFull || !syncState?.sync_token || ['NEVER_SYNCED', 'STALE', 'REBUILDING'].includes(syncState?.health_status ?? '')
    let result
    try {
      result = await performSync(calendar.id, accessToken, calendar.google_calendar_id, syncState?.sync_token ?? null, runForceFull)
    } catch (error) {
      const status = (error as Error & { status?: number }).status
      const message = error instanceof Error ? error.message : 'GOOGLE_SYNC_FAILED'
      if (status === 410 && !runForceFull && syncState?.sync_token) {
        const staleTokenFingerprint = (await sha256Hex(syncState.sync_token)).slice(0, 20)
        const { error: failureError } = await client.rpc('mark_google_sync_failure', {
          p_google_calendar_id: calendar.id,
          p_error: 'GOOGLE_SYNC_TOKEN_GONE',
          p_requires_full_sync: true,
        })
        if (failureError) throw new Error('GOOGLE_SYNC_STALE_MARK_FAILED')

        const { error: enqueueError } = await client.rpc('enqueue_google_calendar_sync', {
          p_google_calendar_id: calendar.id,
          p_idempotency_key: `google-full-sync:${calendar.id}:token-gone:${staleTokenFingerprint}`,
          p_payload_json: { source: 'SYNC_TOKEN_GONE', force_full: true },
        })
        if (enqueueError) throw new Error('GOOGLE_FULL_SYNC_ENQUEUE_FAILED')

        return jsonResponse({
          google_calendar_id: calendar.id,
          mode: 'INCREMENTAL_ABORTED',
          processed: 0,
          repairs_enqueued: 0,
          health_status: 'STALE',
          full_sync_enqueued: true,
        }, 202)
      }

      const { error: failureError } = await client.rpc('mark_google_sync_failure', {
        p_google_calendar_id: calendar.id,
        p_error: message.slice(0, 1000),
        p_requires_full_sync: status === 410,
      })
      if (failureError) throw new Error('GOOGLE_SYNC_FAILURE_SAVE_FAILED')
      throw error
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
      repairs_enqueued: result.repairs,
      health_status: 'HEALTHY',
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_SYNC_FAILED'
    const status = code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.startsWith('ADMIN_') ? 401
      : 400
    return errorResponse(error, status)
  }
})
