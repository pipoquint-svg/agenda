import {
  brlToCents,
  checkInfinitePayPayment,
  createInfinitePayCheckoutLink,
  infinitePayPaymentStorageSnapshot,
  parseInfinitePayRedirectSignal,
  parseInfinitePayWebhookSignal,
  verifyInfinitePayPayment,
  type InfinitePayTransport,
} from './infinitepay.ts'

function assert(condition: unknown, message = 'assertion failed'): asserts condition {
  if (!condition) throw new Error(message)
}

function assertEquals(actual: unknown, expected: unknown, message = 'values differ'): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`)
  }
}

async function assertRejects(fn: () => Promise<unknown> | unknown, code: string): Promise<void> {
  try {
    await fn()
  } catch (cause) {
    assert(cause instanceof Error, 'expected Error')
    assertEquals(cause.message, code)
    return
  }
  throw new Error(`expected rejection ${code}`)
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

Deno.test('brlToCents preserves the table value exactly in cents', () => {
  assertEquals(brlToCents(890), 89000)
  assertEquals(brlToCents('1000.50'), 100050)
})

Deno.test('createInfinitePayCheckoutLink sends provider-owned payment choices only', async () => {
  let capturedUrl = ''
  let capturedBody: Record<string, unknown> = {}
  const transport: InfinitePayTransport = async (input, init) => {
    capturedUrl = String(input)
    capturedBody = JSON.parse(String(init?.body)) as Record<string, unknown>
    return jsonResponse({ url: 'https://checkout.infinitepay.com.br/sabrina?lenc=abc123' })
  }

  const result = await createInfinitePayCheckoutLink({
    handle: 'sabrina_pierri',
    orderNsu: '11111111-2222-3333-4444-555555555555',
    redirectUrl: 'https://sabrinapierri.com.br/pagamento-concluido',
    webhookUrl: 'https://example.supabase.co/functions/v1/infinitepay-webhook',
    customer: {
      name: 'Cliente Teste',
      email: 'CLIENTE@example.com',
      phone_number: '+55 (48) 99999-0000',
    },
    items: [{ quantity: 1, price: 89000, description: 'Natal Tradicional 20 Fotos' }],
  }, transport)

  assertEquals(capturedUrl, 'https://api.checkout.infinitepay.io/links')
  assertEquals(result.url, 'https://checkout.infinitepay.com.br/sabrina?lenc=abc123')
  assertEquals(capturedBody.handle, 'sabrina_pierri')
  assertEquals(capturedBody.order_nsu, '11111111-2222-3333-4444-555555555555')
  assertEquals(capturedBody.items, [{ quantity: 1, price: 89000, description: 'Natal Tradicional 20 Fotos' }])
  assertEquals(capturedBody.customer, {
    name: 'Cliente Teste',
    email: 'cliente@example.com',
    phone_number: '+5548999990000',
  })
  assert(!('method' in capturedBody), 'Agenda must not choose Pix/card for InfinitePay')
  assert(!('installments' in capturedBody), 'Agenda must not choose installments for InfinitePay')
  assert(!('discount' in capturedBody), 'Agenda must not apply a Pix discount for InfinitePay')
})

Deno.test('checkout adapter rejects a non-InfinitePay redirect returned by provider', async () => {
  const transport: InfinitePayTransport = async () => jsonResponse({ url: 'https://evil.example/checkout' })
  await assertRejects(() => createInfinitePayCheckoutLink({
    handle: 'sabrina_pierri',
    orderNsu: 'order-123',
    items: [{ quantity: 1, price: 1000, description: 'Teste' }],
  }, transport), 'INFINITEPAY_CHECKOUT_URL_INVALID')
})

Deno.test('payment_check allows paid_amount to differ from order amount', async () => {
  let requestBody: Record<string, unknown> = {}
  const transport: InfinitePayTransport = async (_input, init) => {
    requestBody = JSON.parse(String(init?.body)) as Record<string, unknown>
    return jsonResponse({
      success: true,
      paid: true,
      amount: 100000,
      paid_amount: 107350,
      installments: 6,
      capture_method: 'credit_card',
    })
  }

  const checked = await checkInfinitePayPayment({
    handle: 'sabrina_pierri',
    orderNsu: 'order-123',
    transactionNsu: 'tx-456',
    slug: 'invoice-789',
  }, transport)

  assertEquals(requestBody, {
    handle: 'sabrina_pierri',
    order_nsu: 'order-123',
    transaction_nsu: 'tx-456',
    slug: 'invoice-789',
  })
  assertEquals(checked.amount, 100000)
  assertEquals(checked.paidAmount, 107350)
  assertEquals(checked.installments, 6)
  assertEquals(checked.captureMethod, 'credit_card')
})

Deno.test('authoritative verification compares expected order against amount, not paid_amount', () => {
  const signal = parseInfinitePayWebhookSignal({
    invoice_slug: 'invoice-789',
    amount: 100000,
    paid_amount: 107350,
    installments: 6,
    capture_method: 'credit_card',
    transaction_nsu: 'tx-456',
    order_nsu: 'order-123',
    receipt_url: 'https://receipt.example/123',
  })
  const verified = verifyInfinitePayPayment({
    signal,
    expectedOrderNsu: 'order-123',
    expectedAmountCents: 100000,
    check: {
      success: true,
      paid: true,
      amount: 100000,
      paidAmount: 107350,
      installments: 6,
      captureMethod: 'credit_card',
      raw: { success: true, paid: true },
    },
  })
  assertEquals(verified.agendaMethod, 'CARD')
  assertEquals(verified.paidAmount, 107350)
  assertEquals(infinitePayPaymentStorageSnapshot(verified).paid_amount, 107350)
})

Deno.test('authoritative verification rejects a base amount mismatch', () => {
  const signal = parseInfinitePayWebhookSignal({
    invoice_slug: 'invoice-789',
    transaction_nsu: 'tx-456',
    order_nsu: 'order-123',
  })
  try {
    verifyInfinitePayPayment({
      signal,
      expectedOrderNsu: 'order-123',
      expectedAmountCents: 100000,
      check: {
        success: true,
        paid: true,
        amount: 99999,
        paidAmount: 100000,
        installments: 1,
        captureMethod: 'pix',
        raw: {},
      },
    })
  } catch (cause) {
    assert(cause instanceof Error)
    assertEquals(cause.message, 'INFINITEPAY_PAYMENT_AMOUNT_MISMATCH')
    return
  }
  throw new Error('expected amount mismatch')
})

Deno.test('redirect data is only a signal and can be parsed without trusting payment state', () => {
  const url = new URL('https://sabrinapierri.com.br/pagamento-concluido?order_nsu=order-123&transaction_nsu=tx-456&slug=invoice-789&capture_method=pix&receipt_url=https%3A%2F%2Freceipt.example%2F123')
  assertEquals(parseInfinitePayRedirectSignal(url), {
    orderNsu: 'order-123',
    transactionNsu: 'tx-456',
    slug: 'invoice-789',
    receiptUrl: 'https://receipt.example/123',
    captureMethod: 'pix',
  })
})

Deno.test('payment verification rejects untrusted signal method disagreement', () => {
  const signal = parseInfinitePayWebhookSignal({
    invoice_slug: 'invoice-789',
    transaction_nsu: 'tx-456',
    order_nsu: 'order-123',
    capture_method: 'pix',
  })
  try {
    verifyInfinitePayPayment({
      signal,
      expectedOrderNsu: 'order-123',
      expectedAmountCents: 1000,
      check: {
        success: true,
        paid: true,
        amount: 1000,
        paidAmount: 1010,
        installments: 2,
        captureMethod: 'credit_card',
        raw: {},
      },
    })
  } catch (cause) {
    assert(cause instanceof Error)
    assertEquals(cause.message, 'INFINITEPAY_CAPTURE_METHOD_MISMATCH')
    return
  }
  throw new Error('expected capture method mismatch')
})
