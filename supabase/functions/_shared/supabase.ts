import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

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

export function adminClient(): SupabaseClient {
  return createClient(requiredEnv('SUPABASE_URL'), secretKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

export async function requireAdmin(req: Request): Promise<{ adminId: string; authUserId: string }> {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('ADMIN_AUTH_REQUIRED')

  const client = adminClient()
  const { data: userData, error: userError } = await client.auth.getUser(match[1])
  if (userError || !userData.user) throw new Error('ADMIN_AUTH_INVALID')

  const { data: adminId, error: adminError } = await client.rpc('service_admin_resolve_auth_user', {
    p_auth_user_id: userData.user.id,
  })

  if (adminError || typeof adminId !== 'string' || !adminId) throw new Error('ADMIN_ACCESS_DENIED')
  return { adminId, authUserId: userData.user.id }
}

export async function hasAdminPermission(adminId: string, permission: string): Promise<boolean> {
  const client = adminClient()
  const { data, error } = await client.rpc('service_admin_has_permission', {
    p_admin_id: adminId,
    p_permission: permission,
  })
  if (error) throw new Error(error.message)
  return data === true
}

export async function requireAdminPermission(
  req: Request,
  permission: string,
): Promise<{ adminId: string; authUserId: string }> {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
  return admin
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

export function errorResponse(error: unknown, status = 400): Response {
  const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
  return jsonResponse({ error: { code: message } }, status)
}
