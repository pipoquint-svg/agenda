import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'

const INTERNAL_CALL_TIMEOUT_MS = 15_000

function requireInternal(req: Request): string {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
  return expected
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}

function retryDelaySeconds(attempt: number): number | null {
  const schedule = [30, 120, 600, 1800]
  return schedule[attempt - 1] ?? null
}

async function invokeFunction<T = Record<string, unknown>>(name: string, secret: string, body: unknown): Promise<T> {
  const base = Deno.env.get('SUPABASE_URL')
  if (!base) throw new Error('MISSING_ENV:SUPABASE_URL')

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), INTERNAL_CALL_TIMEOUT_MS)
  let response: Response
  try {
    response = await fetch(`${base}/functions/v1/${name}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': secret,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_TIMEOUT`)
    }
    throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_NETWORK_ERROR`)
  } finally {
    clearTimeout(timeout)
  }

  const text = await response.text()
  if (!response.ok) {
    throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_HTTP_${response.status}`)
  }
  if (!text) return {} as T
  try {
    return JSON.parse(text) as T
  } catch {
    throw new Error(`${name.toUpperCase().replaceAll('-', '_')}_INVALID_RESPONSE`)
  }
}

async function discardStaleJob(
  client: ReturnType<typeof adminClient>,
  job: any,
  workerId: string,
  currentVersion: number | undefined,
  missingVersionCode: string,
): Promise<void> {
  if (!Number.isInteger(currentVersion)) throw new Error(missingVersionCode)
  const { error: discardError } = await client.rpc('discard_integration_job_stale', {
    p_job_id: job.id,
    p_worker_id: workerId,
    p_current_version: currentVersion,
  })
  if (discardError) throw new Error('INTEGRATION_JOB_STALE_DISCARD_FAILED')
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    const secret = requireInternal(req)
    const client = adminClient()
    const workerId = `edge:${crypto.randomUUID()}`
    const transactionalEmailWorkerEnabled = envEnabled('TRANSACTIONAL_EMAIL_WORKER_ENABLED')
    const googleIntegrationEnabled = envEnabled('GOOGLE_INTEGRATION_ENABLED')

    const { data: kommoSettings, error: kommoSettingsError } = await client
      .from('kommo_integration_settings')
      .select('enabled')
      .eq('id', 1)
      .maybeSingle()
    if (kommoSettingsError) throw new Error('KOMMO_SETTINGS_LOOKUP_FAILED')
    const kommoIntegrationEnabled = kommoSettings?.enabled === true

    await client.rpc('release_stale_integration_jobs', { p_stale_after_seconds: 300 })

    const { error: holdExpiryError } = await client.rpc('expire_due_checkout_holds')
    if (holdExpiryError) throw new Error('CHECKOUT_HOLD_EXPIRY_FAILED')

    const { error: appointmentHoldExpiryError } = await client.rpc('expire_due_appointment_holds')
    if (appointmentHoldExpiryError) throw new Error('APPOINTMENT_HOLD_EXPIRY_FAILED')

    const { data: expiredFreeVisits, error: freeVisitExpiryError } = await client.rpc('expire_unconfirmed_free_visits')
    if (freeVisitExpiryError) throw new Error('FREE_VISIT_CONFIRMATION_EXPIRY_FAILED')

    let calendarIds: string[] = []
    if (googleIntegrationEnabled) {
      const { data: mappings, error: mappingsError } = await client
        .from('google_calendar_resources')
        .select('google_calendar_id')
      if (mappingsError) throw new Error('GOOGLE_CALENDAR_MAPPING_LOOKUP_FAILED')
      calendarIds = [...new Set((mappings ?? []).map((row: any) => String(row.google_calendar_id)).filter(Boolean))]
      const minuteBucket = Math.floor(Date.now() / 60000)

      for (const calendarId of calendarIds) {
        const { error: enqueueError } = await client.rpc('enqueue_google_calendar_sync', {
          p_google_calendar_id: calendarId,
          p_idempotency_key: `google-reconcile:${calendarId}:${minuteBucket}`,
          p_payload_json: { source: 'PERIODIC_RECONCILIATION', minute_bucket: minuteBucket },
        })
        if (enqueueError) throw new Error('GOOGLE_RECONCILIATION_ENQUEUE_FAILED')
      }

      if (calendarIds.length > 0) {
        const { data: watches, error: watchesError } = await client
          .from('google_watch_channels')
          .select('google_calendar_id, expiration_at, status')
          .in('google_calendar_id', calendarIds)
          .eq('status', 'ACTIVE')
        if (watchesError) throw new Error('GOOGLE_WATCH_LOOKUP_FAILED')

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
            console.error('GOOGLE_WATCH_RENEWAL_FAILED', error instanceof Error ? error.message : 'UNKNOWN')
          }
        }
      }
    }

    const claimJobTypes: string[] = []
    if (googleIntegrationEnabled) claimJobTypes.push('GOOGLE_CALENDAR_SYNC', 'GOOGLE_APPOINTMENT_SYNC')
    if (kommoIntegrationEnabled) claimJobTypes.push('KOMMO_APPOINTMENT_SYNC')
    if (transactionalEmailWorkerEnabled) claimJobTypes.push('APPOINTMENT_CONFIRMED_MESSAGE')

    let jobs: any[] = []
    if (claimJobTypes.length > 0) {
      const { data: claimedJobs, error: claimError } = await client.rpc('claim_integration_jobs', {
        p_worker_id: workerId,
        p_job_types: claimJobTypes,
        p_limit: 10,
      })
      if (claimError) throw new Error('INTEGRATION_JOB_CLAIM_FAILED')
      jobs = claimedJobs ?? []
    }

    let succeeded = 0
    let retried = 0
    let failed = 0
    let discardedStale = 0

    for (const job of jobs) {
      try {
        if (job.job_type === 'GOOGLE_CALENDAR_SYNC') {
          if (!googleIntegrationEnabled) throw new Error('GOOGLE_INTEGRATION_DISABLED')
          const forceFull = job.payload_json?.force_full === true
          await invokeFunction('google-sync', secret, { google_calendar_id: job.entity_id, force_full: forceFull })
        } else if (job.job_type === 'GOOGLE_APPOINTMENT_SYNC') {
          if (!googleIntegrationEnabled) throw new Error('GOOGLE_INTEGRATION_DISABLED')
          if (!Number.isInteger(job.entity_version) || job.entity_version < 1) throw new Error('GOOGLE_APPOINTMENT_SYNC_VERSION_REQUIRED')
          const result = await invokeFunction<{ stale?: boolean; current_version?: number }>('google-appointment-sync', secret, { appointment_id: job.entity_id, entity_version: job.entity_version })
          if (result.stale) {
            await discardStaleJob(client, job, workerId, result.current_version, 'GOOGLE_APPOINTMENT_SYNC_STALE_VERSION_MISSING')
            discardedStale += 1
            continue
          }
        } else if (job.job_type === 'APPOINTMENT_CONFIRMED_MESSAGE') {
          if (!transactionalEmailWorkerEnabled) throw new Error('TRANSACTIONAL_EMAIL_WORKER_DISABLED')
          if (!Number.isInteger(job.entity_version) || job.entity_version < 1) throw new Error('APPOINTMENT_CONFIRMED_MESSAGE_VERSION_REQUIRED')
          const reason = typeof job.payload_json?.reason === 'string' ? job.payload_json.reason : 'CONFIRMED'
          const result = await invokeFunction<{ stale?: boolean; current_version?: number }>('email-send', secret, { appointment_id: job.entity_id, entity_version: job.entity_version, reason })
          if (result.stale) {
            await discardStaleJob(client, job, workerId, result.current_version, 'APPOINTMENT_CONFIRMED_MESSAGE_STALE_VERSION_MISSING')
            discardedStale += 1
            continue
          }
        } else if (job.job_type === 'KOMMO_APPOINTMENT_SYNC') {
          if (!kommoIntegrationEnabled) throw new Error('KOMMO_INTEGRATION_DISABLED')
          if (!Number.isInteger(job.entity_version) || job.entity_version < 1) throw new Error('KOMMO_APPOINTMENT_SYNC_VERSION_REQUIRED')
          const eventKind = typeof job.payload_json?.event_kind === 'string' ? job.payload_json.event_kind : 'UPDATED'
          const result = await invokeFunction<{ stale?: boolean; current_version?: number }>('kommo-sync', secret, { appointment_id: job.entity_id, entity_version: job.entity_version, event_kind: eventKind })
          if (result.stale) {
            await discardStaleJob(client, job, workerId, result.current_version, 'KOMMO_APPOINTMENT_SYNC_STALE_VERSION_MISSING')
            discardedStale += 1
            continue
          }
        } else {
          throw new Error('UNSUPPORTED_JOB_TYPE')
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
          p_error: message.slice(0, 160),
          p_retry_after_seconds: retryAfter,
        })
        if (retryAfter === null || job.attempt_count >= job.max_attempts) failed += 1
        else retried += 1
      }
    }

    return jsonResponse({
      worker_id: workerId,
      google_enabled: googleIntegrationEnabled,
      kommo_enabled: kommoIntegrationEnabled,
      email_worker_enabled: transactionalEmailWorkerEnabled,
      expired_unconfirmed_free_visits: Number(expiredFreeVisits ?? 0),
      calendars_reconciled: calendarIds.length,
      claimed: jobs.length,
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
