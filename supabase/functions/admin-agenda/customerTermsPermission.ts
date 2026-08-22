export type CustomerFinancialTerms = {
  billing_mode: string | null
  invoice_due_days: number | null
}

function normalizeMode(value: string | null | undefined): string {
  return (value ?? '').trim().toUpperCase()
}

function normalizeDays(value: number | string | null | undefined): number | null {
  if (value === null || value === undefined || value === '') return null
  const next = Number(value)
  return Number.isFinite(next) ? next : null
}

/**
 * FINANCE_MANAGE is required only when the financial portion of a customer's
 * commercial terms actually changes. This lets an operations manager edit
 * pre-booking settings for an already-invoiced customer without gaining the
 * ability to change billing mode or due days.
 */
export function customerFinancialTermsChanged(
  current: CustomerFinancialTerms | null,
  proposed: CustomerFinancialTerms,
): boolean {
  const proposedMode = normalizeMode(proposed.billing_mode)
  const proposedDays = normalizeDays(proposed.invoice_due_days)

  if (!current) {
    return proposedMode === 'INVOICE' || proposedDays !== null
  }

  return normalizeMode(current.billing_mode) !== proposedMode
    || normalizeDays(current.invoice_due_days) !== proposedDays
}
