import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function token(value: unknown): string {
  if (typeof value !== 'string' || value.trim().length < 32) {
    throw new Error('PRE_RESERVATION_TOKEN_REQUIRED')
  }
  return value.trim()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'PRE_RESERVATION_TOKEN',
      limit: 30,
      windowSeconds: 600,
    })

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const { data, error } = await client.rpc('public_get_pre_reservation_context', {
      p_access_token: token(body.access_token),
    })
    if (error) throw new Error(error.message)
    return json({ data })
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'PRE_RESERVATION_ACCESS_FAILED'
    const code = raw.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|PRE_RESERVATION_TOKEN_REQUIRED|PRE_RESERVATION_TOKEN_INVALID|PRE_RESERVATION_TOKEN_EXPIRED)/)?.[1]
      ?? raw.split(':')[0]
    const status = code === 'RATE_LIMITED' ? 429
      : code === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : 400
    return json({ error: { code } }, status)
  }
})
