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

export type AdminContext = {
  adminId: string
  authUserId: string
  role: string
  permissions: Record<string, boolean>
}

export async function requireAdmin(req: Request, requiredModule?: string): Promise<AdminContext> {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('ADMIN_AUTH_REQUIRED')

  const client = adminClient()
  const { data: userData, error: userError } = await client.auth.getUser(match[1])
  if (userError || !userData.user) throw new Error('ADMIN_AUTH_INVALID')

  const { data: admin, error: adminError } = await client
    .from('admin_users')
    .select('id, auth_user_id, role, is_active')
    .eq('auth_user_id', userData.user.id)
    .eq('is_active', true)
    .maybeSingle()

  if (adminError || !admin) throw new Error('ADMIN_ACCESS_DENIED')

  const { data: permissionRows, error: permissionError } = await client
    .from('admin_user_permissions')
    .select('module_key, can_access')
    .eq('admin_user_id', admin.id)

  if (permissionError) throw new Error('ADMIN_PERMISSION_LOOKUP_FAILED')

  const permissions = Object.fromEntries(
    (permissionRows ?? []).map((row) => [String(row.module_key), Boolean(row.can_access)]),
  )

  if (requiredModule && admin.role !== 'OWNER' && permissions[requiredModule.toUpperCase()] !== true) {
    throw new Error('ADMIN_MODULE_ACCESS_DENIED')
  }

  return {
    adminId: admin.id,
    authUserId: admin.auth_user_id,
    role: admin.role,
    permissions,
  }
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
