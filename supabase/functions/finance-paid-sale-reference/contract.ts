export const FINANCE_PAID_SALE_CONTRACT = 'FINANCE_PAID_SALE_REFERENCE_V1'

export type FinanceChargeRow = {
  id: string
  appointment_id: string
  transaction_type: string
  payment_purpose: string
  status: string
  contract_amount_settled: number | string
  requested_payment_kind?: string | null
  paid_at?: string | null
  provider?: string | null
  method?: string | null
  is_test?: boolean | null
}

export type FinanceRefundRow = {
  contract_amount_settled: number | string
  transaction_type: string
  payment_purpose: string
  status: string
  is_test?: boolean | null
}

const QUALIFYING_CHARGE_STATUSES = new Set(['APPROVED', 'PARTIALLY_REFUNDED', 'REFUNDED'])
const QUALIFYING_REFUND_STATUSES = new Set(['APPROVED', 'REFUNDED'])

function upper(value: unknown): string {
  return String(value ?? '').trim().toUpperCase()
}

function positiveAmount(value: unknown): number | null {
  const amount = Number(value)
  return Number.isFinite(amount) && amount > 0 ? amount : null
}

function validInstant(value: unknown): string | null {
  const raw = typeof value === 'string' ? value.trim() : ''
  if (!raw || !Number.isFinite(Date.parse(raw))) return null
  return new Date(raw).toISOString()
}

export function isQualifyingPaidSaleCharge(row: FinanceChargeRow): boolean {
  return row.is_test !== true
    && upper(row.transaction_type) === 'CHARGE'
    && upper(row.payment_purpose) === 'CONTRACT'
    && QUALIFYING_CHARGE_STATUSES.has(upper(row.status))
    && positiveAmount(row.contract_amount_settled) !== null
    && validInstant(row.paid_at) !== null
}

export function firstQualifyingPaidSaleCharge(rows: FinanceChargeRow[]): FinanceChargeRow | null {
  const qualified = rows.filter(isQualifyingPaidSaleCharge)
  qualified.sort((a, b) => {
    const aTime = Date.parse(String(a.paid_at))
    const bTime = Date.parse(String(b.paid_at))
    if (aTime !== bTime) return aTime - bTime
    return String(a.id).localeCompare(String(b.id))
  })
  return qualified[0] ?? null
}

export function paymentKind(row: FinanceChargeRow): 'MINIMUM' | 'FULL' | 'UNSPECIFIED' {
  const kind = upper(row.requested_payment_kind)
  return kind === 'MINIMUM' || kind === 'FULL' ? kind : 'UNSPECIFIED'
}

export function summarizeRefunds(chargeAmount: number, rows: FinanceRefundRow[]) {
  const refundedAmount = rows
    .filter((row) => row.is_test !== true
      && upper(row.transaction_type) === 'REFUND'
      && upper(row.payment_purpose) === 'CONTRACT'
      && QUALIFYING_REFUND_STATUSES.has(upper(row.status)))
    .reduce((total, row) => total + Math.max(0, Number(row.contract_amount_settled) || 0), 0)

  const rounded = Math.round(refundedAmount * 100) / 100
  const state = rounded <= 0 ? 'NONE' : rounded + 0.009 >= chargeAmount ? 'FULLY_REFUNDED' : 'PARTIALLY_REFUNDED'
  return { refunded_amount: rounded, reversal_state: state }
}

export function normalizePaidSaleReference(
  organizationId: string,
  tenantId: string,
  externalLeadId: number,
  charge: FinanceChargeRow,
  refundSummary: { refunded_amount: number; reversal_state: string },
) {
  if (!isQualifyingPaidSaleCharge(charge)) throw new Error('FINANCE_PAID_SALE_CHARGE_INVALID')
  return {
    contract: FINANCE_PAID_SALE_CONTRACT,
    authority: 'finance',
    adapter: 'agenda',
    state: 'VERIFIED',
    organization_id: organizationId,
    adapter_tenant_id: tenantId,
    external_lead_id: String(externalLeadId),
    finance_fact_ref: `payment_transaction:${charge.id}`,
    appointment_ref: `appointment:${charge.appointment_id}`,
    paid_sale_at: new Date(String(charge.paid_at)).toISOString(),
    payment_kind: paymentKind(charge),
    contract_amount_settled: Number(charge.contract_amount_settled),
    current_charge_status: upper(charge.status),
    provider: upper(charge.provider) || null,
    method: upper(charge.method) || null,
    refunded_amount: refundSummary.refunded_amount,
    reversal_state: refundSummary.reversal_state,
    milestone_semantics: 'FIRST_QUALIFYING_CONTRACT_PAYMENT',
  }
}
