import { assertEquals, assertMatch, assertNotEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1'
import { submissionStatus, submissionView, whatsappCategory, whatsappSettings, whatsappTemplateDefinition } from './whatsapp-template.ts'

const catalog = ['customer.name', 'appointment.public_code', 'appointment.start_at']
const examples = {
  'customer.name': 'Teste BlackSheep',
  'appointment.public_code': 'TESTE-1234',
  'appointment.start_at': '30/08/2026 14:00',
}
const base = {
  templateId: '1a2b3c4d-0000-4000-8000-000000000000',
  eventKey: 'APPOINTMENT_APPROVED',
  catalog,
  examples,
}

Deno.test('numbers variables by first use and keeps a sample for each', async () => {
  const definition = await whatsappTemplateDefinition({
    ...base,
    body: 'Olá {{customer.name}}! Reserva {{ appointment.public_code }} em {{appointment.start_at}}. Até logo, {{customer.name}}.',
  })
  assertEquals(definition.body_text, 'Olá {{1}}! Reserva {{2}} em {{3}}. Até logo, {{1}}.')
  assertEquals(definition.body_examples, ['Teste BlackSheep', 'TESTE-1234', '30/08/2026 14:00'])
  assertEquals(definition.category, 'UTILITY')
  assertEquals(definition.language, 'pt_BR')
  assertMatch(definition.name, /^agenda_appointment_approved_1a2b3c4d_[0-9a-f]{8}$/)
})

Deno.test('the same text keeps its Meta name and an edit changes it', async () => {
  const first = await whatsappTemplateDefinition({ ...base, body: 'Olá {{customer.name}}, tudo certo.' })
  const again = await whatsappTemplateDefinition({ ...base, body: 'Olá {{customer.name}}, tudo certo.' })
  const edited = await whatsappTemplateDefinition({ ...base, body: 'Oi {{customer.name}}, tudo certo.' })
  assertEquals(first.name, again.name)
  assertNotEquals(first.name, edited.name)
})

Deno.test('rejects drafts Meta would refuse', async () => {
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body: '  ' }), Error, 'WHATSAPP_TEMPLATE_BODY_REQUIRED')
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body: 'Olá {{cliente}}.' }), Error, 'WHATSAPP_TEMPLATE_VARIABLE_INVALID')
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body: '{{customer.name}}, confirmado.' }), Error, 'WHATSAPP_TEMPLATE_PARAMETER_EDGE')
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body: 'Reserva de {{customer.name}}' }), Error, 'WHATSAPP_TEMPLATE_PARAMETER_EDGE')
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body: 'x'.repeat(1025) }), Error, 'WHATSAPP_TEMPLATE_BODY_TOO_LONG')
})

Deno.test('classifies birthday and manual messages as marketing', () => {
  assertEquals(whatsappCategory('BIRTHDAY'), 'MARKETING')
  assertEquals(whatsappCategory('MANUAL'), 'MARKETING')
  assertEquals(whatsappCategory('REWARDS_WINBACK'), 'MARKETING')
  assertEquals(whatsappCategory('REWARDS_COUPON_ISSUED'), 'MARKETING')
  assertEquals(whatsappCategory('REWARDS_COUPON_EXPIRING'), 'MARKETING')
  assertEquals(whatsappCategory('APPOINTMENT_REMINDER'), 'UTILITY')
})

Deno.test('maps Meta statuses onto submission states', () => {
  assertEquals(submissionStatus('PENDING'), { status: 'PENDING_REVIEW', errorCode: null })
  assertEquals(submissionStatus('APPROVED'), { status: 'APPROVED', errorCode: null })
  assertEquals(submissionStatus('REJECTED'), { status: 'REJECTED', errorCode: null })
  assertEquals(submissionStatus('PAUSED'), { status: 'FAILED', errorCode: 'META_TEMPLATE_PAUSED' })
  assertEquals(submissionStatus('NOT_FOUND'), null)
  assertEquals(submissionStatus('SOMETHING'), { status: 'FAILED', errorCode: 'META_TEMPLATE_STATUS_UNKNOWN' })
})

Deno.test('flags drafts edited after submission and hides provider ids', () => {
  const row = {
    notification_template_id: base.templateId,
    status: 'REJECTED',
    provider_error_code: null,
    provider_error_message: 'INVALID_FORMAT',
    submitted_at: '2026-10-20T20:00:00Z',
    approved_at: null,
    updated_at: '2026-10-20T20:05:00Z',
  }
  const view = submissionView(row, '2026-10-20T21:00:00Z')
  assertEquals(view.changed_since_submission, true)
  assertEquals(view.rejected_reason, 'INVALID_FORMAT')
  assertEquals('provider_template_id' in view, false)
  assertEquals(submissionView(row, '2026-10-20T19:00:00Z').changed_since_submission, false)
})

Deno.test('adds header, footer and validity and renames the template', async () => {
  const body = 'Olá {{customer.name}}, tudo certo.'
  const plain = await whatsappTemplateDefinition({ ...base, body })
  const full = await whatsappTemplateDefinition({
    ...base,
    body,
    settings: { category: 'UTILITY', header_text: 'Reserva {{appointment.public_code}}', footer_text: 'BlackSheep', ttl_seconds: 3600, variable_examples: {}, button_text: null, button_variable: null },
  })
  assertEquals(full.header_text, 'Reserva {{1}}')
  assertEquals(full.header_example, 'TESTE-1234')
  assertEquals(full.body_text, 'Olá {{1}}, tudo certo.')
  assertEquals(full.footer_text, 'BlackSheep')
  assertEquals(full.ttl_seconds, 3600)
  assertNotEquals(full.name, plain.name)
  const bodyOnly = await whatsappTemplateDefinition({ ...base, body, settings: { category: 'UTILITY', header_text: null, footer_text: null, ttl_seconds: null, variable_examples: {}, button_text: null, button_variable: null } })
  assertEquals(bodyOnly.name, plain.name)
})

Deno.test('the chosen category wins and marketing drops the validity', async () => {
  const definition = await whatsappTemplateDefinition({
    ...base,
    body: 'Olá {{customer.name}}, novidade.',
    settings: { category: 'MARKETING', header_text: null, footer_text: null, ttl_seconds: 3600, variable_examples: {}, button_text: null, button_variable: null },
  })
  assertEquals(definition.category, 'MARKETING')
  assertEquals(definition.ttl_seconds, null)
})

Deno.test('validates the WhatsApp fields an admin saves', () => {
  assertEquals(whatsappSettings({ category: 'utility', header_text: ' Olá {{customer.name}} ', footer_text: '', ttl_seconds: '3600' }, catalog), {
    category: 'UTILITY', header_text: 'Olá {{customer.name}}', footer_text: null, ttl_seconds: 3600, variable_examples: {},
    button_text: null, button_variable: null,
  })
  assertThrows(() => whatsappSettings({ category: 'AUTH' }, catalog), Error, 'WHATSAPP_CATEGORY_INVALID')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', header_text: '{{customer.name}} {{appointment.public_code}}' }, catalog), Error, 'WHATSAPP_HEADER_VARIABLE_LIMIT')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', header_text: 'x'.repeat(61) }, catalog), Error, 'WHATSAPP_HEADER_INVALID')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', footer_text: 'Oi {{customer.name}}' }, catalog), Error, 'WHATSAPP_FOOTER_VARIABLE')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', ttl_seconds: 999 }, catalog), Error, 'WHATSAPP_TTL_INVALID')
  assertThrows(() => whatsappSettings({ category: 'MARKETING', ttl_seconds: 3600 }, catalog), Error, 'WHATSAPP_TTL_INVALID')
})

Deno.test('uses the samples the admin typed and renames when they change', async () => {
  const body = 'Olá {{customer.name}}, sua reserva {{appointment.public_code}} está confirmada.'
  const settings = { category: 'UTILITY' as const, header_text: null, footer_text: null, ttl_seconds: null, variable_examples: { 'customer.name': 'Maria' }, button_text: null, button_variable: null }
  const custom = await whatsappTemplateDefinition({ ...base, body, settings })
  assertEquals(custom.body_examples, ['Maria', 'TESTE-1234'])
  const other = await whatsappTemplateDefinition({ ...base, body, settings: { ...settings, variable_examples: { 'customer.name': 'Joana' } } })
  assertNotEquals(custom.name, other.name)
  assertEquals(whatsappSettings({ category: 'UTILITY', variable_examples: { 'customer.name': ' Maria ', 'appointment.public_code': '' } }, catalog).variable_examples, { 'customer.name': 'Maria' })
  assertThrows(() => whatsappSettings({ category: 'UTILITY', variable_examples: { cliente: 'Maria' } }, catalog), Error, 'WHATSAPP_EXAMPLES_INVALID')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', variable_examples: { 'customer.name': 'a\nb' } }, catalog), Error, 'WHATSAPP_EXAMPLE_INVALID')
})

Deno.test('puts a customer link behind a URL button', async () => {
  const body = 'Olá {{customer.name}}, sua reserva está confirmada.'
  const settings = { category: 'UTILITY' as const, header_text: null, footer_text: null, ttl_seconds: null, variable_examples: {}, button_text: 'Gerenciar reserva', button_variable: 'appointment.manage_url' }
  const buttonLink = (variable: string) => ({ url: 'https://www.blacksheepestudiocriativo.com.br/{{1}}', example: `https://www.blacksheepestudiocriativo.com.br/gerenciar-reserva#token=${variable.length}` })
  const withButton = await whatsappTemplateDefinition({ ...base, body, settings, buttonLink })
  assertEquals(withButton.button_text, 'Gerenciar reserva')
  assertEquals(withButton.button_url, 'https://www.blacksheepestudiocriativo.com.br/{{1}}')
  const plain = await whatsappTemplateDefinition({ ...base, body })
  assertNotEquals(withButton.name, plain.name)
  assertEquals(plain.button_url, null)
  await assertRejects(() => whatsappTemplateDefinition({ ...base, body, settings }), Error, 'WHATSAPP_BUTTON_LINK_UNAVAILABLE')
  const links = [...catalog, 'appointment.manage_url', 'customer.email']
  assertEquals(whatsappSettings({ category: 'UTILITY', button_text: ' Gerenciar reserva ', button_variable: 'appointment.manage_url' }, links).button_variable, 'appointment.manage_url')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', button_text: 'Abrir' }, links), Error, 'WHATSAPP_BUTTON_INVALID')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', button_text: 'x'.repeat(26), button_variable: 'appointment.manage_url' }, links), Error, 'WHATSAPP_BUTTON_INVALID')
  assertThrows(() => whatsappSettings({ category: 'UTILITY', button_text: 'Abrir', button_variable: 'customer.email' }, links), Error, 'WHATSAPP_BUTTON_LINK_INVALID')
})
