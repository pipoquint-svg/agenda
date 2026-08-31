import {
  assertMercadoPagoPaymentMatchesIntent,
  buildMercadoPagoWebhookManifest,
  mercadoPagoPaymentStorageSnapshot,
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

Deno.test('Mercado Pago webhook manifest preserves Order data id and validates HMAC', async () => {
  const manifest = buildMercadoPagoWebhookManifest('ORD01ABC', 'request-xyz', '1704908010')
  assert(manifest === 'id:ORD01ABC;request-id:request-xyz;ts:1704908010;', 'unexpected manifest')
  const secret = 'test-secret'
  const signature = await hmacHex(secret, manifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1704908010,v1=${signature}`,
    requestId: 'request-xyz',
    dataId: 'ORD01ABC',
    secret,
  })
  assert(valid, 'expected valid signature')

  const invalid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1704908010,v1=${signature}`,
    requestId: 'other-request',
    dataId: 'ORD01ABC',
    secret,
  })
  assert(!invalid, 'changed request id must invalidate signature')
})

Deno.test('Mercado Pago webhook omits request-id component when provider omits the header', async () => {
  const dataId = 'ORDTST01ABC'
  const timestamp = '1704908011'
  const secret = 'test-secret'
  const canonicalManifest = buildMercadoPagoWebhookManifest(dataId.toLowerCase(), null, timestamp)
  assert(canonicalManifest === 'id:ordtst01abc;ts:1704908011;', 'request-id must be omitted entirely')

  const signature = await hmacHex(secret, canonicalManifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=${timestamp},v1=${signature}`,
    requestId: null,
    dataId,
    secret,
  })
  assert(valid, 'signature without request-id must validate using the reduced manifest')
})

Deno.test('Mercado Pago Order statuses normalize conservatively', () => {
  assert(normalizeMercadoPagoPaymentStatus('processed') === 'APPROVED', 'processed')
  assert(normalizeMercadoPagoPaymentStatus('failed') === 'REJECTED', 'failed')
  assert(normalizeMercadoPagoPaymentStatus('canceled') === 'REJECTED', 'canceled')
  assert(normalizeMercadoPagoPaymentStatus('expired') === 'EXPIRED', 'expired')
  assert(normalizeMercadoPagoPaymentStatus('action_required') === 'PENDING', 'action required')
  assert(normalizeMercadoPagoPaymentStatus('processing') === 'PENDING', 'processing')
  assert(normalizeMercadoPagoPaymentStatus('unknown_future_status') === 'PENDING', 'unknown should fail conservative')
})

Deno.test('Orders PIX snapshot exposes transient QR only to client and keeps storage minimal', () => {
  const snapshot = sanitizeMercadoPagoPayment({
    id: 'ORD01PIX',
    status: 'action_required',
    status_detail: 'waiting_transfer',
    external_reference: '11111111-1111-4111-8111-111111111111',
    total_amount: '475.00',
    created_date: '2026-08-23T00:00:00Z',
    payer: { email: 'secret@example.com', identification: { number: '52998224725' } },
    transactions: {
      payments: [{
        id: 'PAY01PIX',
        amount: '475.00',
        status: 'action_required',
        status_detail: 'waiting_transfer',
        payment_method: {
          id: 'pix',
          type: 'bank_transfer',
          qr_code: 'PIX-CODE',
          qr_code_base64: 'BASE64',
          ticket_url: 'https://example.test/pix',
        },
      }],
    },
  })

  const clientSerialized = JSON.stringify(snapshot)
  assert(snapshot.id === 'ORD01PIX', 'order id')
  assert(snapshot.provider_transaction_id === 'PAY01PIX', 'provider transaction id')
  assert(snapshot.status === 'pending', 'client status')
  assert(snapshot.point_of_interaction?.transaction_data?.qr_code === 'PIX-CODE', 'client receives pix instructions')
  assert(!clientSerialized.includes('secret@example.com'), 'payer must not be exposed in sanitized snapshot')
  assert(!clientSerialized.includes('52998224725'), 'document must not be exposed in sanitized snapshot')

  const stored = JSON.stringify(mercadoPagoPaymentStorageSnapshot(snapshot))
  assert(stored.includes('waiting_transfer'), 'storage keeps provider status evidence')
  assert(stored.includes('PAY01PIX'), 'storage keeps provider transaction id')
  assert(!stored.includes('PIX-CODE'), 'storage must not retain PIX copy/paste payload')
  assert(!stored.includes('BASE64'), 'storage must not retain PIX QR image')
  assert(!stored.includes('example.test/pix'), 'storage must not retain PIX ticket URL')
})

Deno.test('Orders 3DS snapshot returns challenge URL but storage drops it', () => {
  const snapshot = sanitizeMercadoPagoPayment({
    id: 'ORD01CARD',
    status: 'action_required',
    status_detail: 'pending_challenge',
    external_reference: '22222222-2222-4222-8222-222222222222',
    total_amount: '500.00',
    transactions: {
      payments: [{
        id: 'PAY01CARD',
        amount: '500.00',
        status: 'action_required',
        status_detail: 'pending_challenge',
        payment_method: {
          id: 'master',
          type: 'credit_card',
          installments: 1,
          token: 'must-never-be-exposed',
          transaction_security: {
            url: 'https://www.mercadopago.com.br/auth/card/challenge-token',
            validation: 'on_fraud_risk',
            liability_shift: 'required',
          },
        },
      }],
    },
  })

  assert(snapshot.status === 'pending', 'challenge remains pending')
  assert(snapshot.three_ds_info?.external_resource_url?.startsWith('https://'), 'client receives challenge URL')
  const clientSerialized = JSON.stringify(snapshot)
  assert(!clientSerialized.includes('must-never-be-exposed'), 'card token must not be exposed')

  const stored = JSON.stringify(mercadoPagoPaymentStorageSnapshot(snapshot))
  assert(!stored.includes('challenge-token'), 'storage must not retain 3DS challenge URL')
})

Deno.test('Order must match internal intent by reference, amount, one transaction and method', () => {
  const pix = sanitizeMercadoPagoPayment({
    id: 'ORD01PIX',
    status: 'action_required',
    status_detail: 'waiting_transfer',
    total_amount: '475.00',
    external_reference: '11111111-1111-4111-8111-111111111111',
    transactions: {
      payments: [{
        id: 'PAY01PIX', amount: '475.00', status: 'action_required', status_detail: 'waiting_transfer',
        payment_method: { id: 'pix', type: 'bank_transfer' },
      }],
    },
  })
  assertMercadoPagoPaymentMatchesIntent(pix, {
    transactionId: '11111111-1111-4111-8111-111111111111', cashAmount: 475, method: 'PIX',
  })

  const card = sanitizeMercadoPagoPayment({
    id: 'ORD01CARD',
    status: 'processed',
    status_detail: 'accredited',
    total_amount: '500.00',
    external_reference: '22222222-2222-4222-8222-222222222222',
    last_updated_date: '2026-08-23T00:00:00Z',
    transactions: {
      payments: [{
        id: 'PAY01CARD', amount: '500.00', status: 'processed', status_detail: 'accredited',
        payment_method: { id: 'master', type: 'credit_card', installments: 1 },
      }],
    },
  })
  assert(card.status === 'approved', 'processed order maps to approved client status')
  assert(card.date_approved === '2026-08-23T00:00:00Z', 'approved provider timestamp')
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
    assert(rejected, 'mismatched provider Order must be rejected')
  }
})

Deno.test('Order with multiple provider payment transactions is rejected', () => {
  const multiple = sanitizeMercadoPagoPayment({
    id: 'ORD01MULTI',
    status: 'processed',
    total_amount: '500.00',
    external_reference: '22222222-2222-4222-8222-222222222222',
    transactions: {
      payments: [
        { id: 'PAY1', amount: '250.00', payment_method: { id: 'master', type: 'credit_card' } },
        { id: 'PAY2', amount: '250.00', payment_method: { id: 'master', type: 'credit_card' } },
      ],
    },
  })
  let rejected = false
  try {
    assertMercadoPagoPaymentMatchesIntent(multiple, {
      transactionId: '22222222-2222-4222-8222-222222222222', cashAmount: 500, method: 'CARD', providerPaymentMethodId: 'master',
    })
  } catch {
    rejected = true
  }
  assert(rejected, 'Agenda must never accept multi-transaction Order for one internal charge')
})

Deno.test('card submission validates against reservation installment cap', () => {
  const card = validateCardSubmission({ token: 'card_token_123456789', payment_method_id: 'visa', installments: 3, issuer_id: '123' }, 6)
  assert(card.paymentMethodId === 'visa' && card.installments === 3, 'valid tokenized card')

  const ten = validateCardSubmission({ token: 'card_token_123456789', payment_method_id: 'visa', installments: 10 }, 10)
  assert(ten.installments === 10, 'snapshot cap above legacy six must be accepted')

  const twelve = validateCardSubmission({ token: 'card_token_123456789', payment_method_id: 'visa', installments: 12 }, 12)
  assert(twelve.installments === 12, 'twelve installments are valid when snapshot permits')

  let rejected = false
  try { validateCardSubmission({ token: '123', payment_method_id: 'visa', installments: 3 }, 6) } catch { rejected = true }
  assert(rejected, 'short/raw-looking token must fail')

  rejected = false
  try { validateCardSubmission({ token: 'card_token_123456789', payment_method_id: 'visa', installments: 10 }, 6) } catch (error) {
    rejected = error instanceof Error && error.message.startsWith('CARD_INSTALLMENTS_POLICY_EXCEEDED:')
  }
  assert(rejected, 'installments above reservation snapshot cap must fail')
})

Deno.test('payer identification resolves CPF and CNPJ only', () => {
  assert(payerIdentification('529.982.247-25').type === 'CPF', 'cpf')
  assert(payerIdentification('11.222.333/0001-81').type === 'CNPJ', 'cnpj')
  let rejected = false
  try { payerIdentification('123') } catch { rejected = true }
  assert(rejected, 'invalid document size')
})
