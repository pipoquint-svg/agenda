import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } })
}
function text(value: unknown) { return typeof value === 'string' ? value.trim() : '' }
function uuid(value: unknown): string {
  const next = text(value)
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error('UUID_INVALID')
  return next
}
function uuidArray(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('UUID_ARRAY_INVALID')
  return value.map((item) => uuid(item))
}
function timestamp(value: unknown): string {
  const next = text(value)
  if (!next || Number.isNaN(Date.parse(next))) throw new Error('TIMESTAMP_INVALID')
  return new Date(next).toISOString()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  try {
    const admin = await requireAdmin(req)
    const canView = await hasAdminPermission(admin.adminId, 'SERVICES_VIEW')
    if (!canView) throw new Error('ADMIN_PERMISSION_DENIED')
    const client = adminClient()

    if (req.method === 'GET') {
      const [employees, services, google] = await Promise.all([
        client.rpc('admin_list_employees'),
        client.rpc('service_admin_list_service_settings'),
        client.from('google_calendars').select('id,name,is_active,google_connection_id').eq('is_active', true).order('name'),
      ])
      if (employees.error) throw new Error(employees.error.message)
      if (services.error) throw new Error(services.error.message)
      if (google.error) throw new Error(google.error.message)
      return json({
        employees: employees.data ?? [],
        services: (services.data ?? []).map((s: Record<string, unknown>) => ({ id: s.id, name: s.name, category_id: s.category_id, category_name: s.category_name, operation_scope: s.operation_scope, is_active: s.is_active })),
        google_calendars: google.data ?? [],
      })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('EMPLOYEE_PAYLOAD_INVALID')
    const action = text(body.action || (req.method === 'POST' ? 'CREATE' : '')).toUpperCase()

    if (req.method === 'POST' && action === 'CREATE') {
      const { data, error } = await client.rpc('admin_create_employee_audited', { p_name: text(body.name), p_email: text(body.email) || null, p_phone: text(body.phone) || null, p_notes: text(body.notes) || null, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }
    if (action === 'UPDATE') {
      const { data, error } = await client.rpc('admin_update_employee_audited', { p_employee_id: uuid(body.employee_id), p_name: text(body.name), p_email: text(body.email) || null, p_phone: text(body.phone) || null, p_notes: text(body.notes) || null, p_is_active: body.is_active !== false, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    if (action === 'SERVICES') {
      const { data, error } = await client.rpc('admin_replace_employee_services_audited', { p_employee_id: uuid(body.employee_id), p_service_ids: uuidArray(body.service_ids ?? []), p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    if (action === 'WORK_HOURS') {
      if (!Array.isArray(body.rules)) throw new Error('WORK_HOURS_INVALID')
      const { data, error } = await client.rpc('admin_replace_work_hours_audited', { p_service_employee_id: uuid(body.service_employee_id), p_rules: body.rules, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    if (action === 'EXCEPTION_ADD') {
      const { data, error } = await client.rpc('admin_add_employee_exception_audited', { p_service_employee_id: uuid(body.service_employee_id), p_exception_type: text(body.exception_type).toUpperCase(), p_start_at: timestamp(body.start_at), p_end_at: timestamp(body.end_at), p_reason: text(body.reason) || null, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }
    if (req.method === 'DELETE' || action === 'EXCEPTION_DELETE') {
      const { data, error } = await client.rpc('admin_remove_employee_exception_audited', { p_exception_id: uuid(body.exception_id), p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    throw new Error('EMPLOYEE_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'EMPLOYEE_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
