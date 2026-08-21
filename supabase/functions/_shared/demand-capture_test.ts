import {
  normalizeBrazilWhatsapp,
  parseConfiguredBrands,
  todaySaoPaulo,
  validateDemandSubmission,
} from './demand-capture.ts'

function assertEquals(actual: unknown, expected: unknown, message?: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message ?? `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}

function assertThrows(fn: () => unknown, code: string) {
  try {
    fn()
  } catch (error) {
    assertEquals(error instanceof Error ? error.message : String(error), code)
    return
  }
  throw new Error(`Expected ${code}`)
}

Deno.test('Brazil WhatsApp normalizes national and country-code formats', () => {
  assertEquals(normalizeBrazilWhatsapp('(48) 99999-1234'), '5548999991234')
  assertEquals(normalizeBrazilWhatsapp('+55 48 99999-1234'), '5548999991234')
})

Deno.test('invalid Brazilian DDD or subscriber length is rejected', () => {
  assertThrows(() => normalizeBrazilWhatsapp('(00) 99999-1234'), 'WHATSAPP_INVALID')
  assertThrows(() => normalizeBrazilWhatsapp('(48) 9999-123'), 'WHATSAPP_INVALID')
})

Deno.test('configured brands accept JSON or comma separated values', () => {
  assertEquals(parseConfiguredBrands('["brand-a","brand-b"]'), ['brand-a', 'brand-b'])
  assertEquals(parseConfiguredBrands('brand-a, brand-b'), ['brand-a', 'brand-b'])
})

Deno.test('submission rejects past date using Sao Paulo calendar date', () => {
  const now = new Date('2026-08-21T18:00:00Z')
  assertEquals(todaySaoPaulo(now), '2026-08-21')
  assertThrows(() => validateDemandSubmission({
    name: 'Pessoa Teste',
    whatsapp: '(48) 99999-1234',
    email: 'pessoa@teste.local',
    brand: 'brand-a',
    service_id: '11111111-1111-4111-8111-111111111111',
    desired_date: '2026-08-20',
    consent_contact: true,
  }, ['brand-a'], now), 'DESIRED_DATE_IN_PAST')
})

Deno.test('submission requires explicit consent', () => {
  assertThrows(() => validateDemandSubmission({
    name: 'Pessoa Teste',
    whatsapp: '(48) 99999-1234',
    email: 'pessoa@teste.local',
    brand: 'brand-a',
    service_id: '11111111-1111-4111-8111-111111111111',
    consent_contact: false,
  }, ['brand-a']), 'CONSENT_REQUIRED')
})

Deno.test('valid submission is normalized for persistence', () => {
  const result = validateDemandSubmission({
    name: ' Pessoa Teste ',
    whatsapp: '(48) 99999-1234',
    email: 'PESSOA@TESTE.LOCAL',
    brand: 'brand-a',
    service_id: '11111111-1111-4111-8111-111111111111',
    desired_date: null,
    desired_period: 'INDIFERENTE',
    notes: ' observacao ',
    campaign: ' campanha ',
    consent_contact: true,
  }, ['brand-a'])

  assertEquals(result.name, 'Pessoa Teste')
  assertEquals(result.whatsapp, '5548999991234')
  assertEquals(result.email, 'pessoa@teste.local')
  assertEquals(result.notes, 'observacao')
})
