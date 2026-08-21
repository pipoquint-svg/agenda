export type ManagedAppointmentDesiredState = {
  appointment_id: string
  public_code?: string
  version: number
  appointment_status: string
  desired_action: 'PRESENT' | 'ABSENT'
  calendar_configured: boolean
  time_scope?: 'FULL_APPOINTMENT' | 'CORE_ONLY'
  start_at?: string
  end_at?: string
  google_calendar_id?: string
  remote_calendar_id?: string
  calendar_timezone?: string
  google_connection_id?: string
  summary?: string
  description?: string
}

export function deterministicAgendaGoogleEventId(appointmentId: string): string {
  const normalized = appointmentId.toLowerCase().replaceAll('-', '')
  if (!/^[0-9a-v]+$/.test(normalized)) throw new Error('APPOINTMENT_ID_NOT_GOOGLE_EVENT_ID_COMPATIBLE')
  return `bs${normalized}`
}

export function buildManagedGoogleEvent(desired: ManagedAppointmentDesiredState): Record<string, unknown> {
  if (!desired.start_at || !desired.end_at || !desired.calendar_timezone) {
    throw new Error('GOOGLE_APPOINTMENT_TIME_MISSING')
  }

  return {
    summary: desired.summary ?? 'Reserva BlackSheep Agenda',
    description: desired.description ?? `BlackSheep Agenda • Reserva ${desired.public_code ?? ''}`.trim(),
    start: {
      dateTime: desired.start_at,
      timeZone: desired.calendar_timezone,
    },
    end: {
      dateTime: desired.end_at,
      timeZone: desired.calendar_timezone,
    },
    extendedProperties: {
      private: {
        bs_source: 'blacksheep_agenda',
        bs_appointment_id: desired.appointment_id,
        bs_appointment_version: String(desired.version),
      },
    },
  }
}

export function sameInstant(left?: string | null, right?: string | null): boolean {
  if (!left || !right) return false
  const l = Date.parse(left)
  const r = Date.parse(right)
  return Number.isFinite(l) && Number.isFinite(r) && l === r
}

export function managedEventNeedsRepair(
  event: { status?: string | null; start_at?: string | null; end_at?: string | null },
  desired: ManagedAppointmentDesiredState,
): boolean {
  if (desired.desired_action !== 'PRESENT') return false
  if (event.status === 'cancelled') return true
  return !sameInstant(event.start_at, desired.start_at) || !sameInstant(event.end_at, desired.end_at)
}
