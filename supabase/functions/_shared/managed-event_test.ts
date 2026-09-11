import {
  appendManagedCustomFields,
  buildManagedGoogleEvent,
  deterministicAgendaGoogleEventId,
  managedEventNeedsRepair,
  renderManagedCustomFieldValue,
  renderManagedNotificationTemplate,
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

Deno.test('managed event payload contains operational metadata but no implicit customer PII', () => {
  const event = buildManagedGoogleEvent(desired) as any
  assert(event.summary === 'Ensaio Gestante', 'service snapshot must be used as title')
  assert(event.extendedProperties.private.bs_source === 'blacksheep_agenda', 'source marker is required')
  assert(event.extendedProperties.private.bs_appointment_id === desired.appointment_id, 'appointment marker is required')
  assert(event.extendedProperties.private.bs_appointment_version === '7', 'version marker is required')
  const serialized = JSON.stringify(event)
  assert(!serialized.includes('email') && !serialized.includes('phone') && !serialized.includes('cpf'), 'payload must not invent customer PII fields')
})

Deno.test('managed notification template renders only variables authorized by template schema', () => {
  const rendered = renderManagedNotificationTemplate(
    '{{service.name}} • {{customer.name}}',
    ['service.name', 'customer.name'],
    { 'service.name': 'Ensaio Gestante', 'customer.name': 'Cliente Teste' },
  )
  assert(rendered === 'Ensaio Gestante • Cliente Teste', 'authorized variables must render deterministically')
})

Deno.test('managed notification template fails closed on undeclared variable', () => {
  let rejected = false
  try {
    renderManagedNotificationTemplate('{{payment.total}}', ['service.name'], { 'payment.total': 'R$ 100,00' })
  } catch (error) {
    rejected = error instanceof Error && error.message === 'NOTIFICATION_TEMPLATE_VARIABLE_NOT_ALLOWED:payment.total'
  }
  assert(rejected, 'undeclared variables must be rejected instead of leaking values')
})

Deno.test('custom reservation fields are appended dynamically in form order', () => {
  const description = appendManagedCustomFields('Reserva confirmada', [
    { field_key: 'pet_names', label: 'Pets', value: ['Luna', 'Nina'], sort_order: 30, sequence: 2 },
    { field_key: 'baby_name', label: 'Nome do bebê', value: 'Arthur', sort_order: 20, sequence: 1 },
    { field_key: 'future_custom_field', label: 'Novo campo futuro', value: 'Nova resposta', sort_order: 40, sequence: 3 },
  ])
  assert(
    description === 'Reserva confirmada\n\nNome do bebê: Arthur\nPets: Luna, Nina\nNovo campo futuro: Nova resposta',
    'custom fields must be rendered without hard-coded field names and preserve sort order',
  )
})

Deno.test('custom reservation fields omit empty, technical and duplicate labels', () => {
  const description = appendManagedCustomFields('Instagram: @cliente', [
    { field_key: 'instagram', label: 'Instagram', value: '@duplicado', sort_order: 1 },
    { field_key: 'empty_note', label: 'Observação', value: '   ', sort_order: 2 },
    { field_key: 'internal_token', label: 'Token interno', value: 'nao-expor', sort_order: 3 },
    { field_key: 'public_note', label: 'Preferências', value: 'Luz suave\nSem flash', sort_order: 4 },
  ])
  assert(!description.includes('@duplicado'), 'labels already present in the base description must not be duplicated')
  assert(!description.includes('Observação:'), 'empty custom answers must be omitted')
  assert(!description.includes('Token interno'), 'technical fields must be omitted')
  assert(description.includes('Preferências: Luz suave\nSem flash'), 'meaningful multiline text must be preserved')
})

Deno.test('legacy inline reservation answers are not duplicated on resync', () => {
  const legacy = 'BlackSheep Agenda • Reserva 3D6859C3EE4D Cliente: Gisele Respostas da reserva: Qual serviço será realizado?: Corporativo Instagram: giselelohn Qual o set de luz utilizado?: Led'
  const description = appendManagedCustomFields(legacy, [
    { field_key: 'service', label: 'Qual serviço será realizado?', value: 'Corporativo', sort_order: 1 },
    { field_key: 'instagram', label: 'Instagram', value: '@duplicado', sort_order: 2 },
    { field_key: 'light_set', label: 'Qual o set de luz utilizado?', value: 'Led', sort_order: 3 },
    { field_key: 'new_field', label: 'Novo campo', value: 'Nova resposta', sort_order: 4 },
  ])
  assert(!description.includes('@duplicado'), 'legacy inline labels already present in the description must not be appended again')
  assert(description.match(/Qual serviço será realizado\?:/g)?.length === 1, 'legacy service answer must remain single')
  assert(description.match(/Qual o set de luz utilizado\?:/g)?.length === 1, 'legacy light answer must remain single')
  assert(description.endsWith('Novo campo: Nova resposta'), 'new fields must still be appended to legacy descriptions')
})

Deno.test('custom reservation value renderer keeps common future field types human-readable', () => {
  assert(renderManagedCustomFieldValue(true) === 'Sim', 'boolean true must be human-readable')
  assert(renderManagedCustomFieldValue(false) === 'Não', 'boolean false must be human-readable')
  assert(renderManagedCustomFieldValue(['A', '', 'B']) === 'A, B', 'multi-select arrays must be readable')
  assert(renderManagedCustomFieldValue({ label: 'Opção bonita', value: 'raw' }) === 'Opção bonita', 'labeled option objects must prefer their display label')
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
