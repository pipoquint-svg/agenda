import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-appointment-token',
  'access-control-allow-methods': 'GET, OPTIONS',
  'cache-control': 'no-store, max-age=0',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function appointmentToken(req: Request): string {
  const value = req.headers.get('x-appointment-token')?.trim() ?? ''
  if (value.length < 32 || value.length > 500) throw new Error('APPOINTMENT_TOKEN_INVALID')
  return value
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'PUBLIC_PAYMENT_PREVIEW',
      limit: 60,
      windowSeconds: 600,
    })

    const token = appointmentToken(req)
    const { data, error } = await client.rpc('service_get_public_payment_method_preview', {
      p_access_token: token,
    })
    if (error) throw new Error(error.message)

    return response({ data })
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'PAYMENT_PREVIEW_FAILED'
    const code = raw.match(/(APPOINTMENT_TOKEN_INVALID|APPOINTMENT_TOKEN_REVOKED|APPOINTMENT_TOKEN_EXPIRED|TOKEN_SCOPE_DENIED|APPOINTMENT_NOT_PAYABLE|PAYMENT_HOLD_EXPIRED|CUSTOMER_NOT_FOUND|SERVICE_NOT_FOUND|PAYMENT_SETTINGS_LOAD_FAILED|RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED)/)?.[1]
      ?? 'PAYMENT_PREVIEW_FAILED'
    const status = code === 'RATE_LIMITED' ? 429
      : code === 'RATE_LIMIT_BACKEND_FAILED' || code === 'PAYMENT_PREVIEW_FAILED' || code === 'PAYMENT_SETTINGS_LOAD_FAILED' ? 503
      : code.startsWith('APPOINTMENT_TOKEN') || code === 'TOKEN_SCOPE_DENIED' ? 401
      : code === 'PAYMENT_HOLD_EXPIRED' ? 409
      : 400
    return response({ error: { code } }, status)
  }
})
