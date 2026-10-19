// Owner-only password management for team members (admin-team-member-access).
// Pure rules live here so they can be tested without Auth or the database.

export const OWNER_PASSWORD_MIN_LENGTH = 12
export const OWNER_PASSWORD_MAX_LENGTH = 128
// Supabase Auth hashes with bcrypt, which only accepts up to 72 bytes.
export const OWNER_PASSWORD_MAX_BYTES = 72

// Mirrors the production Auth policy (password_required_characters).
const SYMBOLS = "!@#$%^&*()_+-=[]{};'\\:\"|<>?,./`~"

export const RECOVERY_REDIRECT_URL = 'https://www.blacksheepestudiocriativo.com.br/gestao/recuperar-senha'

export type PasswordOperation = 'SET_PASSWORD' | 'SEND_PASSWORD_RECOVERY'

export function passwordAuditAction(operation: PasswordOperation): string {
  return operation === 'SET_PASSWORD' ? 'USER_PASSWORD_RESET_BY_OWNER' : 'USER_PASSWORD_RECOVERY_SENT'
}

export type RateLimitPolicy = { scope: string; limit: number; windowSeconds: number }

// One recovery e-mail per member every 5 minutes; an Owner can act on at most
// 10 members per hour. Auth adds its own per-user e-mail frequency limit on top.
export const PASSWORD_RATE_LIMITS: Record<PasswordOperation, { actor: RateLimitPolicy; target: RateLimitPolicy }> = {
  SET_PASSWORD: {
    actor: { scope: 'OWNER_PASSWORD_SET_ACTOR', limit: 10, windowSeconds: 3600 },
    target: { scope: 'OWNER_PASSWORD_SET_TARGET', limit: 5, windowSeconds: 3600 },
  },
  SEND_PASSWORD_RECOVERY: {
    actor: { scope: 'OWNER_PASSWORD_RECOVERY_ACTOR', limit: 10, windowSeconds: 3600 },
    target: { scope: 'OWNER_PASSWORD_RECOVERY_TARGET', limit: 1, windowSeconds: 300 },
  },
}

export type PasswordActor = { adminId: string; role: string; isActive: boolean }
export type PasswordTarget = { id: string; role: string; is_active: boolean }

/** Returns the password unchanged when it satisfies the Owner policy; never echoes it in errors. */
export function validateOwnerPassword(value: unknown): string {
  if (typeof value !== 'string') throw new Error('ADMIN_PASSWORD_INVALID')
  const length = [...value].length
  if (length < OWNER_PASSWORD_MIN_LENGTH) throw new Error('ADMIN_PASSWORD_TOO_SHORT')
  if (length > OWNER_PASSWORD_MAX_LENGTH || new TextEncoder().encode(value).length > OWNER_PASSWORD_MAX_BYTES) {
    throw new Error('ADMIN_PASSWORD_TOO_LONG')
  }
  if (/\s/.test(value)) throw new Error('ADMIN_PASSWORD_INVALID')
  const hasLower = /[a-z]/.test(value)
  const hasUpper = /[A-Z]/.test(value)
  const hasDigit = /[0-9]/.test(value)
  const hasSymbol = [...value].some((char) => SYMBOLS.includes(char))
  if (!hasLower || !hasUpper || !hasDigit || !hasSymbol) throw new Error('ADMIN_PASSWORD_WEAK')
  return value
}

/** Owner-only, active Owner, never another Owner nor the Owner's own account, never an inactive member. */
export function assertPasswordManagementAllowed(actor: PasswordActor, target: PasswordTarget): void {
  if (!actor.isActive || actor.role.toUpperCase() !== 'OWNER') throw new Error('ADMIN_OWNER_REQUIRED')
  if (target.id === actor.adminId) throw new Error('ADMIN_SELF_PASSWORD_FORBIDDEN')
  if (String(target.role ?? '').toUpperCase() === 'OWNER') throw new Error('ADMIN_OWNER_PASSWORD_FORBIDDEN')
  if (target.is_active !== true) throw new Error('ADMIN_TARGET_INACTIVE')
}

/** Audit row with identifiers, operation and result only: no password, token, link or e-mail. */
export function passwordAuditRow(
  operation: PasswordOperation,
  actorId: string,
  targetId: string,
  result: 'SUCCESS' | 'FAILED',
  errorCode?: string,
) {
  return {
    admin_user_id: actorId,
    entity_type: 'ADMIN_USER',
    entity_id: targetId,
    action: passwordAuditAction(operation),
    before_json: null,
    after_json: {
      operation,
      result,
      ...(errorCode ? { error_code: errorCode.slice(0, 80) } : {}),
    },
    origin: 'ADMIN',
  }
}

/** Auth rejects weak or oversized passwords with 4xx; anything else is an Auth failure. */
export function authPasswordUpdateErrorCode(error: { status?: number; code?: string; message?: string }): string {
  const code = String(error.code ?? '').toLowerCase()
  const status = Number(error.status ?? 0)
  if (code === 'weak_password' || ((status === 400 || status === 422) && /password/i.test(String(error.message ?? '')))) {
    return 'ADMIN_PASSWORD_WEAK'
  }
  return 'ADMIN_AUTH_PASSWORD_UPDATE_FAILED'
}

export function passwordErrorStatus(code: string): number | null {
  if (code === 'ADMIN_OWNER_REQUIRED' || code === 'ADMIN_SELF_PASSWORD_FORBIDDEN' || code === 'ADMIN_OWNER_PASSWORD_FORBIDDEN') return 403
  if (code === 'ADMIN_PASSWORD_INVALID' || code === 'ADMIN_PASSWORD_TOO_SHORT' || code === 'ADMIN_PASSWORD_TOO_LONG' || code === 'ADMIN_PASSWORD_WEAK') return 422
  if (code === 'RATE_LIMITED' || code === 'ADMIN_PASSWORD_RECOVERY_RATE_LIMITED') return 429
  if (code === 'ADMIN_AUTH_PASSWORD_UPDATE_FAILED' || code === 'ADMIN_PASSWORD_RECOVERY_SEND_FAILED') return 502
  if (code === 'RATE_LIMIT_BACKEND_FAILED') return 503
  return null
}
