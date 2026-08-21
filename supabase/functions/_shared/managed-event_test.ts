import {
  buildManagedGoogleEvent,
  deterministicAgendaGoogleEventId,
  managedEventNeedsRepair,
  sameInstant,
  type ManagedAppointmentDesiredState,
} from './managed-event.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

const desired: ManagedAppointmentDesiredState = {
  appointment_id: '11111111-1111-1111-1111-111111111111',
  public_code: 'BS-1234',
  version: 7,
  appointment_status: 'CONFIRMED',
  desired_action: 'PRESENT',
  calendar_configured: true,
  time_scope: 'CORE_ONLY',
  start_at: '2035-01-15T12:00:00.000Z',
  end_at: '2035-01-15T13:00:00.000Z',
  calendar_timezone: 'America/Sao_Paulo',
  summary: 'Ensaio Gestante',
  description: 'BlackSheep Agenda • Reserva BS-1234',
}

Deno.test('deterministic Agenda event id is stable and Google-compatible', () => {
  const first = deterministicAgendaGoogleEventId(desired.appointment_id)
  const second = deterministicAgendaGoogleEventId(desired.appointment_id)
  assert(first === second, 'same appointment must always yield same event id')
  assert(/^bs[0-9a-v]+$/.test(first), 'event id must use base32hex-compatible alphabet')
})

Deno.test('managed event payload contains operational metadata but no customer PII', () => {
  const event = buildManagedGoogleEvent(desired) as any
  assert(event.summary === 'Ensaio Gestante', 'service snapshot must be used as title')
  assert(event.extendedProperties.private.bs_source === 'blacksheep_agenda', 'source marker is required')
  assert(event.extendedProperties.private.bs_appointment_id === desired.appointment_id, 'appointment marker is required')
  assert(event.extendedProperties.private.bs_appointment_version === '7', 'version marker is required')
  const serialized = JSON.stringify(event)
  assert(!serialized.includes('email') && !serialized.includes('phone') && !serialized.includes('cpf'), 'payload must not contain customer PII fields')
})

Deno.test('sameInstant compares RFC3339 instants independent of offset', () => {
  assert(sameInstant('2035-01-15T09:00:00-03:00', '2035-01-15T12:00:00Z'), 'equivalent offsets must match')
  assert(!sameInstant('2035-01-15T09:00:00-03:00', '2035-01-15T12:01:00Z'), 'different instants must not match')
})

Deno.test('managed drift detects deletion or time change but not matching state', () => {
  assert(managedEventNeedsRepair({ status: 'cancelled', start_at: null, end_at: null }, desired), 'cancelled remote event must be repaired')
  assert(managedEventNeedsRepair({ status: 'confirmed', start_at: '2035-01-15T12:05:00Z', end_at: desired.end_at }, desired), 'time drift must be repaired')
  assert(!managedEventNeedsRepair({ status: 'confirmed', start_at: desired.start_at, end_at: desired.end_at }, desired), 'matching managed event must not loop repairs')
})

Deno.test('ABSENT desired state never requests repair', () => {
  const absent = { ...desired, desired_action: 'ABSENT' as const, appointment_status: 'CANCELLED' }
  assert(!managedEventNeedsRepair({ status: 'confirmed', start_at: desired.start_at, end_at: desired.end_at }, absent), 'cancelled appointment is handled by desired-state removal job')
})
