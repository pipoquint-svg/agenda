import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, normalizeGoogleEvent, refreshAccessToken } from '../_shared/google.ts'
import {
  buildManagedGoogleEvent,
  deterministicAgendaGoogleEventId,
  renderManagedNotificationTemplate,
  type ManagedAppointmentDesiredState,
} from '../_shared/managed-event.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function numeric(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}
function money(value: unknown): string {
  return numeric(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

async function applyConfiguredCalendarTemplate(
  client: ReturnType<typeof adminClient>,
  appointmentId: string,
  desired: ManagedAppointmentDesiredState,
): Promise<ManagedAppointmentDesiredState> {
  const { data: appointment, error: appointmentError } = await client
    .from('appointments')
    .select('id,service_id,service_employee_id,primary_customer_id,public_code,start_at,end_at,financial_status,commercial_value,service_name_snapshot,service_description_snapshot')
    .eq('id', appointmentId)
    .maybeSingle()
  if (appointmentError || !appointment) throw new Error('GOOGLE_TEMPLATE_APPOINTMENT_LOOKUP_FAILED')

  const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
    p_event_key: 'APPOINTMENT_APPROVED',
    p_channel: 'GOOGLE_CALENDAR',
    p_audience: 'EMPLOYEE',
    p_service_id: appointment.service_id,
  })
  if (resolverError) throw new Error('GOOGLE_NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
  const template = Array.isArray(rows) ? rows[0] : null
  if (!template) return desired

  const { data: service, error: serviceError } = await client
    .from('services')
    .select('id,name,full_description,operation_scope')
    .eq('id', appointment.service_id)
    .maybeSingle()
  if (serviceError || !service) throw new Error('GOOGLE_TEMPLATE_SERVICE_LOOKUP_FAILED')
  const scope = String(service.operation_scope ?? '').trim().toUpperCase()

  const [{ data: customer }, { data: financial }, { data: extras }, { data: discount }, { data: operationSettings }, { data: serviceEmployee }] = await Promise.all([
    appointment.primary_customer_id
      ? client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle()
      : Promise.resolve({ data: null }),
    client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId }),
    client.from('appointment_extras').select('name_snapshot,quantity').eq('appointment_id', appointmentId),
    client.from('appointment_discounts').select('code_snapshot,calculated_discount_amount').eq('appointment_id', appointmentId).maybeSingle(),
    scope ? client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope }) : Promise.resolve({ data: null }),
    appointment.service_employee_id
      ? client.from('service_employees').select('employee_id').eq('id', appointment.service_employee_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ])

  let employeeName = ''
  if (serviceEmployee?.employee_id) {
    const { data: employee } = await client.from('employees').select('name').eq('id', serviceEmployee.employee_id).maybeSingle()
    employeeName = String(employee?.name ?? '')
  }

  const values: Record<string, string> = {
    'appointment.public_code': String(appointment.public_code ?? ''),
    'appointment.start_at': String(appointment.start_at ?? ''),
    'appointment.end_at': String(appointment.end_at ?? ''),
    'customer.name': String(customer?.name ?? ''),
    'customer.email': String(customer?.email ?? ''),
    'employee.name': employeeName,
    'service.name': String(appointment.service_name_snapshot ?? service.name ?? ''),
    'service.description': String(appointment.service_description_snapshot ?? service.full_description ?? ''),
    'operation.name': String(operationSettings?.public_name ?? ''),
    'operation.email': String(operationSettings?.public_email ?? ''),
    'operation.phone': String(operationSettings?.public_phone ?? ''),
    'operation.address': String(operationSettings?.public_address ?? ''),
    'operation.site_url': String(operationSettings?.public_site_url ?? ''),
    'payment.total': money(appointment.commercial_value),
    'payment.status': String(appointment.financial_status ?? financial?.financial_status ?? ''),
    'extras.summary': (extras ?? []).map((item: any) => `${item.name_snapshot} × ${item.quantity}`).join(', '),
    'coupon.code': String(discount?.code_snapshot ?? ''),
    'coupon.discount': money(discount?.calculated_discount_amount ?? 0),
  }
  const allowed = Array.isArray(template.variable_schema) ? template.variable_schema.map((item: unknown) => String(item)) : []

  return {
    ...desired,
    summary: renderManagedNotificationTemplate(String(template.title_template ?? ''), allowed, values),
    description: renderManagedNotificationTemplate(String(template.body_template ?? ''), allowed, values),
  }
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
    const appointmentId = String(body.appointment_id ?? '')
    const entityVersion = Number(body.entity_version)
    if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
    if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')

    const client = adminClient()
    const { data: desiredData, error: desiredError } = await client.rpc('get_google_appointment_desired_state', {
      p_appointment_id: appointmentId,
    })
    if (desiredError) throw new Error(desiredError.message)
    let desired = desiredData as ManagedAppointmentDesiredState

    if (entityVersion < desired.version) {
      return jsonResponse({ stale: true, current_version: desired.version, appointment_id: appointmentId })
    }
    if (entityVersion > desired.version) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')

    if (desired.desired_action === 'PRESENT') {
      desired = await applyConfiguredCalendarTemplate(client, appointmentId, desired)
    }

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