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
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) throw new Error('UUID_INVALID')
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
function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
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
      const [employees, services, google, mappings] = await Promise.all([
        client.rpc('admin_list_employees'),
        client.rpc('service_admin_list_service_settings'),
        client.from('google_calendars').select('id,name,is_active,google_connection_id,access_role').eq('is_active', true).order('name'),
        client.from('google_calendar_resources').select('google_calendar_id,resource_id'),
      ])
      if (employees.error) throw new Error(employees.error.message)
      if (services.error) throw new Error(services.error.message)
      if (google.error) throw new Error(google.error.message)
      if (mappings.error) throw new Error(mappings.error.message)
      const mappedByResource = new Map<string,string[]>()
      for (const row of mappings.data ?? []) {
        const list = mappedByResource.get(row.resource_id) ?? []
        list.push(row.google_calendar_id)
        mappedByResource.set(row.resource_id,list)
      }
      const employeeRows = (employees.data ?? []).map((employee: Record<string,unknown>) => ({
        ...employee,
        blocking_calendar_ids: typeof employee.resource_id === 'string' ? mappedByResource.get(employee.resource_id) ?? [] : [],
      }))
      return json({
        employees: employeeRows,
        services: (services.data ?? []).map((s: Record<string, unknown>) => ({ id: s.id, name: s.name, category_id: s.category_id, category_name: s.category_name, operation_scope: s.operation_scope, is_active: s.is_active })),
        google_calendars: (google.data ?? []).map((calendar) => ({ ...calendar, writable: calendar.access_role === 'writer' || calendar.access_role === 'owner' })),
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
    if (action === 'WRITE_CALENDAR' || action === 'CLEAR_WRITE_CALENDAR') {
      if (!(await hasAdminPermission(admin.adminId, 'INTEGRATIONS_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const serviceEmployeeId = uuid(body.service_employee_id)
      if (action === 'CLEAR_WRITE_CALENDAR') {
        const { data, error } = await client.rpc('admin_clear_service_employee_write_calendar_audited', { p_service_employee_id: serviceEmployeeId, p_admin_id: admin.adminId })
        if (error) throw new Error(error.message)
        return json(data)
      }
      const calendarId = uuid(body.google_calendar_id)
      const prefix = requiredEnv('GOOGLE_TEST_CALENDAR_PREFIX')
      const { data: calendar, error: calendarError } = await client.from('google_calendars').select('id,name,access_role,is_active').eq('id',calendarId).maybeSingle()
      if (calendarError || !calendar?.is_active) throw new Error('GOOGLE_CALENDAR_NOT_ACTIVE')
      if (!(calendar.access_role === 'writer' || calendar.access_role === 'owner')) throw new Error('GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED')
      if (!calendar.name.toLocaleUpperCase('pt-BR').startsWith(prefix.toLocaleUpperCase('pt-BR'))) throw new Error('GOOGLE_TEST_CALENDAR_PREFIX_REQUIRED')
      const { data, error } = await client.rpc('admin_set_service_employee_write_calendar_audited', { p_service_employee_id: serviceEmployeeId, p_google_calendar_id: calendarId, p_time_scope: text(body.time_scope).toUpperCase() || 'FULL_APPOINTMENT', p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    if (action === 'BLOCKING_CALENDAR_MAP' || action === 'BLOCKING_CALENDAR_UNMAP') {
      if (!(await hasAdminPermission(admin.adminId, 'INTEGRATIONS_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const employeeId = uuid(body.employee_id)
      const calendarId = uuid(body.google_calendar_id)
      const prefix = requiredEnv('GOOGLE_TEST_CALENDAR_PREFIX')
      const [{ data: employee, error: employeeError }, { data: calendar, error: calendarError }] = await Promise.all([
        client.from('employees').select('id,resource_id,is_active').eq('id', employeeId).maybeSingle(),
        client.from('google_calendars').select('id,name,is_active').eq('id', calendarId).maybeSingle(),
      ])
      if (employeeError || !employee?.is_active || !employee.resource_id) throw new Error('EMPLOYEE_RESOURCE_NOT_AVAILABLE')
      if (calendarError || !calendar?.is_active) throw new Error('GOOGLE_CALENDAR_NOT_ACTIVE')
      if (!calendar.name.toLocaleUpperCase('pt-BR').startsWith(prefix.toLocaleUpperCase('pt-BR'))) throw new Error('GOOGLE_TEST_CALENDAR_PREFIX_REQUIRED')
      if (action === 'BLOCKING_CALENDAR_MAP') {
        const { data, error } = await client.rpc('service_admin_add_google_calendar_resource_mapping', { p_google_calendar_id: calendarId, p_resource_id: employee.resource_id, p_admin_user_id: admin.adminId })
        if (error) throw new Error(error.message)
        return json(data)
      }
      const { data, error } = await client.rpc('service_admin_remove_google_calendar_resource_mapping', { p_google_calendar_id: calendarId, p_resource_id: employee.resource_id, p_admin_user_id: admin.adminId, p_reason: 'EMPLOYEE_ADMIN_UNMAP' })
      if (error) throw new Error(error.message)
      return json(data)
    }
    if (req.method === 'DELETE' || action === 'EXCEPTION_DELETE') {
      const { data, error } = await client.rpc('admin_remove_employee_exception_audited', { p_exception_id: uuid(body.exception_id), p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }
    throw new Error('EMPLOYEE_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'EMPLOYEE_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : code === 'ADMIN_PERMISSION_DENIED' ? 403 : code.startsWith('MISSING_ENV') ? 503 : 400
    return json({ error: { code } }, status)
  }
})
