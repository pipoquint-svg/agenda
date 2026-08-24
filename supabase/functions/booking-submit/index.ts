import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requestIp(req: Request): string | null {
  return (req.headers.get('x-forwarded-for') ?? req.headers.get('cf-connecting-ip') ?? '')
    .split(',')[0]
    .trim() || null
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('INVALID_TERMS')
  return value.map((item) => {
    if (typeof item !== 'string' || !item) throw new Error('INVALID_TERMS')
    return item
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'BOOKING_SUBMIT',
      limit: 30,
      windowSeconds: 600,
    })

    const body = await req.json()
    const token = typeof body?.checkout_hold_token === 'string' ? body.checkout_hold_token.trim() : ''
    if (token.length < 32) throw new Error('CHECKOUT_HOLD_TOKEN_REQUIRED')

    const terms = stringArray(body?.term_version_ids ?? [])
    const answers = Array.isArray(body?.answers) ? body.answers : []
    const coupon = typeof body?.coupon_code === 'string' ? body.coupon_code.trim() || null : null
    const ip = requestIp(req)
    const userAgent = (req.headers.get('user-agent') ?? '').slice(0, 500) || null
    const requestId = (() => {
      const supplied = req.headers.get('x-request-id')?.trim() ?? ''
      return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(supplied)
        ? supplied
        : crypto.randomUUID()
    })()

    const { error: accessError } = await client.rpc('service_public_check_customer_access', {
      p_checkout_hold_token: token,
      p_ip: ip,
      p_user_agent: userAgent ?? '',
      p_request_id: requestId,
    })
    if (accessError) {
      const code = accessError.message.match(/(ONLINE_BOOKING_NOT_AVAILABLE|FREE_VISIT_NOT_AVAILABLE|FREE_VISIT_ACTIVE_LIMIT_REACHED|CHECKOUT_CUSTOMER_REQUIRED)/)?.[1]
      throw new Error(code ?? 'CHECKOUT_ACCESS_CHECK_FAILED')
    }

    const { data, error } = await client.rpc('service_submit_public_checkout', {
      p_checkout_hold_token: token,
      p_coupon_code: coupon,
      p_term_version_ids: terms,
      p_answers: answers,
      p_acceptance_ip: ip,
      p_user_agent: userAgent,
    })

    if (error) {
      const known = error.message.match(/(CHECKOUT_HOLD_NOT_ACTIVE|CHECKOUT_CUSTOMER_REQUIRED|REQUIRED_SERVICE_FIELDS_MISSING|INVALID_SERVICE_ANSWERS|INVALID_SERVICE_ANSWER_VALUE|TERMS_NOT_ACCEPTED|TERMS_CONFIGURATION_MISSING|INVALID_COUPON|COUPON_USAGE_LIMIT_REACHED|COUPON_CUSTOMER_MISMATCH|COUPON_PACKAGE_POLICY_REQUIRES_DECISION|ONLINE_BOOKING_NOT_AVAILABLE|FREE_VISIT_NOT_AVAILABLE|FREE_VISIT_ACTIVE_LIMIT_REACHED)/)?.[1]
      throw new Error(known ?? `CHECKOUT_SUBMIT_FAILED:${error.message}`)
    }

    return response({ ok: true, appointment: data })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'CHECKOUT_SUBMIT_FAILED'
    const publicCode = code.split(':')[0]
    const neutral = ['ONLINE_BOOKING_NOT_AVAILABLE', 'FREE_VISIT_NOT_AVAILABLE'].includes(publicCode)
      ? 'ONLINE_BOOKING_NOT_AVAILABLE'
      : publicCode
    const status = neutral === 'RATE_LIMITED' ? 429
      : neutral === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : neutral === 'CHECKOUT_HOLD_NOT_ACTIVE' ? 409
      : neutral === 'ONLINE_BOOKING_NOT_AVAILABLE' ? 403
      : 400
    return response({ error: { code: neutral } }, status)
  }
})
