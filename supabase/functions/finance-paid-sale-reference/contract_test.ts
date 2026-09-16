import {
  firstQualifyingPaidSaleCharge,
  isQualifyingPaidSaleCharge,
  normalizePaidSaleReference,
  summarizeRefunds,
  type FinanceChargeRow,
} from './contract.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

const base = (overrides: Partial<FinanceChargeRow> = {}): FinanceChargeRow => ({
  id: '11111111-1111-4111-8111-111111111111',
  appointment_id: '22222222-2222-4222-8222-222222222222',
  transaction_type: 'CHARGE',
  payment_purpose: 'CONTRACT',
  status: 'APPROVED',
  contract_amount_settled: 500,
  requested_payment_kind: 'MINIMUM',
  paid_at: '2026-09-15T17:00:00Z',
  provider: 'MERCADO_PAGO',
  method: 'PIX',
  is_test: false,
  ...overrides,
})

Deno.test('PF-100: first approved minimum contract payment is the paid-sale milestone', () => {
  const first = base()
  const laterFull = base({
    id: '33333333-3333-4333-8333-333333333333',
    requested_payment_kind: 'FULL',
    paid_at: '2026-09-15T18:00:00Z',
  })
  const selected = firstQualifyingPaidSaleCharge([laterFull, first])
  assert(selected?.id === first.id, 'first qualifying payment must win even if a full payment happens later')
  const normalized = normalizePaidSaleReference('44444444-4444-4444-8444-444444444444', '55555555-5555-4555-8555-555555555555', 123, first, summarizeRefunds(500, []))
  assert(normalized.state === 'VERIFIED', 'qualified payment must produce VERIFIED')
  assert(normalized.payment_kind === 'MINIMUM', 'deposit/minimum must remain visible')
  assert(normalized.milestone_semantics === 'FIRST_QUALIFYING_CONTRACT_PAYMENT', 'milestone semantics must be explicit')
})

Deno.test('PF-100: pending rejected expired test and zero-value payments do not qualify', () => {
  for (const row of [
    base({ status: 'PENDING' }),
    base({ status: 'REJECTED' }),
    base({ status: 'EXPIRED' }),
    base({ is_test: true }),
    base({ contract_amount_settled: 0 }),
    base({ paid_at: null }),
    base({ transaction_type: 'REFUND' }),
    base({ payment_purpose: 'CANCELLATION_PENALTY' }),
  ]) {
    assert(!isQualifyingPaidSaleCharge(row), `row should not qualify: ${JSON.stringify(row)}`)
  }
})

Deno.test('PF-100: refunded original charge preserves historical milestone and exposes reversal', () => {
  const charge = base({ status: 'REFUNDED' })
  assert(isQualifyingPaidSaleCharge(charge), 'Finance gross settlement remains a historical payment fact after refund')
  const refund = summarizeRefunds(500, [{
    contract_amount_settled: 500,
    transaction_type: 'REFUND',
    payment_purpose: 'CONTRACT',
    status: 'APPROVED',
    is_test: false,
  }])
  assert(refund.refunded_amount === 500, 'refund amount must be visible')
  assert(refund.reversal_state === 'FULLY_REFUNDED', 'full refund must be explicit instead of erasing paid_at')
})

Deno.test('PF-100: partial refund is distinct from full refund', () => {
  const refund = summarizeRefunds(500, [{
    contract_amount_settled: 100,
    transaction_type: 'REFUND',
    payment_purpose: 'CONTRACT',
    status: 'APPROVED',
    is_test: false,
  }])
  assert(refund.refunded_amount === 100, 'partial refund amount must be retained')
  assert(refund.reversal_state === 'PARTIALLY_REFUNDED', 'partial refund must not be classified as full')
})

Deno.test('PF-100: test refunds never alter reversal state', () => {
  const refund = summarizeRefunds(500, [{
    contract_amount_settled: 500,
    transaction_type: 'REFUND',
    payment_purpose: 'CONTRACT',
    status: 'APPROVED',
    is_test: true,
  }])
  assert(refund.refunded_amount === 0 && refund.reversal_state === 'NONE', 'test refunds must be excluded')
})
