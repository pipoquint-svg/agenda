// Autorização administrativa com menos idas ao banco, sem afrouxar a verificação.
//
// Antes: validar token no Auth → resolver admin → 1 RPC por permissão, tudo em
// fila. Agora a validação do token (Auth) e a leitura do admin + perfil de
// permissões (banco) correm em paralelo. O `sub` usado para a leitura vem do
// próprio token, mas nada é aceito antes de o Auth confirmar o token e o
// usuário retornado ser exatamente esse `sub`. O perfil lido é reaproveitado
// pelas checagens seguintes por no máximo 1 s; permissões fora dele seguem para o RPC.

export type AdminIdentity = { adminId: string; authUserId: string }

export type AdminAccessProfile = { permissions: Record<string, boolean> } & Record<string, unknown>

export type AdminAuthDeps = {
  getUser: (token: string) => Promise<{ id: string } | null>
  /** Admin ativo + perfil numa única leitura (`admin_user_id` dentro do perfil). */
  resolveProfile: (authUserId: string) => Promise<AdminAccessProfile | null>
}

/** `sub` do JWT sem confiar nele (apenas para paralelizar; o Auth valida depois). */
export function unverifiedJwtSubject(token: string): string | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null
  try {
    const json = atob(parts[1].replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(parts[1].length / 4) * 4, '='))
    const payload = JSON.parse(json) as { sub?: unknown }
    return typeof payload.sub === 'string' && /^[0-9a-f-]{36}$/i.test(payload.sub) ? payload.sub : null
  } catch {
    return null
  }
}

export function bearerToken(req: Request): string {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('ADMIN_AUTH_REQUIRED')
  return match[1]
}

export async function authorizeAdmin(
  token: string,
  deps: AdminAuthDeps,
): Promise<AdminIdentity & { profile: AdminAccessProfile | null }> {
  const claimed = unverifiedJwtSubject(token)

  const lookup = async (authUserId: string) => {
    const profile = await deps.resolveProfile(authUserId)
    const adminId = profile && typeof profile.admin_user_id === 'string' && profile.admin_user_id ? profile.admin_user_id : null
    return adminId ? { adminId, profile } : { adminId: null, profile: null }
  }

  // Leitura do admin já começa com o `sub` alegado; só é usada se o Auth confirmar.
  const speculative = claimed ? lookup(claimed).catch(() => null) : null
  const user = await deps.getUser(token).catch(() => null)
  if (!user?.id) throw new Error('ADMIN_AUTH_INVALID')

  const resolved = claimed === user.id && speculative ? await speculative : null
  const { adminId, profile } = resolved ?? await lookup(user.id).catch(() => ({ adminId: null, profile: null }))
  if (!adminId) throw new Error('ADMIN_ACCESS_DENIED')
  return { adminId, authUserId: user.id, profile }
}

const PROFILE_TTL_MS = 1000
const profiles = new Map<string, { profile: AdminAccessProfile; expiresAt: number }>()

function isProfile(value: unknown): value is AdminAccessProfile {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const permissions = (value as { permissions?: unknown }).permissions
  return !!permissions && typeof permissions === 'object' && !Array.isArray(permissions)
}

/** Guarda o perfil lido nesta requisição para as checagens seguintes do mesmo handler. */
export function rememberProfile(adminId: string, profile: unknown, now = Date.now()) {
  if (!isProfile(profile)) return
  profiles.set(adminId, { profile, expiresAt: now + PROFILE_TTL_MS })
  if (profiles.size > 500) {
    for (const [key, value] of profiles) if (value.expiresAt <= now) profiles.delete(key)
  }
}

/** `true`/`false` quando o perfil recente responde; `null` para seguir ao RPC. */
export function rememberedPermission(adminId: string, permission: string, now = Date.now()): boolean | null {
  const value = rememberedProfile(adminId, now)?.permissions[permission]
  return typeof value === 'boolean' ? value : null
}

/** Perfil completo lido na autorização desta requisição (janela de 1 s), ou `null`. */
export function rememberedProfile(adminId: string, now = Date.now()): AdminAccessProfile | null {
  const entry = profiles.get(adminId)
  return entry && entry.expiresAt > now ? entry.profile : null
}

export function forgetRememberedPermissions() {
  profiles.clear()
}
