import {
  assertSafeCustomHtml,
  beginNotificationDelivery,
  brandedEmailHtml,
  markNotificationFailed,
  markNotificationSent,
  renderCustomEmailHtml,
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

Deno.test('notification renderer uses custom HTML while keeping text alternative', () => {
  const template = {
    id: 'template-id',
    title_template: 'Olá {{customer.name}}',
    body_template: 'Versão texto para {{customer.name}}',
    html_template: '<main><h1>Olá {{customer.name}}</h1><a href="{{operation.site_url}}">Abrir site</a></main>',
    variable_schema: ['customer.name', 'operation.site_url'],
  }
  const message = renderNotificationMessage(template, {
    'customer.name': 'Sabrina & Pipo',
    'operation.site_url': 'https://example.test/?a=1&b=2',
  }, 'BlackSheep')
  assert(message.text === 'Versão texto para Sabrina & Pipo', 'plain-text alternative must remain available')
  assert(message.html.includes('Sabrina &amp; Pipo'), 'custom HTML variables must be escaped')
  assert(message.html.includes('https://example.test/?a=1&amp;b=2'), 'custom HTML URL variable must be attribute-safe')
  assert(!message.html.includes('BLACKSHEEP</div>'), 'custom HTML should not be replaced by legacy wrapper')
})

Deno.test('custom HTML fragments receive a minimal email document wrapper', () => {
  const html = renderCustomEmailHtml('<strong>{{customer.name}}</strong>', ['customer.name'], { 'customer.name': 'Sabrina' })
  assert(html.startsWith('<!doctype html><html lang="pt-BR"><body>'), 'HTML fragment should receive a document wrapper')
  assert(html.includes('<strong>Sabrina</strong>'), 'custom HTML content was not preserved')
})

Deno.test('custom HTML rejects executable or active content', () => {
  const unsafe = [
    '<script>alert(1)</script>',
    '<img src="x" onerror="alert(1)">',
    '<a href="javascript:alert(1)">x</a>',
    '<iframe src="https://example.test"></iframe>',
  ]
  for (const source of unsafe) {
    let failed = false
    try {
      assertSafeCustomHtml(source)
    } catch (error) {
      failed = error instanceof Error && error.message === 'NOTIFICATION_HTML_UNSAFE'
    }
    assert(failed, `unsafe custom HTML should fail closed: ${source}`)
  }
})

Deno.test('custom HTML enforces an email-size guard', () => {
  let failed = false
  try {
    assertSafeCustomHtml(`<div>${'a'.repeat(90_100)}</div>`)
  } catch (error) {
    failed = error instanceof Error && error.message === 'NOTIFICATION_HTML_TOO_LARGE'
  }
  assert(failed, 'oversized HTML should fail before provider delivery')
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

Deno.test('provider evidence is authoritative even if a stale retry previously marked the row failed', async () => {
  let writes = 0
  const client = {
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => ({ data: { id: 'log-1', status: 'FAILED', attempt_count: 5, provider_message_id: 'msg-accepted' }, error: null }),
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
    idempotencyKey: 'notification:provider-evidence',
  })
  assert(result.alreadySent === true, 'provider evidence must suppress duplicate provider sends')
  assert(result.providerMessageId === 'msg-accepted', 'accepted provider message id must be returned')
  assert(writes === 0, 'provider evidence must not start another delivery attempt')
})

Deno.test('delivery success and failure persist explicit history states without downgrading provider evidence', async () => {
  const updates: Array<Record<string, unknown>> = []
  const filters: Array<[string, string, unknown]> = []
  const client = {
    from: (table: string) => {
      assert(table === 'notification_delivery_logs', 'delivery helper wrote outside central log table')
      return {
        update: (payload: Record<string, unknown>) => {
          updates.push(payload)
          const chain: any = {
            eq: (column: string, value: unknown) => { filters.push(['eq', column, value]); return chain },
            neq: (column: string, value: unknown) => { filters.push(['neq', column, value]); return chain },
            is: (column: string, value: unknown) => { filters.push(['is', column, value]); return Promise.resolve({ error: null }) },
            then: (resolve: (value: { error: null }) => unknown) => resolve({ error: null }),
          }
          return chain
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
  assert(filters.some(([op, column, value]) => op === 'neq' && column === 'status' && value === 'SENT'), 'failure transition must not overwrite SENT')
  assert(filters.some(([op, column, value]) => op === 'is' && column === 'provider_message_id' && value === null), 'failure transition must not overwrite provider evidence')
})
