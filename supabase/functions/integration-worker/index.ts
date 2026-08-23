import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'

function requireInternal(req: Request): string {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
  return expected
}

function retryDelaySeconds(attempt: number): number | null {
  const schedule = [30, 120, 600, 1800]
  return schedule[attempt - 1] ?? null
}

async function invokeFunction<T = Record<string, unknown>>(name: string, secret: string, body: unknown): Promise<T> {
  const base = Deno.env.get('SUPABASE_URL')
  if (!base) throw new Error('MISSING_ENV:SUPABASE_URL')
  const response = await fetch(`${base}/functions/v1/${name}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': secret,
    },
    body: JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`${name.toUpperCase()}_FAILED:${text.slice(0, 1000)}`)
  if (!text) return {} as T
  return JSON.parse(text) as T
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    const secret = requireInternal(req)
    const client = adminClient()
    const workerId = `edge:${crypto.randomUUID()}`

    await client.rpc('release_stale_integration_jobs', { p_stale_after_seconds: 300 })

    const { error: holdExpiryError } = await client.rpc('expire_due_checkout_holds')
    if (holdExpiryError) throw new Error(`CHECKOUT_HOLD_EXPIRY_FAILED:${holdExpiryError.message}`)

    // Periodic reconciliation is the safety net if Google push delivery is delayed/dropped.
    const { data: mappings } = await client.from('google_calendar_resources').select('google_calendar_id')
    const calendarIds = [...new Set((mappings ?? []).map((row: any) => row.google_calendar_id))]
    const minuteBucket = Math.floor(Date.now() / 60000)

    for (const calendarId of calendarIds) {
      await client.rpc('enqueue_google_calendar_sync', {
        p_google_calendar_id: calendarId,
        p_idempotency_key: `google-reconcile:${calendarId}:${minuteBucket}`,
        p_payload_json: { source: 'PERIODIC_RECONCILIATION', minute_bucket: minuteBucket },
      })
    }

    // Keep watch channels renewed at least 24h before expiration.
    if (calendarIds.length > 0) {
      const { data: watches } = await client
        .from('google_watch_channels')
        .select('google_calendar_id, expiration_at, status')
        .in('google_calendar_id', calendarIds)
        .eq('status', 'ACTIVE')

      const safeWatch = new Set<string>()
      const threshold = Date.now() + 24 * 60 * 60 * 1000
      for (const watch of watches ?? []) {
        if (watch.expiration_at && new Date(watch.expiration_at).getTime() > threshold) safeWatch.add(watch.google_calendar_id)
      }

      for (const calendarId of calendarIds) {
        if (safeWatch.has(calendarId)) continue
        try {
          await invokeFunction('google-watch', secret, { google_calendar_id: calendarId })
        } catch (error) {
          console.error('GOOGLE_WATCH_RENEWAL_FAILED', calendarId, error instanceof Error ? error.message : error)
        }
      }
    }

    // Kommo is intentionally not claimed yet. Its provider adapter remains disabled
    // until the private integration/account spike is completed. Direct WhatsApp jobs
    // are no longer part of the V1 worker contract.
    const { data: jobs, error: claimError } = await client.rpc('claim_integration_jobs', {
      p_worker_id: workerId,
      p_job_types: [
        'GOOGLE_CALENDAR_SYNC',
        'GOOGLE_APPOINTMENT_SYNC',
      ],
      p_limit: 10,
    })
    if (claimError) throw new Error(`INTEGRATION_JOB_CLAIM_FAILED:${claimError.message}`)

    let succeeded = 0
    let retried = 0
    let failed = 0
    let discardedStale = 0

    for (const job of jobs ?? []) {
      try {
        if (job.job_type === 'GOOGLE_CALENDAR_SYNC') {
          await invokeFunction('google-sync', secret, { google_calendar_id: job.entity_id, force_full: false })
        } else if (job.job_type === 'GOOGLE_APPOINTMENT_SYNC') {
          if (!Number.isInteger(job.entity_version) || job.entity_version < 1) {
            throw new Error('GOOGLE_APPOINTMENT_SYNC_VERSION_REQUIRED')
          }
          const result = await invokeFunction<{ stale?: boolean; current_version?: number }>(
            'google-appointment-sync',
            secret,
            { appointment_id: job.entity_id, entity_version: job.entity_version },
          )
          if (result.stale) {
            if (!Number.isInteger(result.current_version)) throw new Error('GOOGLE_APPOINTMENT_SYNC_STALE_VERSION_MISSING')
            const { error: discardError } = await client.rpc('discard_integration_job_stale', {
              p_job_id: job.id,
              p_worker_id: workerId,
              p_current_version: result.current_version,
            })
            if (discardError) throw new Error(`INTEGRATION_JOB_STALE_DISCARD_FAILED:${discardError.message}`)
            discardedStale += 1
            continue
          }
        } else {
          throw new Error(`UNSUPPORTED_JOB_TYPE:${job.job_type}`)
        }

        await client.rpc('finish_integration_job', {
          p_job_id: job.id,
          p_worker_id: workerId,
          p_succeeded: true,
          p_error: null,
          p_retry_after_seconds: null,
        })
        succeeded += 1
      } catch (error) {
        const message = error instanceof Error ? error.message : 'INTEGRATION_JOB_FAILED'
        const retryAfter = retryDelaySeconds(job.attempt_count)
        await client.rpc('finish_integration_job', {
          p_job_id: job.id,
          p_worker_id: workerId,
          p_succeeded: false,
          p_error: message,
          p_retry_after_seconds: retryAfter,
        })
        if (retryAfter === null || job.attempt_count >= job.max_attempts) failed += 1
        else retried += 1
      }
    }

    return jsonResponse({
      worker_id: workerId,
      calendars_reconciled: calendarIds.length,
      claimed: (jobs ?? []).length,
      succeeded,
      discarded_stale: discardedStale,
      retried,
      failed,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'INTEGRATION_JOB_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
