import { adminClient } from '../_shared/supabase.ts'
import { sha256Hex } from '../_shared/google.ts'

const IMMEDIATE_SYNC_TIMEOUT_MS = 20_000

type AdminClient = ReturnType<typeof adminClient>

type ClaimedJob = {
  id?: string
}

function googleIntegrationEnabled(): boolean {
  return (Deno.env.get('GOOGLE_INTEGRATION_ENABLED') ?? '').trim().toLowerCase() === 'true'
}

function runInBackground(task: Promise<void>): void {
  const runtime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil?: (promise: Promise<unknown>) => void }
  }).EdgeRuntime

  if (typeof runtime?.waitUntil === 'function') {
    runtime.waitUntil(task)
    return
  }

  // Local/test runtimes do not expose EdgeRuntime. The task catches its own errors,
  // so letting it continue without blocking the webhook response is safe here too.
  void task
}

function claimedJobId(value: unknown): string | null {
  const row = Array.isArray(value) ? value[0] : value
  if (!row || typeof row !== 'object') return null
  const id = (row as ClaimedJob).id
  return typeof id === 'string' && id ? id : null
}

async function finishImmediateJob(
  client: AdminClient,
  jobId: string,
  workerId: string,
  succeeded: boolean,
): Promise<void> {
  const { error } = await client.rpc('finish_integration_job', {
    p_job_id: jobId,
    p_worker_id: workerId,
    p_succeeded: succeeded,
    p_error: succeeded ? null : 'GOOGLE_PUSH_IMMEDIATE_SYNC_FAILED',
    p_retry_after_seconds: succeeded ? null : 30,
  })
  if (error) throw new Error('GOOGLE_PUSH_JOB_FINISH_FAILED')
}

async function processCalendarPushImmediately(client: AdminClient, googleCalendarId: string): Promise<void> {
  const workerId = `google-webhook:${crypto.randomUUID()}`
  let jobId: string | null = null

  try {
    const { data: claimed, error: claimError } = await client.rpc('claim_google_calendar_sync_job', {
      p_google_calendar_id: googleCalendarId,
      p_worker_id: workerId,
    })
    if (claimError) throw new Error('GOOGLE_PUSH_JOB_CLAIM_FAILED')

    jobId = claimedJobId(claimed)
    if (!jobId) return

    const base = Deno.env.get('SUPABASE_URL')?.replace(/\/$/, '')
    const internalSecret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
    if (!base || !internalSecret) throw new Error('GOOGLE_PUSH_IMMEDIATE_SYNC_NOT_CONFIGURED')

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), IMMEDIATE_SYNC_TIMEOUT_MS)
    try {
      const response = await fetch(`${base}/functions/v1/google-sync`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-internal-secret': internalSecret,
        },
        body: JSON.stringify({ google_calendar_id: googleCalendarId }),
        signal: controller.signal,
      })
      await response.body?.cancel().catch(() => undefined)
      if (!response.ok) throw new Error(`GOOGLE_PUSH_IMMEDIATE_SYNC_HTTP_${response.status}`)
    } finally {
      clearTimeout(timeout)
    }

    await finishImmediateJob(client, jobId, workerId, true)
  } catch (error) {
    if (jobId) {
      try {
        await finishImmediateJob(client, jobId, workerId, false)
      } catch {
        // The periodic worker releases stale PROCESSING jobs after five minutes.
      }
    }

    const code = error instanceof Error ? error.message.split(':')[0] : 'GOOGLE_PUSH_IMMEDIATE_SYNC_FAILED'
    console.error('Google push immediate sync deferred to queue', { code })
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response(null, { status: 405 })

  // A watch can be provisioned before the worker is globally enabled as part of the
  // staged activation gate. Acknowledge Google pushes during that interval without
  // creating jobs that the worker is intentionally forbidden to claim.
  if (!googleIntegrationEnabled()) return new Response(null, { status: 204 })

  const channelId = req.headers.get('x-goog-channel-id')
  const resourceId = req.headers.get('x-goog-resource-id')
  const token = req.headers.get('x-goog-channel-token')
  const messageNumber = req.headers.get('x-goog-message-number') ?? 'unknown'
  const resourceState = req.headers.get('x-goog-resource-state') ?? 'unknown'

  if (!channelId || !resourceId || !token) return new Response(null, { status: 204 })

  try {
    const client = adminClient()
    const { data: channel } = await client
      .from('google_watch_channels')
      .select('id, google_calendar_id, channel_token_hash, status, expiration_at')
      .eq('channel_id', channelId)
      .eq('google_resource_id', resourceId)
      .eq('status', 'ACTIVE')
      .maybeSingle()

    if (!channel?.channel_token_hash) return new Response(null, { status: 204 })
    if (channel.expiration_at && new Date(channel.expiration_at).getTime() <= Date.now()) return new Response(null, { status: 204 })

    const suppliedHash = await sha256Hex(token)
    if (suppliedHash !== channel.channel_token_hash) return new Response(null, { status: 204 })

    const key = `google-calendar-sync:${channel.google_calendar_id}:${channelId}:${messageNumber}`
    const { error: enqueueError } = await client.rpc('enqueue_google_calendar_sync', {
      p_google_calendar_id: channel.google_calendar_id,
      p_idempotency_key: key,
      p_payload_json: {
        source: 'GOOGLE_PUSH',
        channel_id: channelId,
        message_number: messageNumber,
        resource_state: resourceState,
      },
    })
    if (enqueueError) throw new Error('GOOGLE_PUSH_ENQUEUE_FAILED')

    // Google only needs a quick 204 acknowledgment. The validated push gets an
    // immediate, serialized sync attempt in the Edge background lifetime; the durable
    // queue remains intact and retries after 30s / via periodic reconciliation on failure.
    runInBackground(processCalendarPushImmediately(client, String(channel.google_calendar_id)))

    return new Response(null, { status: 204 })
  } catch {
    // Google retries non-2xx responses. The periodic reconciliation path remains the safety net,
    // so malformed/spoofed notifications are acknowledged without exposing internal state.
    return new Response(null, { status: 204 })
  }
})
