import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  assertSafeCustomHtml,
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, OPTIONS',
}

const events = [
  'APPOINTMENT_APPROVED', 'APPOINTMENT_PENDING', 'APPOINTMENT_REJECTED', 'APPOINTMENT_CANCELLED',
  'APPOINTMENT_CHANGED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_REMINDER', 'WAITLIST_AVAILABLE', 'BIRTHDAY',
  'RENTAL_BALANCE_DUE', 'ADMIN_USER_INVITE', 'PRE_RESERVATION_CREATED', 'REFUND_FAILED', 'MANUAL',
]
const channels = ['EMAIL', 'GOOGLE_CALENDAR']
const audiences = ['CUSTOMER', 'EMPLOYEE']
const variables = [
  'appointment.public_code', 'appointment.start_at', 'appointment.end_at', 'appointment.duration',
  'customer.name', 'customer.email', 'employee.name', 'auth.invite_url', 'service.name', 'service.description',
  'operation.name', 'operation.email', 'operation.phone', 'operation.address', 'operation.site_url',
  'payment.total', 'payment.paid', 'payment.balance', 'payment.status', 'extras.summary',
  'coupon.code', 'coupon.discount', 'coupon.expires_at',
  'balance.amount', 'balance.expires_at', 'balance.payment_url',
  'pre_reservation.expires_at', 'pre_reservation.payment_url',
  'refund.amount', 'refund.error_code',
]
const financialVariables = new Set([
  'payment.total', 'payment.paid', 'payment.balance', 'payment.status', 'coupon.discount', 'balance.amount', 'refund.amount',
])

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
function positiveInteger(value: string | null, fallback: number): number {
  const next = Number(value ?? fallback)
  return Number.isInteger(next) && next > 0 ? next : fallback
}
function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value as Record<string, unknown>[] : []
}

function testValues(recipient: string, brandName: string): Record<string, string> {
  return {
    'appointment.public_code': 'TESTE-1234',
    'appointment.start_at': '30/08/2026 14:00',
    'appointment.end_at': '30/08/2026 15:00',
    'appointment.duration': '60 min',
    'customer.name': 'Teste BlackSheep',
    'customer.email': recipient,
    'employee.name': 'Equipe BlackSheep',
    'auth.invite_url': 'https://www.blacksheepestudiocriativo.com.br/gestao/primeiro-acesso',
    'service.name': 'Serviço de teste',
    'service.description': 'Descrição de exemplo para conferir a apresentação do e-mail.',
    'operation.name': brandName,
    'operation.email': recipient,
    'operation.phone': '(48) 0000-0000',
    'operation.address': 'Palhoça/SC',
    'operation.site_url': 'https://www.blacksheepestudiocriativo.com.br',
    'payment.total': 'R$ 1.000,00',
    'payment.paid': 'R$ 500,00',
    'payment.balance': 'R$ 500,00',
    'payment.status': 'PAGO PARCIALMENTE',
    'extras.summary': 'Adicional de teste × 1',
    'coupon.code': 'TESTE50',
    'coupon.discount': 'R$ 500,00',
    'coupon.expires_at': '30/09/2026',
    'balance.amount': 'R$ 500,00',
    'balance.expires_at': '30/08/2026 16:00',
    'balance.payment_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/saldo?collection=teste',
    'pre_reservation.expires_at': '30/08/2026 16:00',
    'pre_reservation.payment_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/pagamento?pre_reservation=teste',
    'refund.amount': 'R$ 500,00',
    'refund.error_code': 'REFUND_TEST',
  }
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

      if (url.searchParams.get('view') === 'history') {
        const page = positiveInteger(url.searchParams.get('page'), 1)
        const limit = Math.min(positiveInteger(url.searchParams.get('limit'), 50), 100)
        const status = text(url.searchParams.get('status'), true)?.toUpperCase() ?? null
        const eventKey = text(url.searchParams.get('event_key'), true)?.toUpperCase() ?? null
        if (status !== null && !['PENDING', 'SENT', 'FAILED', 'SKIPPED'].includes(status)) throw new Error('NOTIFICATION_STATUS_INVALID')
        if (eventKey !== null && !events.includes(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
        const { data, error } = await client.rpc('service_admin_list_notification_delivery_logs', {
          p_channel: 'EMAIL',
          p_status: status,
          p_event_key: eventKey,
          p_limit: limit,
          p_offset: (page - 1) * limit,
        })
        if (error) throw new Error(error.message)
        const deliveries = data ?? []
        const total = Number(deliveries[0]?.total_count ?? 0)
        return json({
          deliveries: deliveries.map((item: Record<string, unknown>) => {
            const { total_count: _totalCount, ...safe } = item
            return safe
          }),
          pagination: { page, limit, total, total_pages: Math.ceil(total / limit) },
        })
      }

      const templateId = url.searchParams.get('template_id')
      if (templateId) {
        const { data, error } = await client.rpc('service_admin_notification_template_versions', { p_template_id: uuid(templateId) })
        if (error) throw new Error(error.message)
        return json({ versions: data ?? [] })
      }
      const [templates, services, categories] = await Promise.all([
        client.rpc('service_admin_list_notification_templates_v2'),
        client.rpc('service_admin_list_service_settings'),
        client.rpc('service_admin_list_categories'),
      ])
      if (templates.error) throw new Error(templates.error.message)
      if (services.error) throw new Error(services.error.message)
      if (categories.error) throw new Error(categories.error.message)
      return json({
        templates: templates.data ?? [],
        services: records(services.data).map((service) => ({
          id: service.id, name: service.name, operation_scope: service.operation_scope, category_id: service.category_id, is_active: service.is_active,
        })),
        categories: records(categories.data).map((category) => ({
          id: category.id, name: category.name, operation_scope: category.operation_scope, is_active: category.is_active,
        })),
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

    if (req.method === 'POST' && String(record.action ?? '').toUpperCase() === 'TEST') {
      const templateId = uuid(record.template_id) as string
      const { data: template, error: templateError } = await client
        .from('notification_template_configs')
        .select('id,event_key,channel,audience,operation_scope,category_id,title_template,body_template,html_template,is_active,variable_schema')
        .eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (template.channel !== 'EMAIL') throw new Error('NOTIFICATION_TEST_EMAIL_ONLY')
      const requestedVariables = Array.isArray(template.variable_schema) ? template.variable_schema.map((item: unknown) => String(item)) : []
      if (requestedVariables.some((item: string) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
        throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
      }

      let scope = String(template.operation_scope ?? '').trim().toUpperCase()
      if (!scope && template.category_id) {
        const { data: categoryRows, error: categoryError } = await client.rpc('service_admin_list_categories')
        if (categoryError) throw new Error(categoryError.message)
        const category = records(categoryRows).find((item) => String(item.id ?? '') === String(template.category_id))
        scope = String(category?.operation_scope ?? '').trim().toUpperCase()
      }
      if (!scope) {
        const { data: binding } = await client.from('notification_template_services').select('service_id').eq('template_id', templateId).limit(1).maybeSingle()
        if (binding?.service_id) {
          const { data: serviceRows, error: serviceError } = await client.rpc('service_admin_list_service_settings')
          if (serviceError) throw new Error(serviceError.message)
          const service = records(serviceRows).find((item) => String(item.id ?? '') === String(binding.service_id))
          scope = String(service?.operation_scope ?? '').trim().toUpperCase()
        }
      }
      if (!['BLACKSHEEP', 'SABRINA'].includes(scope)) scope = 'BLACKSHEEP'
      const sender = notificationSenderForScope(scope)
      if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

      const { data: authUser, error: authUserError } = await client.auth.admin.getUserById(admin.authUserId)
      if (authUserError || !authUser.user) throw new Error('ADMIN_TEST_RECIPIENT_LOOKUP_FAILED')
      const recipient = normalizedEmail(authUser.user.email)
      if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) throw new Error('ADMIN_TEST_RECIPIENT_INVALID')

      const message = renderNotificationMessage(template as NotificationTemplate, testValues(recipient, sender.brandName), sender.brandName)
      const idempotencyKey = `notification-test:${templateId}:${crypto.randomUUID()}`
      const delivery = await beginNotificationDelivery(client, {
        templateId,
        eventKey: String(template.event_key),
        audience: template.audience === 'EMPLOYEE' ? 'EMPLOYEE' : 'CUSTOMER',
        recipient,
        idempotencyKey,
        isTest: true,
        payloadSnapshot: { template_id: templateId, operation_scope: scope, test: true },
      })
      const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
      if (sender.replyTo) payload.reply_to = sender.replyTo
      try {
        const providerMessageId = await sendEmailWithProvider(payload, idempotencyKey)
        await markNotificationSent(client, delivery.id, providerMessageId)
        return json({ sent: true, template_id: templateId, recipient_masked: maskEmail(recipient), provider_message_id: providerMessageId })
      } catch (sendError) {
        await markNotificationFailed(client, delivery.id, sendError)
        throw sendError
      }
    }

    const eventKey = (text(record.event_key) as string).toUpperCase()
    const channel = (text(record.channel) as string).toUpperCase()
    const audience = (text(record.audience) as string).toUpperCase()
    const operationScope = text(record.operation_scope, true)?.toUpperCase() ?? null
    const htmlTemplate = typeof record.html_template === 'string' ? record.html_template.trim() || null : null
    if (!events.includes(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
    if (!channels.includes(channel)) throw new Error('NOTIFICATION_CHANNEL_INVALID')
    if (!audiences.includes(audience)) throw new Error('NOTIFICATION_AUDIENCE_INVALID')
    if (operationScope !== null && !['SABRINA', 'BLACKSHEEP'].includes(operationScope)) throw new Error('NOTIFICATION_OPERATION_SCOPE_INVALID')
    assertSafeCustomHtml(htmlTemplate)
    const requestedVariables = Array.isArray(record.variable_schema) ? record.variable_schema.map((item) => text(item) as string) : []
    if (requestedVariables.some((item) => !variables.includes(item))) throw new Error('NOTIFICATION_VARIABLE_INVALID')
    if (requestedVariables.some((item) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
      throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
    }

    const { data, error } = await client.rpc('service_admin_upsert_notification_template_v2', {
      p_template_id: uuid(record.template_id, true),
      p_event_key: eventKey,
      p_channel: channel,
      p_audience: audience,
      p_operation_scope: operationScope,
      p_category_id: uuid(record.category_id, true),
      p_title_template: text(record.title_template),
      p_body_template: typeof record.body_template === 'string' ? record.body_template : '',
      p_html_template: htmlTemplate,
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
        : code.includes('PROVIDER_') || code.startsWith('EMAIL_')
          ? 502
          : 400
    return json({ error: { code } }, status)
  }
})
