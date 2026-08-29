import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, PUT, OPTIONS',
}

const allowedPermissions = new Set([
  'DASHBOARD_VIEW',
  'AGENDA_VIEW','AGENDA_MANAGE',
  'CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW',
  'FINANCE_VIEW','FINANCE_MANAGE',
  'PACKAGES_VIEW','PACKAGES_MANAGE',
  'SERVICES_VIEW','SERVICES_MANAGE',
  'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE',
  'LEADS_VIEW','LEADS_MANAGE',
  'AUDIT_VIEW','TEAM_MANAGE',
])
const creatableRoles = new Set(['ADMIN', 'OPERATION', 'FINANCE'])
const INVITE_EVENT = 'ADMIN_USER_INVITE'
const OFFICIAL_SITE_URL = 'https://www.blacksheepestudiocriativo.com.br'

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function uuid(value: unknown, code: string): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)) throw new Error(code)
  return text
}

function email(value: unknown): string {
  const text = normalizedEmail(typeof value === 'string' ? value : '')
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text) || text.length > 254) throw new Error('ADMIN_EMAIL_INVALID')
  return text
}

function password(value: unknown): string {
  const text = typeof value === 'string' ? value : ''
  if (text.length < 12 || text.length > 128) throw new Error('ADMIN_TEMPORARY_PASSWORD_INVALID')
  return text
}

function permissionTargetFromPath(pathname: string): string | null {
  const match = pathname.match(/\/admin-team-members\/([^/]+)\/permissions\/?$/)
  return match ? match[1] : null
}

function statusTargetFromPath(pathname: string): string | null {
  const match = pathname.match(/\/admin-team-members\/([^/]+)\/status\/?$/)
  return match ? match[1] : null
}

function firstAccessUrl(): string {
  const url = new URL(OFFICIAL_SITE_URL)
  url.pathname = '/gestao/primeiro-acesso'
  url.search = ''
  url.hash = ''
  return url.toString()
}

async function listMembers(req: Request): Promise<Response> {
  await requireAdminPermission(req, 'TEAM_MANAGE')
  const client = adminClient()
  const [{ data: admins, error: adminsError }, { data: overrides, error: overridesError }, authUsersResult] = await Promise.all([
    client.from('admin_users').select('id,auth_user_id,display_name,role,is_active,created_at,updated_at').order('display_name'),
    client.from('admin_user_permissions').select('admin_user_id,permission,is_granted,updated_by_admin_id,updated_at').order('permission'),
    client.auth.admin.listUsers({ page: 1, perPage: 1000 }),
  ])

  if (adminsError) throw new Error('ADMIN_TEAM_USERS_QUERY_FAILED')
  if (overridesError) throw new Error('ADMIN_TEAM_PERMISSIONS_QUERY_FAILED')
  if (authUsersResult.error) throw new Error('ADMIN_TEAM_AUTH_QUERY_FAILED')

  const authById = new Map((authUsersResult.data?.users ?? []).map((user) => [user.id, user]))
  const overridesByAdmin = new Map<string, Array<Record<string, unknown>>>()
  for (const row of overrides ?? []) {
    const key = String(row.admin_user_id)
    const current = overridesByAdmin.get(key) ?? []
    current.push({ permission: row.permission, is_granted: row.is_granted, updated_by_admin_id: row.updated_by_admin_id, updated_at: row.updated_at })
    overridesByAdmin.set(key, current)
  }

  const profiles = await Promise.all((admins ?? []).map(async (admin) => {
    const { data, error } = await client.rpc('service_admin_get_access_profile', { p_admin_id: admin.id })
    if (error) throw new Error('ADMIN_TEAM_PROFILE_QUERY_FAILED')
    return [String(admin.id), data] as const
  }))
  const profileById = new Map(profiles)

  return json({
    members: (admins ?? []).map((admin) => {
      const authUser = authById.get(String(admin.auth_user_id))
      const profile = profileById.get(String(admin.id)) as Record<string, unknown> | null
      return {
        id: admin.id,
        auth_user_id: admin.auth_user_id,
        display_name: admin.display_name,
        email: authUser?.email ?? null,
        role: admin.role,
        is_active: admin.is_active,
        created_at: admin.created_at,
        updated_at: admin.updated_at,
        email_confirmed_at: authUser?.email_confirmed_at ?? null,
        last_sign_in_at: authUser?.last_sign_in_at ?? null,
        permissions: profile?.permissions ?? {},
        permission_overrides: overridesByAdmin.get(String(admin.id)) ?? [],
      }
    }),
    security: { session_tokens_exposed: false, password_data_exposed: false },
  })
}

async function removeUnusedInviteUser(client: ReturnType<typeof adminClient>, authUserId: string, adminUserId: string | null): Promise<void> {
  if (adminUserId) await client.from('admin_users').delete().eq('id', adminUserId)
  await client.auth.admin.deleteUser(authUserId).catch(() => undefined)
}

async function createMember(req: Request, body: Record<string, unknown>): Promise<Response> {
  const actor = await requireAdminPermission(req, 'TEAM_MANAGE')
  const displayName = typeof body.display_name === 'string' ? body.display_name.trim() : ''
  const memberEmail = email(body.email)
  const role = typeof body.role === 'string' ? body.role.trim().toUpperCase() : ''

  if (displayName.length < 2 || displayName.length > 120) throw new Error('ADMIN_DISPLAY_NAME_INVALID')
  if (!creatableRoles.has(role)) throw new Error('ADMIN_ROLE_INVALID')

  const client = adminClient()
  const [{ data: template, error: templateError }, { data: operationSettings, error: operationError }] = await Promise.all([
    client.from('notification_template_configs')
      .select('id,event_key,title_template,body_template,variable_schema,operation_scope,is_active')
      .eq('event_key', INVITE_EVENT)
      .eq('channel', 'EMAIL')
      .eq('audience', 'EMPLOYEE')
      .eq('operation_scope', 'BLACKSHEEP')
      .eq('is_active', true)
      .is('category_id', null)
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: 'BLACKSHEEP' }),
  ])
  if (templateError || !template) throw new Error('ADMIN_INVITE_TEMPLATE_NOT_FOUND')
  if (operationError) throw new Error('ADMIN_INVITE_OPERATION_SETTINGS_FAILED')

  const redirectTo = firstAccessUrl()
  const sender = notificationSenderForScope('BLACKSHEEP')
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

  const { data: linkData, error: linkError } = await client.auth.admin.generateLink({
    type: 'invite',
    email: memberEmail,
    options: {
      redirectTo,
      data: { display_name: displayName },
    },
  })
  if (linkError || !linkData?.user || !linkData?.properties?.action_link) {
    const authMessage = linkError?.message?.toLowerCase() ?? ''
    if (authMessage.includes('already') || authMessage.includes('registered') || authMessage.includes('exists')) throw new Error('ADMIN_EMAIL_ALREADY_REGISTERED')
    throw new Error('ADMIN_INVITE_LINK_CREATE_FAILED')
  }

  const authUserId = linkData.user.id
  let adminUserId: string | null = null
  let deliveryLogId: string | null = null
  let providerSucceeded = false

  try {
    const { data: profile, error: registerError } = await client.rpc('service_admin_register_admin_user', {
      p_auth_user_id: authUserId,
      p_display_name: displayName,
      p_role: role,
      p_actor_admin_id: actor.adminId,
    })
    if (registerError) throw new Error(registerError.message || 'ADMIN_USER_REGISTER_FAILED')

    const { data: adminRow, error: adminLookupError } = await client.from('admin_users').select('id').eq('auth_user_id', authUserId).maybeSingle()
    if (adminLookupError || !adminRow) throw new Error('ADMIN_USER_REGISTER_LOOKUP_FAILED')
    adminUserId = String(adminRow.id)

    const values: Record<string, string> = {
      'employee.name': displayName,
      'auth.invite_url': linkData.properties.action_link,
      'operation.name': String(operationSettings?.public_name ?? sender.brandName),
      'operation.site_url': OFFICIAL_SITE_URL,
    }
    const message = renderNotificationMessage(template as NotificationTemplate, values, sender.brandName)
    const idempotencyKey = `admin-user-invite:${authUserId}`
    const delivery = await beginNotificationDelivery(client, {
      templateId: String(template.id),
      eventKey: INVITE_EVENT,
      audience: 'EMPLOYEE',
      recipient: memberEmail,
      idempotencyKey,
      payloadSnapshot: { admin_user_id: adminUserId, role, operation_scope: 'BLACKSHEEP' },
    })
    deliveryLogId = delivery.id

    const providerPayload: EmailProviderPayload = {
      from: sender.from,
      to: [memberEmail],
      subject: message.subject,
      text: message.text,
      html: message.html,
    }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    const providerMessageId = await sendEmailWithProvider(providerPayload, idempotencyKey)
    providerSucceeded = true
    try {
      await markNotificationSent(client, deliveryLogId, providerMessageId)
    } catch (logError) {
      console.error('Admin invite was sent but delivery finalization failed', {
        admin_user_id: adminUserId,
        code: logError instanceof Error ? logError.message : 'NOTIFICATION_DELIVERY_LOG_SENT_FAILED',
      })
    }

    return json({
      member: {
        id: adminUserId,
        auth_user_id: authUserId,
        display_name: displayName,
        email: memberEmail,
        role,
        is_active: true,
        permissions: (profile as Record<string, unknown> | null)?.permissions ?? {},
      },
      invite_email_sent: true,
      recipient_masked: maskEmail(memberEmail),
      password_returned: false,
    }, 201)
  } catch (error) {
    if (deliveryLogId && !providerSucceeded) await markNotificationFailed(client, deliveryLogId, error)
    if (!providerSucceeded) await removeUnusedInviteUser(client, authUserId, adminUserId)
    throw error
  }
}

async function transferOwner(req: Request, body: Record<string, unknown>): Promise<Response> {
  const actor = await requireAdminPermission(req, 'TEAM_MANAGE')
  const targetEmail = email(body.email)
  const temporaryPassword = password(body.temporary_password)
  const displayName = typeof body.display_name === 'string' && body.display_name.trim() ? body.display_name.trim() : 'Pipo Quint'
  const client = adminClient()

  const { data: actorRow, error: actorError } = await client.from('admin_users').select('id,role,is_active').eq('id', actor.adminId).maybeSingle()
  if (actorError || !actorRow) throw new Error('ADMIN_USER_NOT_FOUND')
  if (!actorRow.is_active || actorRow.role !== 'OWNER') throw new Error('ADMIN_OWNER_REQUIRED')

  const authUsersResult = await client.auth.admin.listUsers({ page: 1, perPage: 1000 })
  if (authUsersResult.error) throw new Error('ADMIN_TEAM_AUTH_QUERY_FAILED')
  let authUser = (authUsersResult.data?.users ?? []).find((user) => user.email?.toLowerCase() === targetEmail) ?? null
  let createdAuthUser = false

  if (!authUser) {
    const { data, error } = await client.auth.admin.createUser({ email: targetEmail, password: temporaryPassword, email_confirm: true })
    if (error || !data.user) throw new Error('ADMIN_AUTH_USER_CREATE_FAILED')
    authUser = data.user
    createdAuthUser = true
  }

  try {
    let { data: targetAdmin, error: targetError } = await client
      .from('admin_users')
      .select('id,auth_user_id,display_name,role,is_active')
      .eq('auth_user_id', authUser.id)
      .maybeSingle()

    if (targetError) throw new Error('ADMIN_TARGET_QUERY_FAILED')
    if (targetAdmin && !targetAdmin.is_active) throw new Error('ADMIN_TARGET_INACTIVE')

    if (!targetAdmin) {
      const { error: registerError } = await client.rpc('service_admin_register_admin_user', {
        p_auth_user_id: authUser.id,
        p_display_name: displayName,
        p_role: 'ADMIN',
        p_actor_admin_id: actor.adminId,
      })
      if (registerError) throw new Error(registerError.message || 'ADMIN_USER_REGISTER_FAILED')

      const lookup = await client.from('admin_users').select('id,auth_user_id,display_name,role,is_active').eq('auth_user_id', authUser.id).maybeSingle()
      if (lookup.error || !lookup.data) throw new Error('ADMIN_TARGET_QUERY_FAILED')
      targetAdmin = lookup.data
    }

    const { data: transfer, error: transferError } = await client.rpc('service_admin_transfer_owner', {
      p_target_admin_id: targetAdmin.id,
      p_actor_admin_id: actor.adminId,
    })
    if (transferError) throw new Error(transferError.message || 'ADMIN_OWNER_TRANSFER_FAILED')

    return json({
      transferred: true,
      email: targetEmail,
      auth_user_created: createdAuthUser,
      temporary_password_returned: false,
      transfer,
    })
  } catch (error) {
    if (createdAuthUser && authUser) await client.auth.admin.deleteUser(authUser.id).catch(() => undefined)
    throw error
  }
}

async function updatePermissions(req: Request, targetRaw: string): Promise<Response> {
  const actor = await requireAdminPermission(req, 'TEAM_MANAGE')
  const targetAdminId = uuid(targetRaw, 'ADMIN_USER_ID_INVALID')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  if (!Array.isArray(body.permissions) || body.permissions.length < 1 || body.permissions.length > allowedPermissions.size) throw new Error('ADMIN_PERMISSIONS_REQUIRED')

  const normalized = body.permissions.map((item) => {
    const row = item && typeof item === 'object' ? item as Record<string, unknown> : {}
    const permission = typeof row.permission === 'string' ? row.permission.trim().toUpperCase() : ''
    if (!allowedPermissions.has(permission)) throw new Error('ADMIN_PERMISSION_INVALID')
    if (typeof row.is_granted !== 'boolean') throw new Error('ADMIN_PERMISSION_VALUE_INVALID')
    return { permission, is_granted: row.is_granted }
  })
  if (new Set(normalized.map((row) => row.permission)).size !== normalized.length) throw new Error('ADMIN_PERMISSION_DUPLICATE')

  const client = adminClient()
  let profile: unknown = null
  for (const change of normalized) {
    const { data, error } = await client.rpc('service_admin_set_permission', {
      p_target_admin_id: targetAdminId,
      p_permission: change.permission,
      p_is_granted: change.is_granted,
      p_actor_admin_id: actor.adminId,
    })
    if (error) throw new Error(error.message || 'ADMIN_PERMISSION_UPDATE_FAILED')
    profile = data
  }
  return json({ member_id: targetAdminId, profile })
}

async function updateStatus(req: Request, targetRaw: string): Promise<Response> {
  const actor = await requireAdminPermission(req, 'TEAM_MANAGE')
  const targetAdminId = uuid(targetRaw, 'ADMIN_USER_ID_INVALID')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  if (body.is_active !== false) throw new Error('ADMIN_STATUS_VALUE_INVALID')

  const client = adminClient()
  const { data, error } = await client.rpc('service_admin_deactivate_admin_user', {
    p_target_admin_id: targetAdminId,
    p_actor_admin_id: actor.adminId,
  })
  if (error) throw new Error(error.message || 'ADMIN_USER_DEACTIVATE_FAILED')

  const result = data && typeof data === 'object' ? data as Record<string, unknown> : {}
  const authUserId = typeof result.auth_user_id === 'string' ? result.auth_user_id : ''
  if (!authUserId) throw new Error('ADMIN_USER_AUTH_ID_MISSING')

  const { error: banError } = await client.auth.admin.updateUserById(authUserId, { ban_duration: '876000h' })
  if (banError) throw new Error('ADMIN_AUTH_BAN_FAILED')

  return json({ member_id: targetAdminId, is_active: false, access_revoked: true })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const url = new URL(req.url)
    const root = url.pathname.replace(/\/+$/, '').endsWith('/admin-team-members')
    const permissionTarget = permissionTargetFromPath(url.pathname)
    const statusTarget = statusTargetFromPath(url.pathname)
    if (req.method === 'GET' && root) return await listMembers(req)
    if (req.method === 'POST' && root) {
      const body = await req.json().catch(() => ({})) as Record<string, unknown>
      const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : 'CREATE'
      if (action === 'TRANSFER_OWNER') return await transferOwner(req, body)
      if (action === 'CREATE') return await createMember(req, body)
      throw new Error('ADMIN_TEAM_ACTION_INVALID')
    }
    if (req.method === 'PUT' && permissionTarget) return await updatePermissions(req, permissionTarget)
    if (req.method === 'PUT' && statusTarget) return await updateStatus(req, statusTarget)
    if (!['GET', 'POST', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_TEAM_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_OWNER_REQUIRED' ? 403
      : code === 'ADMIN_USER_NOT_FOUND' || code === 'ADMIN_TARGET_NOT_FOUND' ? 404
      : code === 'ADMIN_EMAIL_ALREADY_REGISTERED' ? 409
      : code === 'ADMIN_SELF_DEACTIVATION_FORBIDDEN' || code === 'ADMIN_OWNER_DEACTIVATION_FORBIDDEN' ? 409
      : code.includes('EMAIL_PROVIDER_') || code === 'EMAIL_SCOPE_SENDER_NOT_CONFIGURED' ? 502
      : code === 'ADMIN_AUTH_BAN_FAILED' ? 502
      : 400
    return json({ error: { code } }, status)
  }
})
