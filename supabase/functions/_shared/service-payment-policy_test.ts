import { assertEquals, assertThrows } from 'jsr:@std/assert'
import { normalizeServicePaymentPolicy } from './service-payment-policy.ts'

Deno.test('normaliza política de pagamento por serviço', () => {
  assertEquals(normalizeServicePaymentPolicy({
    pix_discount_percent: '5.25',
    payment_mode: 'minimum_only',
    card_max_installments: '10',
  }), {
    pix_discount_percent: 5.25,
    payment_mode: 'MINIMUM_ONLY',
    card_max_installments: 10,
  })
})

Deno.test('aceita herança do PIX com null', () => {
  assertEquals(normalizeServicePaymentPolicy({
    pix_discount_percent: null,
    payment_mode: 'FULL_ONLY',
    card_max_installments: 12,
  }).pix_discount_percent, null)
})

Deno.test('rejeita política e parcelamento fora do contrato', () => {
  assertThrows(() => normalizeServicePaymentPolicy({
    pix_discount_percent: 5,
    payment_mode: 'INVALID',
    card_max_installments: 6,
  }), Error, 'PAYMENT_MODE_INVALID')

  assertThrows(() => normalizeServicePaymentPolicy({
    pix_discount_percent: 5,
    payment_mode: 'MINIMUM_OR_FULL',
    card_max_installments: 13,
  }), Error, 'CARD_MAX_INSTALLMENTS_INVALID')
})

Deno.test('rejeita desconto PIX fora de 0 a 100', () => {
  assertThrows(() => normalizeServicePaymentPolicy({
    pix_discount_percent: 101,
    payment_mode: 'MINIMUM_OR_FULL',
    card_max_installments: 6,
  }), Error, 'PIX_DISCOUNT_PERCENT_INVALID')
})
