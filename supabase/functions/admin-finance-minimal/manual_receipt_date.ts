export function financeServerDate(now = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(now)
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${values.year}-${values.month}-${values.day}`
}

export function manualReceiptPaidAt(selectedDate: unknown, legacyPaidAt: unknown, now = new Date(), expectedServerDate?: unknown): string | null {
  if (expectedServerDate !== undefined && expectedServerDate !== financeServerDate(now)) {
    throw new Error('MANUAL_RECEIPT_SERVER_DATE_CHANGED')
  }
  if (selectedDate === undefined) {
    const raw = typeof legacyPaidAt === 'string' ? legacyPaidAt.trim() : ''
    if (!raw) return null
    const parsed = Date.parse(raw)
    if (!Number.isFinite(parsed)) throw new Error('MANUAL_RECEIPT_PAID_AT_INVALID')
    return new Date(parsed).toISOString()
  }

  if (typeof selectedDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(selectedDate)) {
    throw new Error('MANUAL_RECEIPT_PAID_AT_INVALID')
  }
  const date = new Date(`${selectedDate}T12:00:00-03:00`)
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== selectedDate) {
    throw new Error('MANUAL_RECEIPT_PAID_AT_INVALID')
  }
  const today = financeServerDate(now)
  if (selectedDate > today) throw new Error('MANUAL_RECEIPT_PAID_AT_FUTURE')
  return selectedDate === today ? now.toISOString() : date.toISOString()
}
