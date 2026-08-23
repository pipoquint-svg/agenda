import {
  assertMercadoPagoPaymentMatchesIntent,
  buildMercadoPagoWebhookManifest,
  normalizeMercadoPagoPaymentStatus,
  payerIdentification,
  sanitizeMercadoPagoPayment,
  validateCardSubmission,
  verifyMercadoPagoWebhookSignature,
} from './mercado-pago.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

async function hmacHex(secret: string, text: string): Promise<string> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const result = new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(text)))
  return Array.from(result).map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

Deno.test('Mercado Pago webhook manifest preserves data id and validates HMAC', async () => {
  const manifest = buildMercadoPagoWebhookManifest('AbC123', 'request-xyz', '1704908010')
  assert(manifest === 'id:AbC123;request-id:request-xyz;ts:1704908010;', 'unexpected manifest')
  const secret = 'test-secret'
  const signature = await hmacHex(secret, manifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1704908010,v1=${signature}`,
    requestId: 'request-xyz',
    dataId: 'AbC123',
    secret,
  })
  assert(valid, 'expected valid signature')

  const invalid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1704908010,v1=${signature}`,
    requestId: 'other-request',
    dataId: 'AbC123',
    secret,
  })
  assert(!invalid, 'changed request id must invalidate signature')
})

Deno.test('Mercado Pago statuses normalize conservatively', () => {
  assert(normalizeMercadoPagoPaymentStatus('approved') === 'APPROVED', 'approved')
  assert(normalizeMercadoPagoPaymentStatus('rejected') === 'REJECTED', 'rejected')
  assert(normalizeMercadoPagoPaymentStatus('cancelled') === 'REJECTED', 'cancelled')
  assert(normalizeMercadoPagoPaymentStatus('expired') === 'EXPIRED', 'expired')
  assert(normalizeMercadoPagoPaymentStatus('in_process') === 'PENDING', 'in process')
  assert(normalizeMercadoPagoPaymentStatus('unknown_future_status') === 'PENDING', 'unknown should fail conservative')
})

Deno.test('payment snapshot excludes raw payer/card data and keeps PIX/3DS instructions only', () => {
  const snapshot = sanitizeMercadoPagoPayment({
    id: 123,
    status: 'pending',
    status_detail: 'pending_challenge',
    payment_method_id: 'master',
    payment_type_id: 'credit_card',
    transaction_amount: 475,
    external_reference: 'tx-id',
    payer: { email: 'secret@example.com', identification: { number: '52998224725' } },
    card: { first_six_digits: '123456', last_four_digits: '7890' },
    point_of_interaction: { transaction_data: { qr_code: 'PIX-CODE', qr_code_base64: 'BASE64', ticket_url: 'https://example.test/pix' } },
    three_ds_info: { external_resource_url: 'https://acs.example.test/challenge', creq: 'challenge-request' },
  })
  const serialized = JSON.stringify(snapshot)
  assert(snapshot.id === '123', 'provider id')
  assert(snapshot.point_of_interaction?.transaction_data?.qr_code === 'PIX-CODE', 'pix data')
  assert(snapshot.three_ds_info?.creq === 'challenge-request', '3DS challenge data')
  assert(!serialized.includes('secret@example.com'), 'payer must not be persisted in snapshot')
  assert(!serialized.includes('123456'), 'card digits must not be persisted in snapshot')
})

Deno.test('provider payment must match internal intent by reference, amount and method', () => {
  const pix = sanitizeMercadoPagoPayment({
    id: 'mp-1', status: 'approved', payment_method_id: 'pix', payment_type_id: 'bank_transfer',
    transaction_amount: '475.00', external_reference: '11111111-1111-4111-8111-111111111111',
  })
  assertMercadoPagoPaymentMatchesIntent(pix, {
    transactionId: '11111111-1111-4111-8111-111111111111', cashAmount: 475, method: 'PIX',
  })

  const card = sanitizeMercadoPagoPayment({
    id: 'mp-2', status: 'pending', payment_method_id: 'master', payment_type_id: 'credit_card',
    transaction_amount: 500, external_reference: '22222222-2222-4222-8222-222222222222',
  })
  assertMercadoPagoPaymentMatchesIntent(card, {
    transactionId: '22222222-2222-4222-8222-222222222222', cashAmount: '500.00', method: 'CARD', providerPaymentMethodId: 'master',
  })

  const invalidCases = [
    () => assertMercadoPagoPaymentMatchesIntent(pix, { transactionId: '33333333-3333-4333-8333-333333333333', cashAmount: 475, method: 'PIX' }),
    () => assertMercadoPagoPaymentMatchesIntent(pix, { transactionId: '11111111-1111-4111-8111-111111111111', cashAmount: 474.99, method: 'PIX' }),
    () => assertMercadoPagoPaymentMatchesIntent(pix, { transactionId: '11111111-1111-4111-8111-111111111111', cashAmount: 475, method: 'CARD' }),
    () => assertMercadoPagoPaymentMatchesIntent(card, { transactionId: '22222222-2222-4222-8222-222222222222', cashAmount: 500, method: 'CARD', providerPaymentMethodId: 'visa' }),
  ]
  for (const run of invalidCases) {
    let rejected = false
    try { run() } catch { rejected = true }
    assert(rejected, 'mismatched provider payment must be rejected')
  }
})

Deno.test('card submission accepts only tokenized bounded data', () => {
  const card = validateCardSubmission({ token: 'card_token_123456789', payment_method_id: 'visa', installments: 3, issuer_id: '123' })
  assert(card.paymentMethodId === 'visa' && card.installments === 3, 'valid tokenized card')

  let rejected = false
  try { validateCardSubmission({ token: '123', payment_method_id: 'visa', installments: 3 }) } catch { rejected = true }
  assert(rejected, 'short/raw-looking token must fail')
})

Deno.test('payer identification resolves CPF and CNPJ only', () => {
  assert(payerIdentification('529.982.247-25').type === 'CPF', 'cpf')
  assert(payerIdentification('11.222.333/0001-81').type === 'CNPJ', 'cnpj')
  let rejected = false
  try { payerIdentification('123') } catch { rejected = true }
  assert(rejected, 'invalid document size')
})
