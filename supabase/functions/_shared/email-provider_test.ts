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

Deno.test('unified notifications keep the documented canonical From when the optional sender override is absent', () => {
  const previous = {
    blacksheepFrom: Deno.env.get('EMAIL_FROM_BLACKSHEEP'),
    blacksheepReply: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP'),
  }
  try {
    Deno.env.delete('EMAIL_FROM_BLACKSHEEP')
    Deno.env.delete('EMAIL_REPLY_TO_BLACKSHEEP')

    const blacksheep = notificationSenderForScope('BLACKSHEEP')
    const sabrina = notificationSenderForScope('SABRINA')
    assert(blacksheep?.from === 'BlackSheep Estúdio Criativo <agenda@blacksheepestudiocriativo.com.br>', 'BlackSheep notification sender fallback is missing')
    assert(sabrina?.from === blacksheep?.from, 'Sabrina unified notifications must share the fallback canonical From')
    assert(blacksheep?.replyTo === null, 'missing optional Reply-To must remain null')
    assert(senderForScope('BLACKSHEEP') === null, 'Supabase Auth scoped sender must remain environment-backed')
  } finally {
    const restore = (key: string, value: string | undefined) => value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value)
    restore('EMAIL_FROM_BLACKSHEEP', previous.blacksheepFrom)
    restore('EMAIL_REPLY_TO_BLACKSHEEP', previous.blacksheepReply)
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

Deno.test('provider adapter canonicalizes legacy manage-booking links before delivery', async () => {
  let capturedInit: RequestInit | undefined
  await sendEmailWithProvider({
    from: 'BlackSheep <agenda@example.test>',
    to: ['cliente@example.test'],
    subject: 'Reserva confirmada',
    text: 'Gerencie: https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token=abc123&scope=RESCHEDULE',
    html: '<a href="https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token=abc123&scope=RESCHEDULE">Gerenciar</a>',
  }, 'notification:test:canonical-manage-link', {
    apiKey: 'test-key',
    fetchImpl: (async (_input: string | URL | Request, init?: RequestInit) => {
      capturedInit = init
      return new Response(JSON.stringify({ id: 'provider-message-link' }), { status: 200 })
    }) as typeof fetch,
  })

  const body = String(capturedInit?.body ?? '')
  assert(!body.includes('/reserva/gerenciar?token='), 'legacy manage-booking URL reached the provider')
  assert(body.includes('/gerenciar-reserva#token=abc123&scope=RESCHEDULE'), 'canonical fragment manage-booking URL was not sent')
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
