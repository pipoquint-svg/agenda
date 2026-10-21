import { buildBalancePaymentUrl } from './balance-payment-link.ts'
import { CANONICAL_MANAGE_PREFIX } from './email-provider.ts'
import { paymentResumeBaseUrl } from './payment-resume-email.ts'
import { paymentBaseUrl } from './prebook-email.ts'

/** Customer links that may sit behind a WhatsApp URL button. */
export const CUSTOMER_LINK_VARIABLES = [
  'appointment.manage_url',
  'pre_reservation.payment_url',
  'balance.payment_url',
  'payment.resume_url',
  'booking.url',
] as const

/** Public booking page a Rewards message points to (same site as the other customer links). */
export const BOOKING_URL = 'https://www.blacksheepestudiocriativo.com.br/agenda-e-valores'

export type CustomerLinkVariable = typeof CUSTOMER_LINK_VARIABLES[number]

const SAMPLE_TOKEN = 'a'.repeat(64)

/**
 * A sample built by the same code that builds the real link, so the button's
 * fixed part always matches what customers receive.
 */
export function customerLinkSample(variable: CustomerLinkVariable): string {
  switch (variable) {
    case 'appointment.manage_url':
      return `${CANONICAL_MANAGE_PREFIX}${SAMPLE_TOKEN}&scope=RESCHEDULE`
    case 'pre_reservation.payment_url':
      return `${paymentBaseUrl()}/pre-reserva/confirmar?token=${SAMPLE_TOKEN}`
    case 'balance.payment_url': {
      const base = Deno.env.get('PUBLIC_BOOKING_BASE_URL')?.trim().replace(/\/$/, '') ?? ''
      if (!base) throw new Error('WHATSAPP_BUTTON_LINK_UNAVAILABLE')
      return buildBalancePaymentUrl(base, SAMPLE_TOKEN)
    }
    case 'payment.resume_url':
      return `${paymentResumeBaseUrl()}/retomar-pagamento.html#token=${SAMPLE_TOKEN}`
    case 'booking.url':
      return BOOKING_URL
  }
}

/**
 * Meta button URL for a customer link: the site origin is fixed and approved,
 * the rest of the link is the {{1}} suffix sent with each message.
 */
export function customerLinkButton(variable: CustomerLinkVariable) {
  const sample = customerLinkSample(variable)
  const origin = new URL(sample).origin
  if (!sample.startsWith(`${origin}/`) || sample.length <= origin.length + 1) {
    throw new Error('WHATSAPP_BUTTON_LINK_UNAVAILABLE')
  }
  return { url: `${origin}/{{1}}`, example: sample }
}

/** Suffix to send as the button parameter for a real customer link. */
export function customerLinkSuffix(variable: CustomerLinkVariable, link: string): string {
  const { url } = customerLinkButton(variable)
  const prefix = url.slice(0, -'{{1}}'.length)
  if (!link.startsWith(prefix) || link.length === prefix.length) throw new Error('WHATSAPP_BUTTON_LINK_MISMATCH')
  return link.slice(prefix.length)
}
