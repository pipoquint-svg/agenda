import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown): string {
  if (typeof value !== 'string') throw new Error('RESOURCE_ID_INVALID')
  const next = value.trim()
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('RESOURCE_ID_INVALID')
  }
  return next
}

function rules(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error('RESOURCE_AVAILABILITY_RULES_INVALID')
  return value
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) {
        throw new Error('ADMIN_PERMISSION_DENIED')
      }

      const { data, error } = await client.rpc('service_admin_list_resource_settings')
      if (error) throw new Error(error.message)
      return json({ resources: Array.isArray(data) ? data : [] })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) {
      throw new Error('ADMIN_PERMISSION_DENIED')
    }

    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      throw new Error('RESOURCE_SETTINGS_PAYLOAD_INVALID')
    }
    const record = body as Record<string, unknown>
    const keys = Object.keys(record)
    if (keys.length !== 2 || !keys.includes('resource_id') || !keys.includes('rules')) {
      throw new Error('RESOURCE_SETTINGS_PAYLOAD_INVALID')
    }

    const resourceId = uuid(record.resource_id)
    const normalizedRules = rules(record.rules)

    const { data, error } = await client.rpc('service_admin_replace_resource_availability_audited', {
      p_resource_id: resourceId,
      p_rules: normalizedRules,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)

    return json({ resource_id: resourceId, availability_rules: Array.isArray(data) ? data : [] })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'RESOURCE_SETTINGS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
        ? 403
        : 400
    return json({ error: { code } }, status)
  }
})
