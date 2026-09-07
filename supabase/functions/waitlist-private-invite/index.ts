import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function secretKey(): string {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (legacy) return legacy
  const raw = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (!raw) throw new Error('MISSING_ENV:SUPABASE_SECRET_KEYS')
  const parsed = JSON.parse(raw)
  const value = parsed.default ?? Object.values(parsed)[0]
  if (typeof value !== 'string' || !value) throw new Error('INVALID_ENV:SUPABASE_SECRET_KEYS')
  return value
}

function client(): SupabaseClient {
  return createClient(requiredEnv('SUPABASE_URL'), secretKey(), { auth: { persistSession: false, autoRefreshToken: false } })
}

function clientKey(req: Request): string {
  const forwarded = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? ''
  const ip = req.headers.get('cf-connecting-ip')?.trim() || forwarded || req.headers.get('x-real-ip')?.trim() || ''
  if (ip) return `ip:${ip}`
  const ua = (req.headers.get('user-agent') ?? '').trim().slice(0, 200)
  return ua ? `missing-ip:ua:${ua}` : 'missing-ip:unknown'
}

async function rateLimit(db: SupabaseClient, req: Request): Promise<void> {
  const { error } = await db.rpc('service_consume_public_rate_limit', {
    p_scope: 'WAITLIST_PRIVATE_INVITE',
    p_client_key: clientKey(req),
    p_limit: 30,
    p_window_seconds: 600,
  })
  if (!error) return
  if (error.message.includes('RATE_LIMITED')) throw new Error('RATE_LIMITED')
  throw new Error('RATE_LIMIT_BACKEND_FAILED')
}

function token(value: unknown): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (text.length < 32) throw new Error('WAITLIST_PRIVATE_TOKEN_INVALID')
  return text
}

function uuid(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) throw new Error(code)
  return text
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const db = client()
    await rateLimit(db, req)
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = String(body.action ?? 'CONTEXT').trim().toUpperCase()
    const accessToken = token(body.access_token)

    if (action === 'CONTEXT') {
      const { data, error } = await db.rpc('public_get_waitlist_private_invite_context', { p_access_token: accessToken })
      if (error) throw new Error(error.message)
      return response({ data })
    }

    if (action === 'CREATE_HOLD') {
      const extras = Array.isArray(body.extra_selections) ? body.extra_selections : []
      const peopleCount = Number(body.people_count ?? 1)
      if (!Number.isInteger(peopleCount) || peopleCount < 1) throw new Error('INVALID_PEOPLE_COUNT')
      const { data, error } = await db.rpc('public_create_waitlist_private_checkout_hold', {
        p_access_token: accessToken,
        p_service_id: uuid(body.service_id, 'WAITLIST_PRIVATE_SERVICE_NOT_ALLOWED'),
        p_extra_selections: extras,
        p_people_count: peopleCount,
      })
      if (error) throw new Error(error.message)
      return response({ hold: data }, 201)
    }

    throw new Error('WAITLIST_PRIVATE_ACTION_INVALID')
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'WAITLIST_PRIVATE_INVITE_FAILED'
    const code = raw.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|WAITLIST_PRIVATE_[A-Z0-9_]+|INVALID_[A-Z0-9_]+|BOOKING_PAGE_NOT_FOUND|SERVICE_NOT_AVAILABLE|REQUIRED_EXTRA_MISSING)/)?.[1]
      ?? raw.split(':')[0]
    const status = code === 'RATE_LIMITED' ? 429
      : code === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : code === 'WAITLIST_PRIVATE_SLOT_TAKEN' ? 409
      : code === 'WAITLIST_PRIVATE_TOKEN_INVALID' ? 404
      : code === 'WAITLIST_PRIVATE_TOKEN_EXPIRED' ? 410
      : 400
    return response({ error: { code } }, status)
  }
})
