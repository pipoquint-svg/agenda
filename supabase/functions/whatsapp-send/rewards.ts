/**
 * Rewards "Cupom Rewards liberado": issued and sent N minutes after the reservation ends,
 * on the same scheduled path as the balance message. These helpers hold the rules that do
 * not need the database.
 */
export const REWARDS_COUPON_EVENT = 'REWARDS_COUPON_ISSUED'
export const REWARDS_REFERRAL_EVENT = 'REWARDS_REFERRAL_REWARD'
/** Rewards messages sent after a reservation ends. */
export const REWARDS_DISPATCH_EVENTS = [REWARDS_COUPON_EVENT, REWARDS_REFERRAL_EVENT]
/** Campaign triggers whose coupon comes from one reservation of the same customer. */
export const APPOINTMENT_TRIGGERS = ['RENTAL_COMPLETED_FINANCIALLY_CLEARED', 'FREE_VISIT_COMPLETED']

/** Which campaign triggers each Rewards message serves. */
export function triggerServes(eventKey: string, triggerKind: string) {
  return eventKey === REWARDS_REFERRAL_EVENT ? triggerKind === 'REFERRAL_FIRST_RENTAL' : APPOINTMENT_TRIGGERS.includes(triggerKind)
}

type ScheduledTemplate = { id: string; schedule_mode: string | null; schedule_offset_minutes: number | null }

/**
 * The schedule key is `template:version:mode:offset`. Rewards ignores the version: a
 * changed reservation still earns its coupon. Mode and offset must still be the current ones.
 */
export function rewardsScheduleMatches(scheduleKey: string, template: ScheduledTemplate) {
  const [id, version, mode, offset, ...rest] = scheduleKey.split(':')
  return rest.length === 0 && id === template.id && /^\d+$/.test(version ?? '') &&
    template.schedule_mode === 'AFTER_END' && mode === template.schedule_mode &&
    offset === String(template.schedule_offset_minutes)
}

/** One coupon per campaign and reservation, whatever job asks for it. */
export const issuanceKey = (campaignId: string, appointmentId: string) => `rewards-dispatch:${campaignId}:${appointmentId}`
/** One message per message template and reservation (no version: a change never sends it twice). */
export const rewardsDeliveryKey = (templateId: string, appointmentId: string, eventKey = REWARDS_COUPON_EVENT) =>
  `rewards:${templateId}:${appointmentId}:${eventKey}:WHATSAPP:CUSTOMER`

/** "1 hora", "1h30", "2 horas", "45 minutos". */
export function hoursLabel(minutes: unknown) {
  const total = Math.max(0, Math.round(Number(minutes) || 0))
  const hours = Math.floor(total / 60)
  const rest = total % 60
  if (!hours) return `${rest} minutos`
  if (!rest) return hours === 1 ? '1 hora' : `${hours} horas`
  return `${hours}h${String(rest).padStart(2, '0')}`
}

/** Unpaid is not final: the payment trigger queues the message again when it is paid. */
export function rewardsSkipReason(detail: string) {
  return detail === 'MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED' ? 'REWARDS_WAITING_PAYMENT' : `REWARDS_NOT_ELIGIBLE:${detail || 'UNKNOWN'}`
}

export function couponDiscountLabel(type: unknown, value: unknown) {
  const amount = Number(value)
  if (!Number.isFinite(amount) || amount <= 0) return ''
  return String(type).toUpperCase() === 'PERCENT'
    ? `${amount.toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`
    : amount.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

export function couponDateLabel(value: unknown) {
  const date = new Date(String(value ?? ''))
  if (!value || Number.isNaN(date.getTime())) return ''
  return date.toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })
}

export function couponDaysLeft(value: unknown, now = Date.now()) {
  const date = new Date(String(value ?? ''))
  if (!value || Number.isNaN(date.getTime())) return ''
  return String(Math.max(0, Math.ceil((date.getTime() - now) / 86_400_000)))
}
