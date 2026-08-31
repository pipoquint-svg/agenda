export type ServicePaymentMode = 'MINIMUM_OR_FULL' | 'MINIMUM_ONLY' | 'FULL_ONLY'

export type ServicePaymentPolicyInput = {
  pix_discount_percent: number | null
  payment_mode: ServicePaymentMode
  card_max_installments: number
}

export function normalizeServicePaymentPolicy(input: Record<string, unknown>): ServicePaymentPolicyInput {
  const rawPix = input.pix_discount_percent
  let pixDiscountPercent: number | null = null
  if (rawPix !== null && rawPix !== undefined && rawPix !== '') {
    const parsed = Number(rawPix)
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > 100) {
      throw new Error('PIX_DISCOUNT_PERCENT_INVALID')
    }
    pixDiscountPercent = Math.round(parsed * 100) / 100
  }

  const paymentMode = typeof input.payment_mode === 'string'
    ? input.payment_mode.trim().toUpperCase()
    : ''
  if (!['MINIMUM_OR_FULL', 'MINIMUM_ONLY', 'FULL_ONLY'].includes(paymentMode)) {
    throw new Error('PAYMENT_MODE_INVALID')
  }

  const cardMaxInstallments = Number(input.card_max_installments)
  if (!Number.isInteger(cardMaxInstallments) || cardMaxInstallments < 1 || cardMaxInstallments > 12) {
    throw new Error('CARD_MAX_INSTALLMENTS_INVALID')
  }

  return {
    pix_discount_percent: pixDiscountPercent,
    payment_mode: paymentMode as ServicePaymentMode,
    card_max_installments: cardMaxInstallments,
  }
}
