import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  reconcileMercadoPagoCandidate,
  safeReconcileCode,
  type ReconcileCandidate,
} from './logic.ts'

const RECONCILE_LIMIT = 10
const RECONCILE_CONCURRENCY = 5
const RECONCILE_MIN_AGE_MS = 2 * 60 * 1000
const PROVIDER_TIMEOUT_MS = 15_000

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

    const candidates = (data ?? []) as ReconcileCandidate[]
    let succeeded = 0
    let changed = 0
    const failures: Array<{ transaction_id: string; code: string }> = []

    const deps = {
      getOrder,
      quarantine: async (input: {
        transactionId: string
        providerPaymentId: string
        reason: string
        payload: Record<string, unknown>
      }) => {
        const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
          p_transaction_id: input.transactionId,
          p_provider_payment_id: input.providerPaymentId,
          p_reason: input.reason,
          p_payload_json: input.payload,
        })
        if (quarantineError) throw new Error('PAYMENT_MISMATCH_QUARANTINE_FAILED')
      },
      apply: async (input: {
        transactionId: string
        providerPaymentId: string
        normalizedStatus: 'PENDING' | 'APPROVED' | 'REJECTED' | 'EXPIRED'
        eventKey: string
        payload: Record<string, unknown>
        paidAt: string | null
      }) => {
        const { data: applied, error: applyError } = await client.rpc('apply_provider_payment_status', {
          p_transaction_id: input.transactionId,
          p_provider_payment_id: input.providerPaymentId,
          p_normalized_status: input.normalizedStatus,
          p_event_key: input.eventKey,
          p_payload_json: input.payload,
          p_paid_at: input.paidAt,
        })
        if (applyError) throw new Error('PAYMENT_STATUS_APPLY_FAILED')
        return applied
      },
    }

    for (let offset = 0; offset < candidates.length; offset += RECONCILE_CONCURRENCY) {
      const batch = candidates.slice(offset, offset + RECONCILE_CONCURRENCY)
      const results = await Promise.all(batch.map(async (candidate) => {
        try {
          const result = await reconcileMercadoPagoCandidate(candidate, deps)
          return { candidate, result, error: null as unknown }
        } catch (error) {
          return { candidate, result: null, error }
        }
      }))

      for (const entry of results) {
        if (!entry.error && entry.result) {
          succeeded += 1
          if (entry.result.changed) changed += 1
          continue
        }
        const code = safeReconcileCode(entry.error)
        failures.push({ transaction_id: entry.candidate.id, code })
        console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_FAILED', {
          transaction_id: entry.candidate.id,
          provider_order_id: entry.candidate.provider_payment_id,
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
    const code = safeReconcileCode(error)
    console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_ABORTED', { code })
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
