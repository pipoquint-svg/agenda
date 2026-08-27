import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

const allowedPermissions = new Set([
  'DASHBOARD_VIEW',
  'AGENDA_VIEW','AGENDA_MANAGE',
  'CUSTOMERS_VIEW','CUSTOMERS_MANAGE',
  'FINANCE_VIEW','FINANCE_MANAGE',
  'PACKAGES_VIEW','PACKAGES_MANAGE',
  'SERVICES_VIEW','SERVICES_MANAGE',
  'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE',
  'AUDIT_VIEW','TEAM_MANAGE',
])

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

function targetIdFromPath(pathname: string): string | null {
  const match = pathname.match(/\/admin-team-members\/([^/]+)\/permissions\/?$/)
  return match ? match[1] : null
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
    current.push({
      permission: row.permission,
      is_granted: row.is_granted,
      updated_by_admin_id: row.updated_by_admin_id,
      updated_at: row.updated_at,
    })
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
    security: {
      session_tokens_exposed: false,
      password_data_exposed: false,
    },
  })
}

async function updatePermissions(req: Request, targetRaw: string): Promise<Response> {
  const actor = await requireAdminPermission(req, 'TEAM_MANAGE')
  const targetAdminId = uuid(targetRaw, 'ADMIN_USER_ID_INVALID')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  if (!Array.isArray(body.permissions) || body.permissions.length < 1 || body.permissions.length > allowedPermissions.size) {
    throw new Error('ADMIN_PERMISSIONS_REQUIRED')
  }

  const normalized = body.permissions.map((item) => {
    const row = item && typeof item === 'object' ? item as Record<string, unknown> : {}
    const permission = typeof row.permission === 'string' ? row.permission.trim().toUpperCase() : ''
    if (!allowedPermissions.has(permission)) throw new Error('ADMIN_PERMISSION_INVALID')
    if (typeof row.is_granted !== 'boolean') throw new Error('ADMIN_PERMISSION_VALUE_INVALID')
    return { permission, is_granted: row.is_granted }
  })

  const unique = new Set(normalized.map((row) => row.permission))
  if (unique.size !== normalized.length) throw new Error('ADMIN_PERMISSION_DUPLICATE')

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const url = new URL(req.url)
    const targetAdminId = targetIdFromPath(url.pathname)
    if (req.method === 'GET' && url.pathname.replace(/\/+$/, '').endsWith('/admin-team-members')) return await listMembers(req)
    if (req.method === 'PUT' && targetAdminId) return await updatePermissions(req, targetAdminId)
    if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    return json({ error: { code: 'NOT_FOUND' } }, 404)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_TEAM_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'ADMIN_USER_NOT_FOUND' ? 404 : 400
    return json({ error: { code } }, status)
  }
})
