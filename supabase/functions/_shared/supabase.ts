import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { installLocalVerificationTransport } from './local-verification.ts'
import { authorizeAdmin, bearerToken, rememberedPermission, rememberProfile, type AdminAccessProfile } from './admin-auth.ts'
export { rememberedProfile } from './admin-auth.ts'

installLocalVerificationTransport()

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

// Memoized at module scope: the client only wraps a fixed service-role key and
// carries no per-request auth state (caller JWTs are passed as call arguments,
// e.g. client.auth.getUser(jwt), never stored as session state), so it is safe
// to reuse across concurrent requests within the same isolate. This removes the
// redundant createClient() construction that several handlers previously paid
// for multiple times per request (once directly, once inside requireAdmin/
// requireAdminPermission, etc.).
let cachedAdminClient: SupabaseClient | null = null

export function adminClient(): SupabaseClient {
  if (!cachedAdminClient) {
    cachedAdminClient = createClient(requiredEnv('SUPABASE_URL'), secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    })
  }
  return cachedAdminClient
}

export async function requireAdmin(req: Request): Promise<{ adminId: string; authUserId: string }> {
  const token = bearerToken(req)
  const client = adminClient()
  // Auth (token) e banco (admin + perfil) em paralelo; ver admin-auth.ts.
  const identity = await authorizeAdmin(token, {
    getUser: async (jwt) => {
      const { data, error } = await client.auth.getUser(jwt)
      return error || !data.user ? null : { id: data.user.id }
    },
    resolveProfile: async (authUserId) => {
      const { data, error } = await client.rpc('service_admin_resolve_access_profile', { p_auth_user_id: authUserId })
      if (!error) return data as AdminAccessProfile | null
      // Janela de deploy (função ainda inexistente): caminho antigo em duas leituras.
      if (error.code !== 'PGRST202' && error.code !== '42883') throw new Error(error.message)
      const resolved = await client.rpc('service_admin_resolve_auth_user', { p_auth_user_id: authUserId })
      if (resolved.error || typeof resolved.data !== 'string' || !resolved.data) return null
      const profile = await client.rpc('service_admin_get_access_profile', { p_admin_id: resolved.data })
      return profile.error ? null : profile.data as AdminAccessProfile | null
    },
  })
  rememberProfile(identity.adminId, identity.profile)
  return { adminId: identity.adminId, authUserId: identity.authUserId }
}

export async function hasAdminPermission(adminId: string, permission: string): Promise<boolean> {
  // Perfil lido no requireAdmin desta mesma requisição (janela de 1 s); fora dele, RPC.
  const remembered = rememberedPermission(adminId, permission)
  if (remembered !== null) return remembered
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
