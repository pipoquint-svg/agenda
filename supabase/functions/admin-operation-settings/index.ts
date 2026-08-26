import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

const operationScopes = new Set(['SABRINA', 'BLACKSHEEP'])

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function assertExactKeys(body: Record<string, unknown>, allowed: string[]) {
  const keys = Object.keys(body)
  if (keys.length !== allowed.length || keys.some((key) => !allowed.includes(key))) {
    throw new Error('OPERATION_SETTINGS_PAYLOAD_INVALID')
  }
}

function nullableUuid(value: unknown): string | null {
  if (value === null) return null
  if (typeof value !== 'string') throw new Error('OCCUPANCY_RESOURCE_ID_INVALID')
  const next = value.trim()
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('OCCUPANCY_RESOURCE_ID_INVALID')
  }
  return next
}

function operationScope(value: unknown): 'SABRINA' | 'BLACKSHEEP' {
  if (typeof value !== 'string') throw new Error('OPERATION_SCOPE_INVALID')
  const next = value.trim().toUpperCase()
  if (!operationScopes.has(next)) throw new Error('OPERATION_SCOPE_INVALID')
  return next as 'SABRINA' | 'BLACKSHEEP'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()
    const url = new URL(req.url)

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) {
        throw new Error('ADMIN_PERMISSION_DENIED')
      }

      const requestedScope = url.searchParams.get('operation_scope')
      if (requestedScope !== null) {
        const scope = operationScope(requestedScope)
        const { data, error } = await client.rpc('service_admin_get_operation_settings_v2', {
          p_operation_scope: scope,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      // Backward-compatible singleton read used by the existing dashboard occupancy UI.
      const { data, error } = await client.rpc('service_admin_get_operation_settings')
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) {
      throw new Error('ADMIN_PERMISSION_DENIED')
    }

    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      throw new Error('OPERATION_SETTINGS_PAYLOAD_INVALID')
    }

    const record = body as Record<string, unknown>

    if ('operation_scope' in record || 'patch' in record) {
      assertExactKeys(record, ['operation_scope', 'patch'])
      const scope = operationScope(record.operation_scope)
      if (!record.patch || typeof record.patch !== 'object' || Array.isArray(record.patch)) {
        throw new Error('OPERATION_SETTINGS_PATCH_INVALID')
      }

      const { data, error } = await client.rpc('service_admin_update_operation_settings_v2', {
        p_operation_scope: scope,
        p_patch: record.patch,
        p_actor_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    // Backward-compatible singleton mutation used only by dashboard occupancy settings.
    assertExactKeys(record, ['dashboard_occupancy_resource_id'])
    const resourceId = nullableUuid(record.dashboard_occupancy_resource_id)

    const { data, error } = await client.rpc('service_admin_set_dashboard_occupancy_resource', {
      p_resource_id: resourceId,
      p_actor_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json(data)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'OPERATION_SETTINGS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_FINANCE_PERMISSION_REQUIRED'
        ? 403
        : 400
    return json({ error: { code } }, status)
  }
})
