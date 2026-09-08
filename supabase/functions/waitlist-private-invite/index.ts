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
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
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

function safeErrorCode(raw: string): string {
  return raw.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|WAITLIST_PRIVATE_[A-Z0-9_]+|INVALID_[A-Z0-9_]+|BOOKING_PAGE_NOT_FOUND|SERVICE_NOT_AVAILABLE|REQUIRED_EXTRA_MISSING)/)?.[1]
    ?? 'WAITLIST_PRIVATE_INVITE_FAILED'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const db = adminClient()
    await enforceDistributedPublicRateLimit(db, req, {
      scope: 'WAITLIST_PRIVATE_INVITE',
      limit: 30,
      windowSeconds: 600,
    })

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = String(body.action ?? 'CONTEXT').trim().toUpperCase()
    const accessToken = token(body.access_token)

    if (action === 'CONTEXT') {
      const { data: roundData, error: roundError } = await db.rpc('public_waitlist_private_round_action', {
        p_action: 'CONTEXT',
        p_access_token: accessToken,
        p_payload: {},
      })
      if (roundError) throw new Error(roundError.message)
      if (roundData) return response({ data: roundData })

      const { data, error } = await db.rpc('public_get_waitlist_private_invite_context', { p_access_token: accessToken })
      if (error) throw new Error(error.message)
      return response({ data: { ...data, mode: 'SINGLE' } })
    }

    if (action === 'CREATE_HOLD') {
      const extras = Array.isArray(body.extra_selections) ? body.extra_selections : []
      const peopleCount = Number(body.people_count ?? 1)
      if (!Number.isInteger(peopleCount) || peopleCount < 1) throw new Error('INVALID_PEOPLE_COUNT')

      if (body.slot_id) {
        const { data, error } = await db.rpc('public_waitlist_private_round_action', {
          p_action: 'CREATE_HOLD',
          p_access_token: accessToken,
          p_payload: {
            slot_id: uuid(body.slot_id, 'WAITLIST_PRIVATE_SLOT_ID_INVALID'),
            service_id: uuid(body.service_id, 'WAITLIST_PRIVATE_SERVICE_NOT_ALLOWED'),
            extra_selections: extras,
            people_count: peopleCount,
          },
        })
        if (error) throw new Error(error.message)
        return response({ hold: data }, 201)
      }

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
    const raw = error instanceof Error ? error.message : ''
    const code = safeErrorCode(raw)
    const status = code === 'RATE_LIMITED' ? 429
      : code === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : code === 'WAITLIST_PRIVATE_SLOT_TAKEN' ? 409
      : code === 'WAITLIST_PRIVATE_INVITE_IN_PROGRESS' || code === 'WAITLIST_PRIVATE_INVITE_ALREADY_USED' ? 409
      : code === 'WAITLIST_PRIVATE_TOKEN_INVALID' ? 404
      : code === 'WAITLIST_PRIVATE_TOKEN_EXPIRED' ? 410
      : code === 'WAITLIST_PRIVATE_INVITE_FAILED' ? 500
      : 400
    return response({ error: { code } }, status)
  }
})
