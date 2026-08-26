import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, OPTIONS',
}

const events = [
  'APPOINTMENT_APPROVED', 'APPOINTMENT_PENDING', 'APPOINTMENT_REJECTED', 'APPOINTMENT_CANCELLED',
  'APPOINTMENT_CHANGED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_REMINDER', 'WAITLIST_AVAILABLE', 'BIRTHDAY', 'MANUAL',
]
const channels = ['EMAIL', 'GOOGLE_CALENDAR']
const audiences = ['CUSTOMER', 'EMPLOYEE']
const variables = [
  'appointment.public_code', 'appointment.start_at', 'appointment.end_at',
  'customer.name', 'customer.email', 'employee.name', 'service.name', 'service.description',
  'operation.name', 'operation.email', 'operation.phone', 'operation.address', 'operation.site_url',
  'payment.total', 'payment.status', 'extras.summary', 'coupon.code', 'coupon.discount', 'coupon.expires_at',
]
const financialVariables = new Set(['payment.total', 'payment.status', 'coupon.discount'])

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } })
}
function text(value: unknown, nullable = false): string | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  if (typeof value !== 'string' || !value.trim()) throw new Error('NOTIFICATION_TEXT_INVALID')
  return value.trim()
}
function uuid(value: unknown, nullable = false): string | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const next = text(value) as string
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) throw new Error('UUID_INVALID')
  return next
}
function uuidArray(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('NOTIFICATION_SERVICES_INVALID')
  return value.map((item) => uuid(item) as string)
}
function integer(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null
  const next = Number(value)
  if (!Number.isInteger(next) || next < 0) throw new Error('NOTIFICATION_REMINDER_OFFSET_INVALID')
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const canViewFinance = await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE')
      const url = new URL(req.url)
      const templateId = url.searchParams.get('template_id')
      if (templateId) {
        const { data, error } = await client.rpc('service_admin_notification_template_versions', { p_template_id: uuid(templateId) })
        if (error) throw new Error(error.message)
        return json({ versions: data ?? [] })
      }
      const [templates, services, categories] = await Promise.all([
        client.rpc('service_admin_list_notification_templates'),
        client.rpc('service_admin_list_service_settings'),
        client.from('categories').select('id,name,operation_scope,is_active').order('operation_scope').order('name'),
      ])
      if (templates.error) throw new Error(templates.error.message)
      if (services.error) throw new Error(services.error.message)
      if (categories.error) throw new Error(categories.error.message)
      return json({
        templates: templates.data ?? [],
        services: (services.data ?? []).map((service: Record<string, unknown>) => ({
          id: service.id, name: service.name, operation_scope: service.operation_scope, category_id: service.category_id, is_active: service.is_active,
        })),
        categories: categories.data ?? [],
        options: {
          events,
          channels,
          audiences,
          variables: canViewFinance ? variables : variables.filter((item) => !financialVariables.has(item)),
        },
      })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('NOTIFICATION_PAYLOAD_INVALID')
    const record = body as Record<string, unknown>
    const eventKey = (text(record.event_key) as string).toUpperCase()
    const channel = (text(record.channel) as string).toUpperCase()
    const audience = (text(record.audience) as string).toUpperCase()
    const operationScope = text(record.operation_scope, true)?.toUpperCase() ?? null
    if (!events.includes(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
    if (!channels.includes(channel)) throw new Error('NOTIFICATION_CHANNEL_INVALID')
    if (!audiences.includes(audience)) throw new Error('NOTIFICATION_AUDIENCE_INVALID')
    if (operationScope !== null && !['SABRINA', 'BLACKSHEEP'].includes(operationScope)) throw new Error('NOTIFICATION_OPERATION_SCOPE_INVALID')
    const requestedVariables = Array.isArray(record.variable_schema) ? record.variable_schema.map((item) => text(item) as string) : []
    if (requestedVariables.some((item) => !variables.includes(item))) throw new Error('NOTIFICATION_VARIABLE_INVALID')
    if (requestedVariables.some((item) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
      throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
    }

    const { data, error } = await client.rpc('service_admin_upsert_notification_template', {
      p_template_id: uuid(record.template_id, true),
      p_event_key: eventKey,
      p_channel: channel,
      p_audience: audience,
      p_operation_scope: operationScope,
      p_category_id: uuid(record.category_id, true),
      p_title_template: text(record.title_template),
      p_body_template: typeof record.body_template === 'string' ? record.body_template : '',
      p_is_active: record.is_active === true,
      p_variable_schema: requestedVariables,
      p_reminder_offset_minutes: integer(record.reminder_offset_minutes),
      p_service_ids: uuidArray(record.service_ids ?? []),
      p_actor_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json({ id: data }, req.method === 'POST' ? 201 : 200)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'NOTIFICATION_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_FINANCE_PERMISSION_REQUIRED'
        ? 403
        : 400
    return json({ error: { code } }, status)
  }
})
