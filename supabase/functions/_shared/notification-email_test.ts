import {
  beginNotificationDelivery,
  brandedEmailHtml,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  renderTemplate,
  templateVariableKeys,
} from './notification-email.ts'

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

Deno.test('already-sent delivery is idempotent and never creates a second send attempt', async () => {
  let writes = 0
  const client = {
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => ({ data: { id: 'log-1', status: 'SENT', attempt_count: 1, provider_message_id: 'msg-1' }, error: null }),
        }),
      }),
      update: () => { writes += 1; return { eq: async () => ({ error: null }) } },
      insert: () => { writes += 1; return { select: () => ({ single: async () => ({ data: { id: 'new' }, error: null }) }) } },
    }),
  }
  const result = await beginNotificationDelivery(client, {
    templateId: 'template-1',
    eventKey: 'APPOINTMENT_APPROVED',
    audience: 'CUSTOMER',
    recipient: 'cliente@example.test',
    idempotencyKey: 'notification:already-sent',
  })
  assert(result.alreadySent === true, 'sent delivery must be recognized as already sent')
  assert(result.providerMessageId === 'msg-1', 'provider evidence must be preserved')
  assert(writes === 0, 'already sent delivery must not be mutated or inserted again')
})

Deno.test('delivery success and failure persist explicit history states', async () => {
  const updates: Array<Record<string, unknown>> = []
  const client = {
    from: (table: string) => {
      assert(table === 'notification_delivery_logs', 'delivery helper wrote outside central log table')
      return {
        update: (payload: Record<string, unknown>) => {
          updates.push(payload)
          return { eq: async () => ({ error: null }) }
        },
      }
    },
  }

  await markNotificationSent(client, 'log-1', 'provider-1')
  await markNotificationFailed(client, 'log-2', new Error('EMAIL_PROVIDER_HTTP_429'))

  assert(updates.length === 2, 'expected one SENT and one FAILED transition')
  assert(updates[0].status === 'SENT', 'successful provider delivery was not marked SENT')
  assert(updates[0].provider_message_id === 'provider-1', 'provider message id was not persisted')
  assert(updates[1].status === 'FAILED', 'provider failure was not marked FAILED')
  assert(updates[1].last_error_code === 'EMAIL_PROVIDER_HTTP_429', 'stable provider failure code was not persisted')
})
