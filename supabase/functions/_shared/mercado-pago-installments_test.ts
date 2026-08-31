import { mercadoPagoPaymentStorageSnapshot, sanitizeMercadoPagoPayment } from './mercado-pago.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('card Order snapshot persists provider-confirmed installments for audit', () => {
  const snapshot = sanitizeMercadoPagoPayment({
    id: 'ORD-INSTALLMENTS-01',
    status: 'processed',
    total_amount: '300.00',
    external_reference: '22222222-2222-4222-8222-222222222222',
    transactions: {
      payments: [{
        id: 'PAY-INSTALLMENTS-01',
        amount: '300.00',
        status: 'processed',
        payment_method: {
          id: 'visa',
          type: 'credit_card',
          installments: 4,
        },
      }],
    },
  })

  assert(snapshot.installments === 4, 'card installments must come from provider response')
  const stored = mercadoPagoPaymentStorageSnapshot(snapshot)
  assert(stored.installments === 4, 'provider storage snapshot must retain installments for audit')
})

Deno.test('PIX Order snapshot never stores installments', () => {
  const snapshot = sanitizeMercadoPagoPayment({
    id: 'ORD-PIX-01',
    status: 'action_required',
    total_amount: '95.00',
    external_reference: '11111111-1111-4111-8111-111111111111',
    transactions: {
      payments: [{
        id: 'PAY-PIX-01',
        amount: '95.00',
        status: 'action_required',
        payment_method: {
          id: 'pix',
          type: 'bank_transfer',
        },
      }],
    },
  })

  assert(snapshot.installments === null, 'PIX must not have installments')
  const stored = mercadoPagoPaymentStorageSnapshot(snapshot)
  assert(stored.installments === null, 'PIX audit snapshot must keep installments null')
})
