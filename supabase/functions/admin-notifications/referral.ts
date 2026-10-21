/** Rules of the referral code send that do not need the database. */

/** Calendar day in São Paulo: one referral code message per customer and day. */
export function saoPauloDay(now: Date) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
}

export function referralCodeDeliveryKey(templateId: string, customerId: string, day: string) {
  return `rewards-referral-code:${templateId}:${customerId}:${day}:WHATSAPP:CUSTOMER`
}

/** Sends per call: small enough to answer well within the browser and function time limits. */
export function referralBatchSize(value: unknown) {
  const size = Number(value)
  return Number.isInteger(size) && size >= 1 && size <= 25 ? size : 15
}

export function chunks<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let index = 0; index < items.length; index += size) out.push(items.slice(index, index + size))
  return out
}
