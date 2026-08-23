import {
  buildContactCustomFields,
  contactMatchesExactly,
  exactContactCandidates,
  kommoLeadName,
  normalizePhone,
  stageIdForAppointment,
} from './kommo.ts'

Deno.test('normalizePhone canonicalizes Brazilian local and +55 formats', () => {
  if (normalizePhone('+55 (48) 99999-0000') !== '5548999990000') throw new Error('international phone normalization failed')
  if (normalizePhone('(48) 99999-0000') !== '5548999990000') throw new Error('local BR phone normalization failed')
})

Deno.test('contact exact match can be restricted to phone identity', () => {
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
