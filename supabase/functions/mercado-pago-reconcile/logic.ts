import {
  assertMercadoPagoPaymentMatchesIntent,
  mercadoPagoPaymentStorageSnapshot,
  normalizeMercadoPagoPaymentStatus,
  sanitizeMercadoPagoPayment,
} from '../_shared/mercado-pago.ts'

export type ReconcileCandidate = {
  id: string
  appointment_id: string
  cash_amount: number | string
  method: 'PIX' | 'CARD'
  provider_payment_id: string
  updated_at: string
}

type QuarantineInput = {
  transactionId: string
  providerPaymentId: string
  reason: string
  payload: Record<string, unknown>
}

type ApplyInput = {
  transactionId: string
  providerPaymentId: string
  normalizedStatus: 'PENDING' | 'APPROVED' | 'REJECTED' | 'EXPIRED'
  eventKey: string
  payload: Record<string, unknown>
  paidAt: string | null
}

export type ReconcileDependencies = {
  getOrder(orderId: string): Promise<Record<string, unknown>>
  quarantine(input: QuarantineInput): Promise<void>
  apply(input: ApplyInput): Promise<unknown>
}

export function safeReconcileCode(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'MERCADO_PAGO_RECONCILE_FAILED'
  return raw.split(':')[0].replace(/[^A-Z0-9_]/gi, '_').slice(0, 120)
}

export function reconcileRetryDelaySeconds(attempt: number): number | null {
  return [30, 120, 600, 1800][attempt - 1] ?? null
}

export async function reconcileMercadoPagoCandidate(
  candidate: ReconcileCandidate,
  deps: ReconcileDependencies,
): Promise<{
  normalized_status: 'PENDING' | 'APPROVED' | 'REJECTED' | 'EXPIRED'
  transaction_status: string
  changed: boolean
  event_key: string
}> {
  const order = await deps.getOrder(candidate.provider_payment_id)
  const snapshot = sanitizeMercadoPagoPayment(order)
  const storedSnapshot = mercadoPagoPaymentStorageSnapshot(snapshot)

  try {
    if (snapshot.id !== candidate.provider_payment_id) throw new Error('MERCADO_PAGO_PAYMENT_ID_MISMATCH')
    assertMercadoPagoPaymentMatchesIntent(snapshot, {
      transactionId: candidate.id,
      cashAmount: candidate.cash_amount,
      method: candidate.method,
    })
  } catch (validationError) {
    const reason = safeReconcileCode(validationError)
    await deps.quarantine({
      transactionId: candidate.id,
      providerPaymentId: snapshot.id || candidate.provider_payment_id,
      reason,
      payload: storedSnapshot,
    })
    throw new Error('MERCADO_PAGO_PAYMENT_VALIDATION_FAILED')
  }

  const normalized = normalizeMercadoPagoPaymentStatus(snapshot.raw_status ?? snapshot.status)
  const eventKey = `reconcile:${snapshot.id}:${snapshot.raw_status ?? snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`
  const applied = await deps.apply({
    transactionId: candidate.id,
    providerPaymentId: snapshot.id,
    normalizedStatus: normalized,
    eventKey,
    payload: storedSnapshot,
    paidAt: snapshot.date_approved,
  })
  const state = applied && typeof applied === 'object' ? applied as Record<string, unknown> : {}
  const transactionStatus = String(state.transaction_status ?? normalized)
  return {
    normalized_status: normalized,
    transaction_status: transactionStatus,
    changed: transactionStatus !== 'PENDING',
    event_key: eventKey,
  }
}
