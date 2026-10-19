// Owner password management (admin-team-member-access SET_PASSWORD / SEND_PASSWORD_RECOVERY)
// against a local Supabase stack: real Auth, real RBAC rows, served Edge Function.
// Every account here is a throwaway local fixture; nothing reaches production.
import { assert, assertEquals } from 'jsr:@std/assert@1'

const API_URL = requiredEnv('LOCAL_API_URL').replace(/\/+$/, '')
const ANON_KEY = requiredEnv('LOCAL_ANON_KEY')
const SERVICE_ROLE_KEY = requiredEnv('LOCAL_SERVICE_ROLE_KEY')
const MAIL_URL = (Deno.env.get('LOCAL_MAIL_URL') ?? '').replace(/\/+$/, '')
const RECOVERY_URL = 'https://www.blacksheepestudiocriativo.com.br/gestao/recuperar-senha'

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

type Member = { adminId: string; authUserId: string; email: string; password: string; role: string }
type Http = { status: number; text: string; body: Record<string, any> }

async function http(url: string, init: RequestInit): Promise<Http> {
  const response = await fetch(url, init)
  const text = await response.text()
  let body: Record<string, any> = {}
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    body = {}
  }
  return { status: response.status, text, body }
}

function serviceHeaders(extra: Record<string, string> = {}): HeadersInit {
  return { apikey: SERVICE_ROLE_KEY, authorization: `Bearer ${SERVICE_ROLE_KEY}`, 'content-type': 'application/json', ...extra }
}

function strongPassword(): string {
  return `Local-${crypto.randomUUID().slice(0, 8)}-Aa1!`
}

async function createMember(role: string, isActive: boolean, permissions: string[] = [], emailConfirmed = true): Promise<Member> {
  const email = `owner-pw-${role.toLowerCase()}-${crypto.randomUUID()}@example.test`
  const password = strongPassword()
  const created = await http(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: serviceHeaders(),
    body: JSON.stringify({ email, password, email_confirm: emailConfirmed }),
  })
  assert([200, 201].includes(created.status), `auth user must be created: ${created.status}`)
  const authUserId = String(created.body.id ?? created.body.user?.id ?? '')

  const row = await http(`${API_URL}/rest/v1/admin_users`, {
    method: 'POST',
    headers: serviceHeaders({ prefer: 'return=representation' }),
    body: JSON.stringify({ auth_user_id: authUserId, display_name: `Local ${role}`, role, is_active: isActive }),
  })
  assertEquals(row.status, 201, `admin_users row must be created: ${row.text}`)
  const adminId = String((row.body as unknown as Array<Record<string, unknown>>)[0].id)

  if (permissions.length) {
    const granted = await http(`${API_URL}/rest/v1/admin_user_permissions`, {
      method: 'POST',
      headers: serviceHeaders({ prefer: 'return=minimal' }),
      body: JSON.stringify(permissions.map((permission) => ({ admin_user_id: adminId, permission, is_granted: true }))),
    })
    assertEquals(granted.status, 201, `permissions must be granted: ${granted.text}`)
  }
  return { adminId, authUserId, email, password, role }
}

async function signIn(email: string, password: string): Promise<Http> {
  return http(`${API_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
}

async function accessToken(member: Member): Promise<string> {
  const session = await signIn(member.email, member.password)
  assertEquals(session.status, 200, `${member.role} must sign in`)
  return String(session.body.access_token)
}

async function passwordAction(token: string, action: string, memberId: string, password?: string): Promise<Http> {
  return http(`${API_URL}/functions/v1/admin-team-member-access`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ action, member_id: memberId, ...(password === undefined ? {} : { password }) }),
  })
}

async function snapshot(member: Member) {
  const [row, permissions, user] = await Promise.all([
    http(`${API_URL}/rest/v1/admin_users?id=eq.${member.adminId}&select=id,auth_user_id,display_name,role,is_active`, { headers: serviceHeaders() }),
    http(`${API_URL}/rest/v1/admin_user_permissions?admin_user_id=eq.${member.adminId}&select=permission,is_granted&order=permission`, { headers: serviceHeaders() }),
    http(`${API_URL}/auth/v1/admin/users/${member.authUserId}`, { headers: serviceHeaders() }),
  ])
  return {
    row: row.body,
    permissions: permissions.body,
    email: user.body.email,
    role: user.body.role,
    appMetadata: user.body.app_metadata,
    userMetadata: user.body.user_metadata,
    banned: user.body.banned_until ?? null,
  }
}

async function auditRows(memberId: string): Promise<Array<Record<string, any>>> {
  const rows = await http(
    `${API_URL}/rest/v1/audit_logs?entity_id=eq.${memberId}&action=in.(USER_PASSWORD_RESET_BY_OWNER,USER_PASSWORD_RECOVERY_SENT)&select=admin_user_id,entity_id,action,before_json,after_json,origin&order=created_at`,
    { headers: serviceHeaders() },
  )
  assertEquals(rows.status, 200)
  return rows.body as unknown as Array<Record<string, any>>
}

const owner = await createMember('OWNER', true)
const otherOwner = await createMember('OWNER', true)
const admin = await createMember('ADMIN', true, ['TEAM_MANAGE'])
const operation = await createMember('OPERATION', true, ['AGENDA_VIEW'])
const finance = await createMember('FINANCE', true, ['FINANCE_VIEW'])
const target = await createMember('OPERATION', true, ['AGENDA_VIEW', 'CUSTOMERS_VIEW'])
const recoveryTarget = await createMember('FINANCE', true, ['FINANCE_VIEW'])
const inactive = await createMember('OPERATION', false, ['AGENDA_VIEW'])
const pendingInvite = await createMember('OPERATION', true, ['AGENDA_VIEW'], false)
const ownerToken = await accessToken(owner)

Deno.test('ADMIN (even with TEAM_MANAGE), OPERATION and FINANCE cannot run either action through the API', async () => {
  for (const actor of [admin, operation, finance]) {
    const token = await accessToken(actor)
    const set = await passwordAction(token, 'SET_PASSWORD', target.adminId, strongPassword())
    assertEquals([set.status, set.body.error?.code], [403, 'ADMIN_OWNER_REQUIRED'], `${actor.role} must not set passwords`)
    const send = await passwordAction(token, 'SEND_PASSWORD_RECOVERY', target.adminId)
    assertEquals([send.status, send.body.error?.code], [403, 'ADMIN_OWNER_REQUIRED'], `${actor.role} must not send recovery`)
  }
  assertEquals((await signIn(target.email, target.password)).status, 200, 'target password is untouched')
  assertEquals(await auditRows(target.adminId), [])
})

Deno.test('requests without a valid session are rejected', async () => {
  const anonymous = await passwordAction(ANON_KEY, 'SET_PASSWORD', target.adminId, strongPassword())
  assertEquals(anonymous.status, 401)
})

Deno.test('the Owner cannot change another Owner, itself or an inactive member', async () => {
  const other = await passwordAction(ownerToken, 'SET_PASSWORD', otherOwner.adminId, strongPassword())
  assertEquals([other.status, other.body.error?.code], [403, 'ADMIN_OWNER_PASSWORD_FORBIDDEN'])
  const self = await passwordAction(ownerToken, 'SET_PASSWORD', owner.adminId, strongPassword())
  assertEquals([self.status, self.body.error?.code], [403, 'ADMIN_SELF_PASSWORD_FORBIDDEN'])
  const selfRecovery = await passwordAction(ownerToken, 'SEND_PASSWORD_RECOVERY', owner.adminId)
  assertEquals([selfRecovery.status, selfRecovery.body.error?.code], [403, 'ADMIN_SELF_PASSWORD_FORBIDDEN'])
  const disabled = await passwordAction(ownerToken, 'SET_PASSWORD', inactive.adminId, strongPassword())
  assertEquals([disabled.status, disabled.body.error?.code], [409, 'ADMIN_TARGET_INACTIVE'])
  const disabledRecovery = await passwordAction(ownerToken, 'SEND_PASSWORD_RECOVERY', inactive.adminId)
  assertEquals([disabledRecovery.status, disabledRecovery.body.error?.code], [409, 'ADMIN_TARGET_INACTIVE'])
  const missing = await passwordAction(ownerToken, 'SET_PASSWORD', crypto.randomUUID(), strongPassword())
  assertEquals([missing.status, missing.body.error?.code], [404, 'ADMIN_USER_NOT_FOUND'])
  assertEquals((await signIn(otherOwner.email, otherOwner.password)).status, 200)
  assertEquals((await signIn(inactive.email, inactive.password)).status, 200, 'inactive fixture password is untouched')
})

Deno.test('a pending invitee cannot get a password, only the recovery e-mail that confirms the address', async () => {
  const before = await snapshot(pendingInvite)
  const set = await passwordAction(ownerToken, 'SET_PASSWORD', pendingInvite.adminId, strongPassword())
  assertEquals([set.status, set.body.error?.code], [409, 'ADMIN_PASSWORD_INVITE_PENDING'])
  assertEquals(await snapshot(pendingInvite), before)
  assertEquals(await auditRows(pendingInvite.adminId), [])

  const send = await passwordAction(ownerToken, 'SEND_PASSWORD_RECOVERY', pendingInvite.adminId)
  assertEquals(send.status, 200, send.text)
  assertEquals(send.body.recovery_email_sent, true)
})

Deno.test('invalid passwords are rejected and never echoed', async () => {
  for (const [password, code] of [
    ['Curta-1a', 'ADMIN_PASSWORD_TOO_SHORT'],
    ['semmaiuscula-2026', 'ADMIN_PASSWORD_WEAK'],
    ['Aa1!' + 'é'.repeat(40), 'ADMIN_PASSWORD_TOO_LONG'],
  ]) {
    const response = await passwordAction(ownerToken, 'SET_PASSWORD', target.adminId, password)
    assertEquals([response.status, response.body.error?.code], [422, code])
    assertEquals(response.text.includes(password), false)
  }
  assertEquals((await signIn(target.email, target.password)).status, 200)
})

Deno.test('the Owner sets a new password: old one stops working, new one signs in, nothing else changes', async () => {
  const before = await snapshot(target)
  const oldSession = await signIn(target.email, target.password)
  assertEquals(oldSession.status, 200)

  const newPassword = strongPassword()
  const response = await passwordAction(ownerToken, 'SET_PASSWORD', target.adminId, newPassword)
  assertEquals(response.status, 200, response.text)
  assertEquals(response.body, { member_id: target.adminId, password_updated: true })
  assertEquals(response.text.includes(newPassword), false)

  assertEquals((await signIn(target.email, target.password)).status, 400, 'old password must stop working')
  assertEquals((await signIn(target.email, newPassword)).status, 200, 'new password must sign in')
  assertEquals(await snapshot(target), before, 'role, permissions, e-mail and metadata stay intact')

  // Supabase revokes the member's refresh tokens on an admin password change, so
  // old sessions cannot renew; an access token already issued lives until it expires.
  const refreshed = await http(`${API_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ refresh_token: oldSession.body.refresh_token }),
  })
  assertEquals(refreshed.status, 400, `old refresh token must be revoked: ${refreshed.text}`)

  const audit = await auditRows(target.adminId)
  assertEquals(audit, [{
    admin_user_id: owner.adminId,
    entity_id: target.adminId,
    action: 'USER_PASSWORD_RESET_BY_OWNER',
    before_json: null,
    after_json: { operation: 'SET_PASSWORD', result: 'SUCCESS' },
    origin: 'ADMIN',
  }])
  assertEquals(JSON.stringify(audit).includes(newPassword), false)
})

Deno.test('the Owner sends a recovery e-mail once per window, through Auth, to the recovery page', async () => {
  const before = await snapshot(recoveryTarget)
  const response = await passwordAction(ownerToken, 'SEND_PASSWORD_RECOVERY', recoveryTarget.adminId)
  assertEquals(response.status, 200, response.text)
  assertEquals(response.body.member_id, recoveryTarget.adminId)
  assertEquals(response.body.recovery_email_sent, true)
  assert(!/token|access_token|verify|http/i.test(response.text), 'no link or token in the response')

  const again = await passwordAction(ownerToken, 'SEND_PASSWORD_RECOVERY', recoveryTarget.adminId)
  assertEquals([again.status, again.body.error?.code], [429, 'RATE_LIMITED'])

  assertEquals(await snapshot(recoveryTarget), before, 'sending recovery changes nothing on the account')
  assertEquals((await signIn(recoveryTarget.email, recoveryTarget.password)).status, 200, 'password unchanged until the member acts')

  const audit = await auditRows(recoveryTarget.adminId)
  assertEquals(audit.map((row) => [row.action, row.admin_user_id, row.after_json]), [
    ['USER_PASSWORD_RECOVERY_SENT', owner.adminId, { operation: 'SEND_PASSWORD_RECOVERY', result: 'SUCCESS' }],
  ])
  assertEquals(JSON.stringify(audit).includes('@'), false)

  if (MAIL_URL) {
    let link = ''
    for (let attempt = 0; attempt < 20 && !link; attempt += 1) {
      const list = await http(`${MAIL_URL}/api/v1/search?query=${encodeURIComponent(`to:${recoveryTarget.email}`)}`, {})
      const id = list.body.messages?.[0]?.ID
      if (id) {
        const message = await http(`${MAIL_URL}/api/v1/message/${id}`, {})
        link = (String(message.body.HTML ?? message.body.Text ?? '').match(/https?:\/\/[^"'\s<>]+verify[^"'\s<>]+/) ?? [''])[0].replaceAll('&amp;', '&')
      }
      if (!link) await new Promise((resolve) => setTimeout(resolve, 500))
    }
    assert(link, 'the recovery e-mail must reach the member mailbox')
    const verifyUrl = new URL(link)
    assertEquals(verifyUrl.searchParams.get('type'), 'recovery')
    assertEquals(verifyUrl.searchParams.get('redirect_to'), RECOVERY_URL)

    const opened = await fetch(link, { redirect: 'manual' })
    await opened.body?.cancel()
    const location = opened.headers.get('location') ?? ''
    assert(location.startsWith(`${RECOVERY_URL}#`), `the link must open the recovery page: ${location.split('#')[0]}`)
    const fragment = new URLSearchParams(location.split('#')[1] ?? '')
    assertEquals(fragment.get('type'), 'recovery')
    assert((fragment.get('access_token') ?? '').length > 40, 'the recovery page receives a recovery session')
  }
})
