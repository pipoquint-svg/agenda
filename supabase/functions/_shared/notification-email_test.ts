import { brandedEmailHtml, renderNotificationMessage, renderTemplate, templateVariableKeys } from './notification-email.ts'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

Deno.test('notification renderer replaces only declared variables', () => {
  const template = {
    id: 'template-id',
    title_template: 'Olá {{customer.name}}',
    body_template: 'Pague em {{balance.payment_url}}',
    variable_schema: ['customer.name', 'balance.payment_url'],
  }
  const message = renderNotificationMessage(template, {
    'customer.name': 'Sabrina',
    'balance.payment_url': 'https://example.test/pagar',
  }, 'BlackSheep Estúdio Criativo')
  assert(message.subject === 'Olá Sabrina', 'subject was not rendered from database template')
  assert(message.text.includes('https://example.test/pagar'), 'body variable was not rendered')
  assert(message.html.includes('BLACKSHEEP ESTÚDIO CRIATIVO'), 'shared brand wrapper was not applied')
  assert(message.html.includes('href="https://example.test/pagar"'), 'https links should be clickable in shared HTML')
})

Deno.test('notification renderer refuses variables outside template schema', () => {
  let failed = false
  try {
    renderTemplate('Olá {{customer.email}}', ['customer.name'], { 'customer.email': 'x@example.test' })
  } catch (error) {
    failed = error instanceof Error && error.message.startsWith('NOTIFICATION_TEMPLATE_VARIABLE_NOT_ALLOWED')
  }
  assert(failed, 'undeclared template variable should fail closed')
})

Deno.test('template variable schema supports strings and key objects', () => {
  const keys = templateVariableKeys(['customer.name', { key: 'operation.name' }, null])
  assert(keys.has('customer.name'), 'string variable missing')
  assert(keys.has('operation.name'), 'object variable missing')
  assert(keys.size === 2, 'invalid schema entries were not ignored')
})

Deno.test('shared email HTML escapes editable content', () => {
  const html = brandedEmailHtml('BlackSheep', '<script>alert(1)</script>')
  assert(!html.includes('<script>'), 'editable body was not escaped')
  assert(html.includes('&lt;script&gt;'), 'escaped body is missing')
})
