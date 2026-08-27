import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown, code = 'RESOURCE_ID_INVALID'): string {
  if (typeof value !== 'string') throw new Error(code)
  const next = value.trim()
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error(code)
  }
  return next
}

function rules(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error('RESOURCE_AVAILABILITY_RULES_INVALID')
  return value
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function timestamp(value: unknown): string {
  const next = text(value)
  if (!next || Number.isNaN(Date.parse(next))) throw new Error('RESOURCE_EXCEPTION_TIMESTAMP_INVALID')
  return new Date(next).toISOString()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) {
    return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  }

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

    if (req.method === 'PUT') {
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
    }

    const action = text(record.action).toUpperCase()

    if (req.method === 'POST' && action === 'EXCEPTION_ADD') {
      const resourceId = uuid(record.resource_id)
      const exceptionType = text(record.exception_type).toUpperCase()
      const startAt = timestamp(record.start_at)
      const endAt = timestamp(record.end_at)
      const reason = text(record.reason) || null

      const { data, error } = await client.rpc('service_admin_add_resource_exception_audited', {
        p_resource_id: resourceId,
        p_exception_type: exceptionType,
        p_start_at: startAt,
        p_end_at: endAt,
        p_reason: reason,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }

    if (req.method === 'DELETE' && action === 'EXCEPTION_DELETE') {
      const exceptionId = uuid(record.exception_id, 'RESOURCE_EXCEPTION_ID_INVALID')
      const { data, error } = await client.rpc('service_admin_remove_resource_exception_audited', {
        p_exception_id: exceptionId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('RESOURCE_SETTINGS_ACTION_INVALID')
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
