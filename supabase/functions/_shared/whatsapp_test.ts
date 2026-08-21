import {
  buildResumeUrl,
  buildWhatsAppRecoveryTemplatePayload,
  normalizeWhatsAppRecipient,
} from './whatsapp.ts'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

Deno.test('WhatsApp recipient normalization keeps only E.164 digits', () => {
  assert(normalizeWhatsAppRecipient('+55 (48) 99999-1234') === '5548999991234', 'phone normalization failed')
})

Deno.test('resume URL is HTTPS and opaque-token based', () => {
  const url = buildResumeUrl('https://agenda.example.com/', 'opaque token')
  assert(url === 'https://agenda.example.com/retomar/opaque%20token', 'resume url mismatch')
})

Deno.test('recovery template sends only the resume URL as body parameter', () => {
  const payload = buildWhatsAppRecoveryTemplatePayload(
    '+55 48 99999-1234',
    { provider_template_name: 'checkout_hold_expired_recovery', language_code: 'pt_BR' },
    'https://agenda.example.com/retomar/token',
  ) as any

  assert(payload.messaging_product === 'whatsapp', 'wrong product')
  assert(payload.to === '5548999991234', 'wrong recipient')
  assert(payload.template.name === 'checkout_hold_expired_recovery', 'wrong template')
  assert(payload.template.components[0].parameters.length === 1, 'unexpected parameter count')
  assert(payload.template.components[0].parameters[0].text.includes('/retomar/token'), 'missing resume url')
})
