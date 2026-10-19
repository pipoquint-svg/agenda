import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import {
  assertPasswordManagementAllowed,
  authPasswordUpdateErrorCode,
  PASSWORD_RATE_LIMITS,
  passwordAuditAction,
  passwordAuditRow,
  passwordErrorStatus,
  validateOwnerPassword,
} from './team-password.ts'

const OWNER = { adminId: '00000000-0000-4000-8000-000000000001', role: 'OWNER', isActive: true }
const MEMBER = { id: '00000000-0000-4000-8000-000000000002', role: 'OPERATION', is_active: true }
const VALID = 'Forte-Senha-2026'

Deno.test('accepts a 12+ character password with lower, upper, digit and symbol', () => {
  assertEquals(validateOwnerPassword(VALID), VALID)
  assertEquals(validateOwnerPassword('Aa1!' + 'x'.repeat(68)), 'Aa1!' + 'x'.repeat(68))
})

Deno.test('rejects passwords outside the Owner policy without echoing them', () => {
  const cases: Array<[unknown, string]> = [
    [undefined, 'ADMIN_PASSWORD_INVALID'],
    [12345678901234, 'ADMIN_PASSWORD_INVALID'],
    ['Curta-1a', 'ADMIN_PASSWORD_TOO_SHORT'],
    ['Aa1!' + 'x'.repeat(125), 'ADMIN_PASSWORD_TOO_LONG'],
    // 72-byte bcrypt ceiling: 40 two-byte characters exceed it despite being short.
    ['Aa1!' + 'é'.repeat(40), 'ADMIN_PASSWORD_TOO_LONG'],
    ['Forte Senha 2026!', 'ADMIN_PASSWORD_INVALID'],
    ['semmaiuscula-2026', 'ADMIN_PASSWORD_WEAK'],
    ['SEMMINUSCULA-2026', 'ADMIN_PASSWORD_WEAK'],
    ['SemNumero-Forte', 'ADMIN_PASSWORD_WEAK'],
    ['SemSimbolo2026Ok', 'ADMIN_PASSWORD_WEAK'],
  ]
  for (const [value, code] of cases) {
    const error = assertThrows(() => validateOwnerPassword(value))
    assertEquals((error as Error).message, code)
    if (typeof value === 'string') assertEquals((error as Error).message.includes(value), false)
  }
})

Deno.test('only an active Owner manages passwords, never for Owners, itself or inactive members', () => {
  assertPasswordManagementAllowed(OWNER, MEMBER)
  for (const role of ['ADMIN', 'OPERATION', 'FINANCE']) {
    assertThrows(() => assertPasswordManagementAllowed({ ...OWNER, role }, MEMBER), Error, 'ADMIN_OWNER_REQUIRED')
  }
  assertThrows(() => assertPasswordManagementAllowed({ ...OWNER, isActive: false }, MEMBER), Error, 'ADMIN_OWNER_REQUIRED')
  assertThrows(() => assertPasswordManagementAllowed(OWNER, { ...MEMBER, id: OWNER.adminId }), Error, 'ADMIN_SELF_PASSWORD_FORBIDDEN')
  assertThrows(() => assertPasswordManagementAllowed(OWNER, { ...MEMBER, role: 'OWNER' }), Error, 'ADMIN_OWNER_PASSWORD_FORBIDDEN')
  assertThrows(() => assertPasswordManagementAllowed(OWNER, { ...MEMBER, is_active: false }), Error, 'ADMIN_TARGET_INACTIVE')
})

Deno.test('audit rows carry identifiers, operation and result only', () => {
  const row = passwordAuditRow('SET_PASSWORD', OWNER.adminId, MEMBER.id, 'SUCCESS')
  assertEquals(row, {
    admin_user_id: OWNER.adminId,
    entity_type: 'ADMIN_USER',
    entity_id: MEMBER.id,
    action: 'USER_PASSWORD_RESET_BY_OWNER',
    before_json: null,
    after_json: { operation: 'SET_PASSWORD', result: 'SUCCESS' },
    origin: 'ADMIN',
  })
  const failed = passwordAuditRow('SEND_PASSWORD_RECOVERY', OWNER.adminId, MEMBER.id, 'FAILED', 'ADMIN_PASSWORD_RECOVERY_SEND_FAILED')
  assertEquals(failed.action, 'USER_PASSWORD_RECOVERY_SENT')
  assertEquals(failed.after_json, { operation: 'SEND_PASSWORD_RECOVERY', result: 'FAILED', error_code: 'ADMIN_PASSWORD_RECOVERY_SEND_FAILED' })
  assertEquals(JSON.stringify(failed).includes('@'), false)
  assertEquals(passwordAuditAction('SET_PASSWORD'), 'USER_PASSWORD_RESET_BY_OWNER')
  assertEquals(passwordAuditAction('SEND_PASSWORD_RECOVERY'), 'USER_PASSWORD_RECOVERY_SENT')
})

Deno.test('rate limits fit the distributed limiter and cap recovery e-mails per member', () => {
  for (const policies of Object.values(PASSWORD_RATE_LIMITS)) {
    for (const policy of [policies.actor, policies.target]) {
      assertEquals(/^[A-Z0-9_]{3,64}$/.test(policy.scope), true)
      assertEquals(policy.limit >= 1 && policy.windowSeconds <= 86400, true)
    }
  }
  assertEquals(PASSWORD_RATE_LIMITS.SEND_PASSWORD_RECOVERY.target, { scope: 'OWNER_PASSWORD_RECOVERY_TARGET', limit: 1, windowSeconds: 300 })
})

Deno.test('maps Auth and policy failures to stable HTTP statuses', () => {
  assertEquals(authPasswordUpdateErrorCode({ status: 422, code: 'weak_password', message: 'Password is known to be weak' }), 'ADMIN_PASSWORD_WEAK')
  assertEquals(authPasswordUpdateErrorCode({ status: 500, message: 'Database error' }), 'ADMIN_AUTH_PASSWORD_UPDATE_FAILED')
  assertEquals(passwordErrorStatus('ADMIN_OWNER_REQUIRED'), 403)
  assertEquals(passwordErrorStatus('ADMIN_SELF_PASSWORD_FORBIDDEN'), 403)
  assertEquals(passwordErrorStatus('ADMIN_OWNER_PASSWORD_FORBIDDEN'), 403)
  assertEquals(passwordErrorStatus('ADMIN_PASSWORD_WEAK'), 422)
  assertEquals(passwordErrorStatus('RATE_LIMITED'), 429)
  assertEquals(passwordErrorStatus('ADMIN_PASSWORD_RECOVERY_SEND_FAILED'), 502)
  assertEquals(passwordErrorStatus('RATE_LIMIT_BACKEND_FAILED'), 503)
  assertEquals(passwordErrorStatus('ADMIN_TARGET_INACTIVE'), null)
})
