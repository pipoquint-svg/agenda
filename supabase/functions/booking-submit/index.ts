import { adminClient } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

const ipBuckets = new Map<string, { count: number; resetAt: number }>()

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

function enforceIpRateLimit(req: Request): void {
  const ip = requestIp(req) ?? 'unknown'
  const now = Date.now()
  const current = ipBuckets.get(ip)
  if (!current || current.resetAt <= now) {
    ipBuckets.set(ip, { count: 1, resetAt: now + 10 * 60 * 1000 })
    return
  }
  if (current.count >= 30) throw new Error('RATE_LIMITED')
  current.count += 1
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
    enforceIpRateLimit(req)
    const body = await req.json()
    const token = typeof body?.checkout_hold_token === 'string' ? body.checkout_hold_token.trim() : ''
    if (token.length < 32) throw new Error('CHECKOUT_HOLD_TOKEN_REQUIRED')

    const terms = stringArray(body?.term_version_ids ?? [])
    const answers = Array.isArray(body?.answers) ? body.answers : []
    const coupon = typeof body?.coupon_code === 'string' ? body.coupon_code.trim() || null : null
    const ip = requestIp(req)
    const userAgent = (req.headers.get('user-agent') ?? '').slice(0, 500) || null

    const client = adminClient()
    const { data, error } = await client.rpc('service_submit_public_checkout', {
      p_checkout_hold_token: token,
      p_coupon_code: coupon,
      p_term_version_ids: terms,
      p_answers: answers,
      p_acceptance_ip: ip,
      p_user_agent: userAgent,
    })

    if (error) {
      const known = error.message.match(/(CHECKOUT_HOLD_NOT_ACTIVE|CHECKOUT_CUSTOMER_REQUIRED|REQUIRED_SERVICE_FIELDS_MISSING|INVALID_SERVICE_ANSWERS|INVALID_SERVICE_ANSWER_VALUE|TERMS_NOT_ACCEPTED|TERMS_CONFIGURATION_MISSING|INVALID_COUPON|COUPON_USAGE_LIMIT_REACHED|COUPON_CUSTOMER_MISMATCH|COUPON_PACKAGE_POLICY_REQUIRES_DECISION)/)?.[1]
      throw new Error(known ?? `CHECKOUT_SUBMIT_FAILED:${error.message}`)
    }

    return response({ ok: true, appointment: data })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'CHECKOUT_SUBMIT_FAILED'
    const publicCode = code.split(':')[0]
    const status = publicCode === 'RATE_LIMITED' ? 429
      : publicCode === 'CHECKOUT_HOLD_NOT_ACTIVE' ? 409
      : 400
    return response({ error: { code: publicCode } }, status)
  }
})
