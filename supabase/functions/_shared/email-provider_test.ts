import { notificationSenderForScope, senderForScope, sendEmailWithProvider, type EmailProviderPayload } from './email-provider.ts'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

Deno.test('unified notifications share one canonical From and Reply-To without changing scoped Auth sender resolution', () => {
  const previous = {
    blacksheepFrom: Deno.env.get('EMAIL_FROM_BLACKSHEEP'),
    blacksheepReply: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP'),
    sabrinaFrom: Deno.env.get('EMAIL_FROM_SABRINA'),
    sabrinaReply: Deno.env.get('EMAIL_REPLY_TO_SABRINA'),
  }
  try {
    Deno.env.set('EMAIL_FROM_BLACKSHEEP', 'BlackSheep <agenda@example.test>')
    Deno.env.set('EMAIL_REPLY_TO_BLACKSHEEP', 'agenda@example.test')
    Deno.env.set('EMAIL_FROM_SABRINA', 'Sabrina <sabrina@example.test>')
    Deno.env.set('EMAIL_REPLY_TO_SABRINA', 'sabrina@example.test')

    const blacksheep = notificationSenderForScope('BLACKSHEEP')
    const sabrina = notificationSenderForScope('SABRINA')
    assert(Boolean(blacksheep && sabrina), 'notification senders must resolve for both operation scopes')
    assert(blacksheep!.from === sabrina!.from, 'notification platform must use the same From identity')
    assert(blacksheep!.replyTo === sabrina!.replyTo, 'notification platform must use the same Reply-To identity')
    assert(blacksheep!.brandName === 'BlackSheep Estúdio Criativo', 'BlackSheep content brand was lost')
    assert(sabrina!.brandName === 'Sabrina Pierri', 'Sabrina content brand was lost')

    const scopedSabrina = senderForScope('SABRINA')
    assert(scopedSabrina?.from === 'Sabrina <sabrina@example.test>', 'legacy scoped sender resolution changed unexpectedly')
  } finally {
    const restore = (key: string, value: string | undefined) => value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value)
    restore('EMAIL_FROM_BLACKSHEEP', previous.blacksheepFrom)
    restore('EMAIL_REPLY_TO_BLACKSHEEP', previous.blacksheepReply)
    restore('EMAIL_FROM_SABRINA', previous.sabrinaFrom)
    restore('EMAIL_REPLY_TO_SABRINA', previous.sabrinaReply)
  }
})

Deno.test('provider adapter preserves rendered payload and idempotency contract', async () => {
  const payload: EmailProviderPayload = {
    from: 'BlackSheep <agenda@example.test>',
    to: ['cliente@example.test'],
    subject: 'Reserva confirmada',
    text: 'Corpo em texto',
    html: '<p>Corpo</p>',
    reply_to: 'agenda@example.test',
  }
  let capturedUrl = ''
  let capturedInit: RequestInit | undefined
  const providerMessageId = await sendEmailWithProvider(payload, 'notification:test:1', {
    apiKey: 'test-key',
    fetchImpl: (async (input: string | URL | Request, init?: RequestInit) => {
      capturedUrl = String(input)
      capturedInit = init
      return new Response(JSON.stringify({ id: 'provider-message-1' }), { status: 200 })
    }) as typeof fetch,
  })

  assert(providerMessageId === 'provider-message-1', 'provider message id was not returned')
  assert(capturedUrl === 'https://api.resend.com/emails', 'canonical provider endpoint changed')
  const headers = new Headers(capturedInit?.headers)
  assert(headers.get('idempotency-key') === 'notification:test:1', 'idempotency key was not forwarded')
  assert(headers.get('authorization') === 'Bearer test-key', 'provider authorization header is missing')
  assert(capturedInit?.body === JSON.stringify(payload), 'rendered provider payload changed in transport')
})

Deno.test('provider rejection becomes a stable failure code for delivery history', async () => {
  let code = ''
  try {
    await sendEmailWithProvider({
      from: 'BlackSheep <agenda@example.test>',
      to: ['cliente@example.test'],
      subject: 'Teste',
      text: 'Falha controlada',
    }, 'notification:test:failure', {
      apiKey: 'test-key',
      fetchImpl: (async () => new Response('rate limited', { status: 429 })) as typeof fetch,
    })
  } catch (error) {
    code = error instanceof Error ? error.message : ''
  }
  assert(code === 'EMAIL_PROVIDER_HTTP_429', 'provider rejection must remain visible as a stable failure code')
})
