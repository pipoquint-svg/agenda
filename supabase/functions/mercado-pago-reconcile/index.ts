import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  assertMercadoPagoPaymentMatchesIntent,
  mercadoPagoPaymentStorageSnapshot,
  normalizeMercadoPagoPaymentStatus,
  sanitizeMercadoPagoPayment,
} from '../_shared/mercado-pago.ts'

const RECONCILE_LIMIT = 20
const RECONCILE_MIN_AGE_MS = 2 * 60 * 1000
const PROVIDER_TIMEOUT_MS = 15_000

type Candidate = {
  id: string
  appointment_id: string
  cash_amount: number | string
  method: 'PIX' | 'CARD'
  provider_payment_id: string
  updated_at: string
}

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
  const supplied = req.headers.get('x-internal-secret')?.trim() ?? ''
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function providerRuntime() {
  return mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    creatingCharge: false,
  })
}

async function getOrder(orderId: string): Promise<Record<string, unknown>> {
  const runtime = providerRuntime()
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS)
  try {
    const response = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(orderId)}`, {
      method: 'GET',
      headers: {
        authorization: `Bearer ${runtime.accessToken}`,
        accept: 'application/json',
      },
      signal: controller.signal,
    })
    const data = await response.json().catch(() => ({})) as Record<string, unknown>
    if (!response.ok) throw new Error(`MERCADO_PAGO_LOOKUP_FAILED:${response.status}`)
    return data
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('MERCADO_PAGO_PROVIDER_TIMEOUT')
    throw error
  } finally {
    clearTimeout(timer)
  }
}

function safeCode(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'MERCADO_PAGO_RECONCILE_FAILED'
  return raw.split(':')[0].replace(/[^A-Z0-9_]/gi, '_').slice(0, 120)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const client = adminClient()
    const staleBefore = new Date(Date.now() - RECONCILE_MIN_AGE_MS).toISOString()
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,appointment_id,cash_amount,method,provider_payment_id,updated_at')
      .eq('provider', 'MERCADO_PAGO')
      .eq('transaction_type', 'CHARGE')
      .eq('status', 'PENDING')
      .not('provider_payment_id', 'is', null)
      .lte('updated_at', staleBefore)
      .order('updated_at', { ascending: true })
      .limit(RECONCILE_LIMIT)
    if (error) throw new Error('MERCADO_PAGO_RECONCILE_CANDIDATE_LOOKUP_FAILED')

    const candidates = (data ?? []) as Candidate[]
    let succeeded = 0
    let changed = 0
    const failures: Array<{ transaction_id: string; code: string }> = []

    for (const candidate of candidates) {
      try {
        const order = await getOrder(candidate.provider_payment_id)
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
          const reason = safeCode(validationError)
          const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
            p_transaction_id: candidate.id,
            p_provider_payment_id: snapshot.id || candidate.provider_payment_id,
            p_reason: reason,
            p_payload_json: storedSnapshot,
          })
          if (quarantineError) throw new Error('PAYMENT_MISMATCH_QUARANTINE_FAILED')
          throw new Error('MERCADO_PAGO_PAYMENT_VALIDATION_FAILED')
        }

        const normalized = normalizeMercadoPagoPaymentStatus(snapshot.raw_status ?? snapshot.status)
        const { data: applied, error: applyError } = await client.rpc('apply_provider_payment_status', {
          p_transaction_id: candidate.id,
          p_provider_payment_id: snapshot.id,
          p_normalized_status: normalized,
          p_event_key: `reconcile:${snapshot.id}:${snapshot.raw_status ?? snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`,
          p_payload_json: storedSnapshot,
          p_paid_at: snapshot.date_approved,
        })
        if (applyError) throw new Error('PAYMENT_STATUS_APPLY_FAILED')
        const state = applied && typeof applied === 'object' ? applied as Record<string, unknown> : {}
        if (String(state.status ?? 'PENDING') !== 'PENDING') changed += 1
        succeeded += 1
      } catch (error) {
        const code = safeCode(error)
        failures.push({ transaction_id: candidate.id, code })
        console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_FAILED', {
          transaction_id: candidate.id,
          provider_order_id: candidate.provider_payment_id,
          code,
        })
      }
    }

    const body = {
      ok: failures.length === 0,
      scanned: candidates.length,
      succeeded,
      changed,
      failed: failures.length,
      failures,
    }
    if (failures.length > 0) return jsonResponse(body, 502)
    return jsonResponse(body)
  } catch (error) {
    const code = safeCode(error)
    console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_ABORTED', { code })
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
