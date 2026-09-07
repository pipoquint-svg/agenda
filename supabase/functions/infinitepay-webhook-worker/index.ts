import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'

const INTERNAL_CALL_TIMEOUT_MS = 15_000

function requireInternal(req: Request): string {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
  return expected
}

function retryDelaySeconds(attempt: number): number | null {
  const schedule = [15, 30, 60, 120, 300, 600, 900]
  return schedule[attempt - 1] ?? null
}

async function invokeReconcile(secret: string, signal: unknown): Promise<void> {
  const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '')
  if (!base) throw new Error('MISSING_ENV:SUPABASE_URL')

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), INTERNAL_CALL_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/infinitepay-reconcile`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': secret,
      },
      body: JSON.stringify({ signal }),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`INFINITEPAY_RECONCILE_HTTP_${response.status}`)
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('INFINITEPAY_RECONCILE_TIMEOUT')
    throw error
  } finally {
    clearTimeout(timer)
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    const secret = requireInternal(req)
    const client = adminClient()
    const workerId = `infinitepay:${crypto.randomUUID()}`

    const { data: claimedJobs, error: claimError } = await client.rpc('claim_integration_jobs', {
      p_worker_id: workerId,
      p_job_types: ['INFINITEPAY_WEBHOOK_VERIFY'],
      p_limit: 20,
    })
    if (claimError) throw new Error('INFINITEPAY_WEBHOOK_JOB_CLAIM_FAILED')

    const jobs: any[] = claimedJobs ?? []
    let succeeded = 0
    let retried = 0
    let failed = 0

    for (const job of jobs) {
      try {
        const signal = job.payload_json?.signal
        if (!signal) throw new Error('INFINITEPAY_WEBHOOK_SIGNAL_MISSING')
        await invokeReconcile(secret, signal)

        await client.rpc('finish_integration_job', {
          p_job_id: job.id,
          p_worker_id: workerId,
          p_succeeded: true,
          p_error: null,
          p_retry_after_seconds: null,
        })
        succeeded += 1
      } catch (error) {
        const message = error instanceof Error ? error.message : 'INFINITEPAY_WEBHOOK_RETRY_FAILED'
        const retryAfter = retryDelaySeconds(job.attempt_count)
        await client.rpc('finish_integration_job', {
          p_job_id: job.id,
          p_worker_id: workerId,
          p_succeeded: false,
          p_error: message.slice(0, 160),
          p_retry_after_seconds: retryAfter,
        })
        if (retryAfter === null || job.attempt_count >= job.max_attempts) failed += 1
        else retried += 1
      }
    }

    return jsonResponse({
      ok: true,
      worker_id: workerId,
      claimed: jobs.length,
      succeeded,
      retried,
      failed,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'INFINITEPAY_WEBHOOK_WORKER_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
