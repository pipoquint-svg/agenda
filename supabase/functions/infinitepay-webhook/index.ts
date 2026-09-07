import { adminClient } from '../_shared/supabase.ts'
import { parseInfinitePayWebhookSignal } from '../_shared/infinitepay.ts'

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

// Auth-contract note: the public webhook is only a durable wake-up signal. The
// internal infinitepay-reconcile boundary performs checkInfinitePayPayment and
// verifyInfinitePayPayment before any financial mutation.
async function reconcileNow(rawSignal: unknown): Promise<boolean> {
  const base = requiredEnv('SUPABASE_URL').replace(/\/$/, '')
  const secret = requiredEnv('INTEGRATION_INTERNAL_SECRET')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12_000)
  try {
    const response = await fetch(`${base}/functions/v1/infinitepay-reconcile`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': secret,
      },
      body: JSON.stringify({ signal: rawSignal }),
      signal: controller.signal,
    })
    return response.ok
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

async function reconcilePersistedSignal(
  client: ReturnType<typeof adminClient>,
  rawSignal: unknown,
  idempotencyKey: string,
): Promise<void> {
  const reconciled = await reconcileNow(rawSignal)
  if (!reconciled) return

  await client.from('integration_jobs')
    .update({
      status: 'SUCCEEDED',
      last_error: null,
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('idempotency_key', idempotencyKey)
    .eq('status', 'PENDING')
    .eq('attempt_count', 0)
}

function runInBackground(task: Promise<void>): void {
  const runtime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void }
  }).EdgeRuntime

  if (runtime?.waitUntil) {
    runtime.waitUntil(task)
    return
  }

  // Outside Supabase Edge Runtime the durable queue remains authoritative and
  // the scheduled worker will retry the persisted job.
  task.catch(() => undefined)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const body = await req.json()
    const signal = parseInfinitePayWebhookSignal(body)
    if (!isUuid(signal.orderNsu)) throw new Error('INFINITEPAY_ORDER_NSU_INVALID')

    const client = adminClient()
    // InfinitePay does not publish a webhook-signature contract. Before we persist a
    // public wake-up signal, require its order_nsu to be one of our own InfinitePay
    // charge transactions. payment_check remains the authoritative payment proof.
    const { data: transaction, error: transactionError } = await client
      .from('payment_transactions')
      .select('id')
      .eq('id', signal.orderNsu)
      .eq('provider', 'INFINITEPAY')
      .eq('transaction_type', 'CHARGE')
      .maybeSingle()
    if (transactionError) throw new Error('INFINITEPAY_WEBHOOK_PAYMENT_LOOKUP_FAILED')
    if (!transaction) return json({ error: { code: 'INFINITEPAY_WEBHOOK_UNKNOWN_ORDER' } }, 400)

    const idempotencyKey = `infinitepay-webhook:${signal.orderNsu}:${signal.transactionNsu}:${signal.slug}`
    const { error: persistError } = await client.from('integration_jobs').upsert({
      job_type: 'INFINITEPAY_WEBHOOK_VERIFY',
      entity_type: 'PAYMENT_TRANSACTION',
      entity_id: signal.orderNsu,
      entity_version: null,
      payload_json: {
        signal: body,
        received_at: new Date().toISOString(),
      },
      status: 'PENDING',
      attempt_count: 0,
      run_after: new Date().toISOString(),
      idempotency_key: idempotencyKey,
      max_attempts: 8,
    }, { onConflict: 'idempotency_key', ignoreDuplicates: true })

    if (persistError) {
      console.error('[OPERATION_ALERT] INFINITEPAY_WEBHOOK_PERSIST_FAILED', {
        order_nsu: signal.orderNsu,
        code: persistError.code ?? 'UNKNOWN',
      })
      // InfinitePay documents that HTTP 400 is retried, so fail closed when the
      // durable handoff itself did not succeed.
      return json({ error: { code: 'INFINITEPAY_WEBHOOK_PERSIST_FAILED' } }, 400)
    }

    // Acknowledge the provider immediately after durable persistence. Financial
    // verification runs in the Edge background; if it fails, the five-minute
    // scheduled worker retries the same durable job.
    runInBackground(reconcilePersistedSignal(client, body, idempotencyKey))
    return json({ ok: true, persisted: true, reconciliation: 'background' })
  } catch (cause) {
    const code = cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_WEBHOOK_INVALID'
    return json({ error: { code } }, 400)
  }
})
