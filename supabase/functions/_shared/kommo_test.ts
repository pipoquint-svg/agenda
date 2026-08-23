import {
  buildContactCustomFields,
  buildLeadCardCustomFields,
  contactMatchesExactly,
  exactContactCandidates,
  findUniqueLeadDateFieldId,
  formatRentalExtras,
  kommoBalanceValue,
  kommoLeadName,
  kommoLeadPrice,
  kommoReservationDateValue,
  normalizePhone,
  resolveLeadCardFields,
  stageIdForAppointment,
} from './kommo.ts'

Deno.test('normalizePhone canonicalizes Brazilian local and +55 formats', () => {
  if (normalizePhone('+55 (48) 99999-0000') !== '5548999990000') throw new Error('international phone normalization failed')
  if (normalizePhone('(48) 99999-0000') !== '5548999990000') throw new Error('local BR phone normalization failed')
})

Deno.test('global Kommo contact identity is exact phone match, independent of lead stage', () => {
  const contact = {
    id: 1,
    custom_fields_values: [
      { field_code: 'EMAIL', values: [{ value: 'Cliente@Teste.Com' }] },
      { field_code: 'PHONE', values: [{ value: '+55 48 99999-0000' }] },
    ],
  }
  if (!contactMatchesExactly(contact, null, '48999990000')) throw new Error('phone should match across BR formatting')
  if (contactMatchesExactly(contact, null, '5511999999999')) throw new Error('unrelated phone matched')
  if (exactContactCandidates([contact], null, '48999990000').length !== 1) throw new Error('phone-only candidate lookup failed')
})

Deno.test('email alone does not match when caller requests phone-only identity', () => {
  const contact = {
    id: 1,
    custom_fields_values: [{ field_code: 'EMAIL', values: [{ value: 'a@b.com' }] }],
  }
  if (exactContactCandidates([contact], null, '48999990000').length !== 0) throw new Error('email must not substitute missing phone')
})

Deno.test('ambiguous phone contacts remain visible to caller', () => {
  const contacts = [
    { id: 1, custom_fields_values: [{ field_code: 'PHONE', values: [{ value: '+55 48 99999-0000' }] }] },
    { id: 2, custom_fields_values: [{ field_code: 'PHONE', values: [{ value: '(48) 99999-0000' }] }] },
  ]
  if (exactContactCandidates(contacts, null, '48999990000').length !== 2) throw new Error('phone ambiguity must not be hidden')
})

Deno.test('stage mapping prioritizes reschedule event then appointment status', () => {
  const settings = {
    pipeline_id: 10,
    stage_awaiting_payment_id: 11,
    stage_confirmed_id: 12,
    stage_rescheduled_id: 13,
    stage_cancelled_id: 14,
    stage_completed_id: 15,
    stage_no_show_id: 16,
    stage_expired_id: 17,
  }
  if (stageIdForAppointment(settings, 'CONFIRMED', 'RESCHEDULED') !== 13) throw new Error('reschedule stage failed')
  if (stageIdForAppointment(settings, 'CONFIRMED', 'UPDATED') !== 12) throw new Error('confirmed stage failed')
  if (stageIdForAppointment(settings, 'AWAITING_PAYMENT', 'CREATED') !== 11) throw new Error('awaiting stage failed')
})

Deno.test('missing stage fails closed', () => {
  let failed = false
  try {
    stageIdForAppointment({
      pipeline_id: 10,
      stage_awaiting_payment_id: null,
      stage_confirmed_id: null,
      stage_rescheduled_id: null,
      stage_cancelled_id: null,
      stage_completed_id: null,
      stage_no_show_id: null,
      stage_expired_id: null,
    }, 'CONFIRMED', 'UPDATED')
  } catch (error) {
    failed = error instanceof Error && error.message.startsWith('KOMMO_STAGE_NOT_CONFIGURED')
  }
  if (!failed) throw new Error('missing stage should fail closed')
})

Deno.test('contact field payload uses provider field ids only', () => {
  const fields = buildContactCustomFields(21, 22, ' CLIENTE@TESTE.COM ', '+55 48 99999-0000')
  if (JSON.stringify(fields) !== JSON.stringify([
    { field_id: 21, values: [{ value: 'cliente@teste.com', enum_code: 'WORK' }] },
    { field_id: 22, values: [{ value: '+55 48 99999-0000', enum_code: 'MOB' }] },
  ])) throw new Error('custom field payload mismatch')
})

Deno.test('lead name carries public code for recovery/idempotency', () => {
  if (kommoLeadName('Locação', 'BS-123') !== 'Locação · BS-123') throw new Error('lead name mismatch')
})

Deno.test('reservation Data field is resolved uniquely and must be date-compatible', () => {
  const id = findUniqueLeadDateFieldId([
    { id: 10, name: 'Pai', type: 'text' },
    { id: 20, name: 'Data', type: 'date' },
  ])
  if (id !== 20) throw new Error('Data field id mismatch')

  let failed = false
  try {
    findUniqueLeadDateFieldId([{ id: 30, name: 'Data', type: 'text' }])
  } catch (error) {
    failed = error instanceof Error && error.message === 'KOMMO_RESERVATION_DATE_FIELD_INVALID_TYPE'
  }
  if (!failed) throw new Error('non-date Data field should fail closed')
})

Deno.test('reservation date is derived in America/Sao_Paulo and encoded as RFC3339', () => {
  const value = kommoReservationDateValue('2026-08-24T01:00:00Z')
  if (value !== '2026-08-23T12:00:00-03:00') throw new Error(`reservation date timezone mismatch: ${value}`)
})

Deno.test('shared lead card fields are resolved by exact account-wide names', () => {
  const fields = resolveLeadCardFields([
    { id: 101, name: 'Data', type: 'date' },
    { id: 102, name: 'SALDO', type: 'monetary' },
    { id: 103, name: 'Extras locação', type: 'textarea' },
    { id: 104, name: 'Pai', type: 'text' },
  ])
  if (fields.reservationDate.id !== 101) throw new Error('Data mapping failed')
  if (fields.balance.id !== 102) throw new Error('Saldo mapping failed')
  if (fields.rentalExtras.id !== 103) throw new Error('Extras locação mapping failed')
})

Deno.test('lead card field mapping fails closed on ambiguity or incompatible type', () => {
  let ambiguous = false
  try {
    resolveLeadCardFields([
      { id: 1, name: 'Data', type: 'date' },
      { id: 2, name: 'Saldo', type: 'numeric' },
      { id: 3, name: 'Saldo', type: 'numeric' },
      { id: 4, name: 'Extras locação', type: 'text' },
    ])
  } catch (error) {
    ambiguous = error instanceof Error && error.message === 'KOMMO_BALANCE_FIELD_AMBIGUOUS'
  }
  if (!ambiguous) throw new Error('Saldo ambiguity should fail closed')

  let invalidExtras = false
  try {
    resolveLeadCardFields([
      { id: 1, name: 'Data', type: 'date' },
      { id: 2, name: 'Saldo', type: 'numeric' },
      { id: 4, name: 'Extras locação', type: 'numeric' },
    ])
  } catch (error) {
    invalidExtras = error instanceof Error && error.message === 'KOMMO_RENTAL_EXTRAS_FIELD_INVALID_TYPE'
  }
  if (!invalidExtras) throw new Error('Extras locação invalid type should fail closed')
})

Deno.test('Venda, Saldo and Extras locação values follow Agenda authority', () => {
  if (kommoLeadPrice(1090) !== 1090) throw new Error('Venda price mismatch')
  if (kommoBalanceValue(545) !== '545.00') throw new Error('Saldo mismatch')
  if (formatRentalExtras([{ name: 'Flash adicional', quantity: 1 }, { name: 'Fundo de papel', quantity: 2 }]) !== 'Flash adicional\n2x Fundo de papel') {
    throw new Error('extras formatting mismatch')
  }

  const payload = buildLeadCardCustomFields({
    reservationDate: { id: 101, type: 'date' },
    balance: { id: 102, type: 'numeric' },
    rentalExtras: { id: 103, type: 'textarea' },
  }, '2026-08-24T01:00:00Z', 545, [{ name: 'Flash adicional', quantity: 1 }])

  if (JSON.stringify(payload) !== JSON.stringify([
    { field_id: 101, values: [{ value: '2026-08-23T12:00:00-03:00' }] },
    { field_id: 102, values: [{ value: '545.00' }] },
    { field_id: 103, values: [{ value: 'Flash adicional' }] },
  ])) throw new Error('lead card payload mismatch')
})

Deno.test('zero balance and no extras clear the operational values deterministically', () => {
  const payload = buildLeadCardCustomFields({
    reservationDate: { id: 101, type: 'date' },
    balance: { id: 102, type: 'numeric' },
    rentalExtras: { id: 103, type: 'text' },
  }, '2026-08-23T15:00:00-03:00', 0, [])
  if (payload[1].values[0].value !== '0.00') throw new Error('zero Saldo should be explicit')
  if (payload[2].values[0].value !== '') throw new Error('no extras should clear field')
})
