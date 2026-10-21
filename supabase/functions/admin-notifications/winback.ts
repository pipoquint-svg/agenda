/** Rules of the win-back batch that do not need the database. */

/** "LARISSA SOUZA" → "Larissa": the message greets by first name. */
export function greetingName(name: unknown) {
  const first = String(name ?? '').trim().split(/\s+/)[0] ?? ''
  return first ? first.charAt(0).toLocaleUpperCase('pt-BR') + first.slice(1).toLocaleLowerCase('pt-BR') : ''
}

/** One coupon and one message per customer and absence (the last rental date marks the absence). */
export function winbackKeys(campaignId: string, templateId: string, customerId: string, lastRentalAt: unknown) {
  const absence = String(lastRentalAt ?? '').slice(0, 10) || 'unknown'
  return {
    issuance: `winback:${campaignId}:${customerId}:${absence}`,
    delivery: `rewards-winback:${templateId}:${customerId}:${absence}:WHATSAPP:CUSTOMER`,
  }
}
