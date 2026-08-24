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
  const schedule = [30,120,600,1800]
  return schedule[attempt - 1] ?? null
}

async function invokeFunction(name: string, secret: string, body: unknown): Promise<Record<string, unknown>> {
  const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/,'') ?? ''
  if (!base) throw new Error('MISSING_ENV:SUPABASE_URL')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), INTERNAL_CALL_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/${name}`, {
      method:'POST',
      headers:{'content-type':'application/json','x-internal-secret':secret},
      body:JSON.stringify(body),
      signal:controller.signal,
    })
    const text = await response.text()
    if (!response.ok) throw new Error(`${name.toUpperCase().replaceAll('-','_')}_HTTP_${response.status}`)
    return text ? JSON.parse(text) as Record<string, unknown> : {}
  } finally { clearTimeout(timer) }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'),405)
  try {
    const secret = requireInternal(req)
    const client = adminClient()
    const workerId = `balance:${crypto.randomUUID()}`
    const emailEnabled = envEnabled('TRANSACTIONAL_EMAIL_WORKER_ENABLED')

    // Balance delivery through Kommo remains deliberately fail-closed. The durable
    // RENTAL_BALANCE_DUE_KOMMO jobs are retained in the outbox, but this worker must not
    // claim them until a dedicated notifier exists and its provider gate is explicitly enabled.
    const kommoDeliveryEnabled = false

    const { data: created, error: enqueueError } = await client.rpc('enqueue_due_rental_balance_collections')
    if (enqueueError) throw new Error('RENTAL_BALANCE_COLLECTION_ENQUEUE_FAILED')

    await client.rpc('release_stale_integration_jobs',{p_stale_after_seconds:300})

    const jobTypes = ['RENTAL_BALANCE_CANCEL_NO_SHOW','RENTAL_BALANCE_CANCEL_EXPIRED']
    if (emailEnabled) jobTypes.push('RENTAL_BALANCE_DUE_EMAIL')

    const { data: jobs, error: claimError } = await client.rpc('claim_integration_jobs', {
      p_worker_id:workerId,p_job_types:jobTypes,p_limit:20,
    })
    if (claimError) throw new Error('BALANCE_JOB_CLAIM_FAILED')

    let succeeded=0,retried=0,failed=0
    for (const job of jobs ?? []) {
      try {
        if (job.job_type==='RENTAL_BALANCE_DUE_EMAIL') {
          await invokeFunction('balance-collection-notify-email',secret,{collection_id:job.entity_id})
        } else if (job.job_type==='RENTAL_BALANCE_CANCEL_NO_SHOW') {
          await invokeFunction('balance-collection-provider-cancel',secret,{collection_id:job.entity_id,reason:'NO_SHOW'})
        } else if (job.job_type==='RENTAL_BALANCE_CANCEL_EXPIRED') {
          await invokeFunction('balance-collection-provider-cancel',secret,{collection_id:job.entity_id,reason:'EXPIRED'})
        } else {
          throw new Error('UNSUPPORTED_BALANCE_JOB_TYPE')
        }

        await client.rpc('finish_integration_job',{
          p_job_id:job.id,p_worker_id:workerId,p_succeeded:true,p_error:null,p_retry_after_seconds:null,
        })
        succeeded+=1
      } catch (error) {
        const message = error instanceof Error ? error.message : 'BALANCE_JOB_FAILED'
        const retryAfter = retryDelaySeconds(job.attempt_count)
        await client.rpc('finish_integration_job',{
          p_job_id:job.id,p_worker_id:workerId,p_succeeded:false,p_error:message.slice(0,160),p_retry_after_seconds:retryAfter,
        })
        if (retryAfter===null || job.attempt_count>=job.max_attempts) failed+=1
        else retried+=1
      }
    }

    return jsonResponse({worker_id:workerId,collections_created:Number(created ?? 0),email_enabled:emailEnabled,kommo_delivery_enabled:kommoDeliveryEnabled,claimed:(jobs ?? []).length,succeeded,retried,failed})
  } catch (error) {
    const code = error instanceof Error ? error.message : 'BALANCE_WORKER_FAILED'
    return errorResponse(error,code==='INTERNAL_AUTH_REQUIRED'?401:500)
  }
})
