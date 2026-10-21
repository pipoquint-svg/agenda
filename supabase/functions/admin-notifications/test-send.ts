import type { WhatsAppTemplateDefinition } from './whatsapp-template.ts'

/** Brazilian mobile/landline as 55 + DDD + number (digits only), or an error code. */
export function testRecipient(value: unknown): string {
  let digits = String(value ?? '').replace(/\D/g, '')
  if (digits.length === 10 || digits.length === 11) digits = `55${digits}`
  if (!/^55[1-9][0-9]{9,10}$/.test(digits)) throw new Error('WHATSAPP_TEST_RECIPIENT_INVALID')
  return digits
}

/** Same sample values Meta approved, sent as parameters of a test message. */
export function testParameters(definition: WhatsAppTemplateDefinition) {
  let button: string | null = null
  if (definition.button_url && definition.button_example) {
    const prefix = definition.button_url.slice(0, -'{{1}}'.length)
    if (!definition.button_url.endsWith('{{1}}') || !definition.button_example.startsWith(prefix)) {
      throw new Error('WHATSAPP_BUTTON_LINK_MISMATCH')
    }
    button = definition.button_example.slice(prefix.length)
  }
  return {
    name: definition.name,
    language: definition.language,
    body_parameters: definition.body_examples,
    header_parameter: definition.header_example,
    button_parameter: button,
  }
}

/** "+55 48 9****-9121" for logs and the screen. */
export function maskPhone(digits: string) {
  return `+${digits.slice(0, 2)} ${digits.slice(2, 4)} ${digits.slice(4, 5)}****-${digits.slice(-4)}`
}
