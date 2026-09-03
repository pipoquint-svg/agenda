import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  reconcileMercadoPagoCandidate,
  reconcileRetryDelaySeconds,
  safeReconcileCode,
  type ReconcileCandidate,
} from './logic.ts'

const RECONCILE_JOB_TYPE = 'MERCADO_PAGO_RECONCILE'
const RECONCILE_ENTITY_TYPE = 'PAYMENT_TRANSACTION'
const RECONCILE_LIMIT = 10
const RECONCILE_DISCOVERY_LIMIT = 50
const RECONCILE_CONCURRENCY = 5
const RECONCILE_MIN_AGE_MS = 2 * 60 * 1000
const RECONCILE_BUCKET_MS = 5 * 60 * 1000
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

async function finishJob(
  client: ReturnType<typeof adminClient>,
  jobId: string,
  workerId: string,
  succeeded: boolean,
  error: string | null,
  retryAfterSeconds: number | null,
): Promise<void> {
  const { error: finishError } = await client.rpc('finish_integration_job', {
    p_job_id: jobId,
    p_worker_id: workerId,
    p_succeeded: succeeded,
    p_error: error,
    p_retry_after_seconds: retryAfterSeconds,
  })
  if (finishError) throw new Error('MERCADO_PAGO_RECONCILE_JOB_FINISH_FAILED')
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const client = adminClient()
    const workerId = `mercado-pago:${crypto.randomUUID()}`
    const staleBefore = new Date(Date.now() - RECONCILE_MIN_AGE_MS).toISOString()

    const { data: rawCandidates, error: candidateError } = await client
      .from('payment_transactions')
      .select('id,appointment_id,cash_amount,method,provider_payment_id,updated_at')
      .eq('provider', 'MERCADO_PAGO')
      .eq('transaction_type', 'CHARGE')
      .eq('status', 'PENDING')
      .not('provider_payment_id', 'is', null)
      .lte('updated_at', staleBefore)
      .order('updated_at', { ascending: true })
      .limit(RECONCILE_DISCOVERY_LIMIT)
    if (candidateError) throw new Error('MERCADO_PAGO_RECONCILE_CANDIDATE_LOOKUP_FAILED')

    const candidates = (rawCandidates ?? []) as ReconcileCandidate[]
    const candidateIds = candidates.map((candidate) => candidate.id)
    const quarantined = new Set<string>()
    const activeJobs = new Set<string>()

    if (candidateIds.length > 0) {
      const { data: incidents, error: incidentError } = await client
        .from('payment_incidents')
        .select('payment_transaction_id')
        .eq('incident_type', 'PROVIDER_INTENT_MISMATCH')
        .eq('status', 'OPEN')
        .in('payment_transaction_id', candidateIds)
      if (incidentError) throw new Error('MERCADO_PAGO_RECONCILE_INCIDENT_LOOKUP_FAILED')
      for (const incident of incidents ?? []) quarantined.add(String(incident.payment_transaction_id))

      const { data: openJobs, error: openJobError } = await client
        .from('integration_jobs')
        .select('entity_id')
        .eq('job_type', RECONCILE_JOB_TYPE)
        .in('status', ['PENDING', 'PROCESSING'])
        .in('entity_id', candidateIds)
      if (openJobError) throw new Error('MERCADO_PAGO_RECONCILE_ACTIVE_JOB_LOOKUP_FAILED')
      for (const job of openJobs ?? []) activeJobs.add(String(job.entity_id))
    }

    const enqueueCandidates = candidates
      .filter((candidate) => !quarantined.has(candidate.id) && !activeJobs.has(candidate.id))
      .slice(0, RECONCILE_LIMIT)
    let enqueued = 0
    if (enqueueCandidates.length > 0) {
      const bucket = Math.floor(Date.now() / RECONCILE_BUCKET_MS)
      const rows = enqueueCandidates.map((candidate) => ({
        job_type: RECONCILE_JOB_TYPE,
        entity_type: RECONCILE_ENTITY_TYPE,
        entity_id: candidate.id,
        entity_version: null,
        payload_json: { provider_order_id: candidate.provider_payment_id },
        status: 'PENDING',
        run_after: new Date().toISOString(),
        max_attempts: 5,
        idempotency_key: `mercado-pago-reconcile:${candidate.id}:${bucket}`,
      }))
      const { data: inserted, error: enqueueError } = await client
        .from('integration_jobs')
        .upsert(rows, { onConflict: 'idempotency_key', ignoreDuplicates: true })
        .select('id')
      if (enqueueError) throw new Error('MERCADO_PAGO_RECONCILE_ENQUEUE_FAILED')
      enqueued = (inserted ?? []).length
    }

    const { data: claimed, error: claimError } = await client.rpc('claim_integration_jobs', {
      p_worker_id: workerId,
      p_job_types: [RECONCILE_JOB_TYPE],
      p_limit: RECONCILE_LIMIT,
    })
    if (claimError) throw new Error('MERCADO_PAGO_RECONCILE_JOB_CLAIM_FAILED')

    const jobs = claimed ?? []
    const claimedIds = [...new Set(jobs.map((job: any) => String(job.entity_id)))]
    const candidateById = new Map<string, ReconcileCandidate>()
    const claimedQuarantined = new Set<string>()

    if (claimedIds.length > 0) {
      const { data: freshTransactions, error: freshError } = await client
        .from('payment_transactions')
        .select('id,appointment_id,cash_amount,method,provider_payment_id,updated_at,provider,transaction_type,status')
        .in('id', claimedIds)
      if (freshError) throw new Error('MERCADO_PAGO_RECONCILE_TRANSACTION_LOOKUP_FAILED')
      for (const transaction of freshTransactions ?? []) {
        if (
          transaction.provider === 'MERCADO_PAGO'
          && transaction.transaction_type === 'CHARGE'
          && transaction.status === 'PENDING'
          && transaction.provider_payment_id
        ) {
          candidateById.set(String(transaction.id), transaction as ReconcileCandidate)
        }
      }

      const { data: incidents, error: incidentError } = await client
        .from('payment_incidents')
        .select('payment_transaction_id')
        .eq('incident_type', 'PROVIDER_INTENT_MISMATCH')
        .eq('status', 'OPEN')
        .in('payment_transaction_id', claimedIds)
      if (incidentError) throw new Error('MERCADO_PAGO_RECONCILE_CLAIMED_INCIDENT_LOOKUP_FAILED')
      for (const incident of incidents ?? []) claimedQuarantined.add(String(incident.payment_transaction_id))
    }

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

    let succeeded = 0
    let stillPending = 0
    let changed = 0
    let skipped = 0
    let retried = 0
    let failed = 0
    const failures: Array<{ transaction_id: string; code: string }> = []

    for (let offset = 0; offset < jobs.length; offset += RECONCILE_CONCURRENCY) {
      const batch = jobs.slice(offset, offset + RECONCILE_CONCURRENCY)
      await Promise.all(batch.map(async (job: any) => {
        const transactionId = String(job.entity_id)
        const candidate = candidateById.get(transactionId)
        if (!candidate || claimedQuarantined.has(transactionId)) {
          await finishJob(client, String(job.id), workerId, true, null, null)
          skipped += 1
          return
        }

        try {
          const result = await reconcileMercadoPagoCandidate(candidate, deps)
          await finishJob(client, String(job.id), workerId, true, null, null)
          succeeded += 1
          if (result.changed) changed += 1
          else stillPending += 1
        } catch (error) {
          const code = safeReconcileCode(error)
          const nonRetryable = code === 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED'
          const retryAfter = nonRetryable ? null : reconcileRetryDelaySeconds(Number(job.attempt_count))
          await finishJob(client, String(job.id), workerId, false, code, retryAfter)
          if (retryAfter === null || Number(job.attempt_count) >= Number(job.max_attempts)) failed += 1
          else retried += 1
          failures.push({ transaction_id: transactionId, code })
          console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_FAILED', {
            transaction_id: transactionId,
            provider_order_id: candidate.provider_payment_id,
            attempt: job.attempt_count,
            retry_after_seconds: retryAfter,
            code,
          })
        }
      }))
    }

    const body = {
      ok: retried === 0 && failed === 0,
      candidates: candidates.length,
      quarantined_skipped: quarantined.size,
      active_job_skipped: activeJobs.size,
      enqueued,
      claimed: jobs.length,
      succeeded,
      still_pending: stillPending,
      changed,
      stale_skipped: skipped,
      retried,
      failed,
      failures,
    }
    if (retried > 0 || failed > 0) return jsonResponse(body, 502)
    return jsonResponse(body)
  } catch (error) {
    const code = safeReconcileCode(error)
    console.error('[OPERATION_ALERT] MERCADO_PAGO_RECONCILE_ABORTED', { code })
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
