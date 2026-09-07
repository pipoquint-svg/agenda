import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
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

function adminClient(): SupabaseClient {
  return createClient(requiredEnv('SUPABASE_URL'), secretKey(), { auth: { persistSession: false, autoRefreshToken: false } })
}

async function requireAdmin(req: Request, client: SupabaseClient): Promise<string> {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('ADMIN_AUTH_REQUIRED')
  const { data: userData, error: userError } = await client.auth.getUser(match[1])
  if (userError || !userData.user) throw new Error('ADMIN_AUTH_INVALID')
  const { data: adminId, error } = await client.rpc('service_admin_resolve_auth_user', { p_auth_user_id: userData.user.id })
  if (error || typeof adminId !== 'string' || !adminId) throw new Error('ADMIN_ACCESS_DENIED')
  return adminId
}

function uuid(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) throw new Error(code)
  return text
}

function uuidArray(value: unknown, code: string): string[] {
  if (!Array.isArray(value) || value.length === 0) throw new Error(code)
  return value.map((item) => uuid(item, code))
}

function iso(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  const parsed = new Date(text)
  if (!text || Number.isNaN(parsed.getTime())) throw new Error(code)
  return parsed.toISOString()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET' && req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    const adminId = await requireAdmin(req, client)

    if (req.method === 'GET') {
      const { data, error } = await client.rpc('service_admin_list_waitlist_private_slots', { p_admin_id: adminId })
      if (error) throw new Error(error.message)
      return response({ slots: Array.isArray(data) ? data : [] })
    }

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = String(body.action ?? '').trim().toUpperCase()

    if (action === 'CREATE') {
      const { data, error } = await client.rpc('service_admin_create_waitlist_private_slot', {
        p_start_at: iso(body.start_at, 'WAITLIST_PRIVATE_START_INVALID'),
        p_expires_at: iso(body.expires_at, 'WAITLIST_PRIVATE_EXPIRY_INVALID'),
        p_service_ids: uuidArray(body.service_ids, 'WAITLIST_PRIVATE_SERVICES_REQUIRED'),
        p_waitlist_entry_ids: uuidArray(body.waitlist_entry_ids, 'WAITLIST_PRIVATE_INVITEES_REQUIRED'),
        p_admin_id: adminId,
      })
      if (error) throw new Error(error.message)
      return response(data, 201)
    }

    if (action === 'ROTATE_INVITE') {
      const { data, error } = await client.rpc('service_admin_rotate_waitlist_private_invite', {
        p_invite_id: uuid(body.invite_id, 'WAITLIST_PRIVATE_INVITE_ID_INVALID'),
        p_admin_id: adminId,
      })
      if (error) throw new Error(error.message)
      return response(data)
    }

    if (action === 'REVOKE_INVITE') {
      const { data, error } = await client.rpc('service_admin_revoke_waitlist_private_invite', {
        p_invite_id: uuid(body.invite_id, 'WAITLIST_PRIVATE_INVITE_ID_INVALID'),
        p_admin_id: adminId,
      })
      if (error) throw new Error(error.message)
      return response(data)
    }

    if (action === 'EXTEND') {
      const { data, error } = await client.rpc('service_admin_extend_waitlist_private_slot', {
        p_slot_id: uuid(body.slot_id, 'WAITLIST_PRIVATE_SLOT_ID_INVALID'),
        p_expires_at: iso(body.expires_at, 'WAITLIST_PRIVATE_EXPIRY_INVALID'),
        p_admin_id: adminId,
      })
      if (error) throw new Error(error.message)
      return response(data)
    }

    if (action === 'CLOSE') {
      const { data, error } = await client.rpc('service_admin_close_waitlist_private_slot', {
        p_slot_id: uuid(body.slot_id, 'WAITLIST_PRIVATE_SLOT_ID_INVALID'),
        p_admin_id: adminId,
      })
      if (error) throw new Error(error.message)
      return response(data)
    }

    throw new Error('WAITLIST_PRIVATE_ACTION_INVALID')
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'WAITLIST_PRIVATE_ADMIN_FAILED'
    const code = raw.match(/(ADMIN_[A-Z0-9_]+|WAITLIST_PRIVATE_[A-Z0-9_]+|SERVICE_HAS_NO_REQUIRED_RESOURCES)/)?.[1]
      ?? raw.split(':')[0]
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'WAITLIST_PRIVATE_SLOT_CONFLICT' || code === 'WAITLIST_PRIVATE_SLOT_BUSY' ? 409
      : 400
    return response({ error: { code } }, status)
  }
})
