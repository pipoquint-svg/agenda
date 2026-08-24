import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
  'cache-control': 'no-store, max-age=0',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) {
    throw new Error('BALANCE_COLLECTION_INVALID_OR_EXPIRED')
  }
  return text
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'BALANCE_COLLECTION_ACCESS',
      limit: 12,
      windowSeconds: 600,
    })

    const body = await req.json().catch(() => ({}))
    const collectionId = uuid(body?.collection_id)
    const email = typeof body?.email === 'string' ? body.email.trim().toLowerCase().slice(0, 320) : ''
    if (!email) throw new Error('BALANCE_COLLECTION_VERIFICATION_FAILED')

    const { data, error } = await client.rpc('service_verify_balance_collection_email', {
      p_collection_id: collectionId,
      p_email: email,
    })
    if (error) throw new Error(error.message)

    return json({ data })
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'BALANCE_COLLECTION_ACCESS_FAILED'
    if (raw.includes('RATE_LIMITED')) return json({ error: { code: 'BALANCE_COLLECTION_RATE_LIMITED' } }, 429)
    if (raw.includes('BALANCE_COLLECTION_ALREADY_PAID')) return json({ error: { code: 'BALANCE_COLLECTION_ALREADY_PAID' } }, 409)
    if (raw.includes('BALANCE_COLLECTION_INVALID_OR_EXPIRED')) {
      return json({ error: { code: 'BALANCE_COLLECTION_INVALID_OR_EXPIRED' } }, 410)
    }
    if (raw.includes('BALANCE_COLLECTION_VERIFICATION_FAILED')) {
      return json({ error: { code: 'BALANCE_COLLECTION_VERIFICATION_FAILED' } }, 400)
    }
    return json({ error: { code: 'BALANCE_COLLECTION_TEMPORARY_FAILURE' } }, 503)
  }
})
