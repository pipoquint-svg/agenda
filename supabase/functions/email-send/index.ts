import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { senderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}
function isEnabled(): boolean { return envEnabled('TRANSACTIONAL_EMAIL_ENABLED') }
function allowRealRecipients(): boolean { return envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS') }

function numeric(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}
function money(value: unknown): string {
  return numeric(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}
function dateTime(value: unknown): string {
  const parsed = new Date(String(value ?? ''))
  if (Number.isNaN(parsed.getTime())) return String(value ?? '')
  return new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Sao_Paulo' }).format(parsed)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  let deliveryLogId: string | null = null
  try {
    requireInternal(req)
    const body = await req.json()
    const appointmentId = String(body.appointment_id ?? '').trim()
    const entityVersion = Number(body.entity_version)
    const reason = String(body.reason ?? 'CONFIRMED').trim().toUpperCase()
    if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
    if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')
    if (!isEnabled()) return jsonResponse({ stale: false, skipped: true, reason: 'TRANSACTIONAL_EMAIL_DISABLED' })

    const client = adminClient()
    const { data: appointment, error: appointmentError } = await client
      .from('appointments')
      .select('id, public_code, service_id, primary_customer_id, status, financial_status, start_at, end_at, duration_minutes, commercial_value, version, service_name_snapshot, service_description_snapshot')
      .eq('id', appointmentId).maybeSingle()
    if (appointmentError) throw new Error('APPOINTMENT_LOOKUP_FAILED')
    if (!appointment) throw new Error('APPOINTMENT_NOT_FOUND')

    const currentVersion = Number(appointment.version)
    if (entityVersion < currentVersion) return jsonResponse({ stale: true, current_version: currentVersion, appointment_id: appointmentId })
    if (entityVersion > currentVersion) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')
    if (appointment.status !== 'CONFIRMED') return jsonResponse({ stale: false, skipped: true, reason: 'APPOINTMENT_NOT_CONFIRMED' })

    const { data: service, error: serviceError } = await client.from('services').select('id,name,full_description,operation_scope').eq('id', appointment.service_id).maybeSingle()
    if (serviceError || !service) throw new Error('SERVICE_LOOKUP_FAILED')
    const scope = String(service.operation_scope ?? '').trim().toUpperCase()
    if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_SCOPE_DISABLED', operation_scope: scope })

    const sender = senderForScope(scope)
    if (!sender) return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_SCOPE_SENDER_NOT_CONFIGURED', operation_scope: scope })
    if (!appointment.primary_customer_id) return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_CUSTOMER_MISSING' })

    const { data: customer, error: customerError } = await client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle()
    if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')
    const recipient = normalizedEmail(customer.email)
    if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' })
    if (!isRecipientAllowed(recipient, allowRealRecipients(), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) {
      return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_RECIPIENT_NOT_ALLOWLISTED', recipient_masked: maskEmail(recipient) })
    }

    const eventKey = 'APPOINTMENT_APPROVED'
    const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
      p_event_key: eventKey, p_channel: 'EMAIL', p_audience: 'CUSTOMER', p_service_id: appointment.service_id,
    })
    if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
    const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
    if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')

    const [{ data: financial, error: financialError }, { data: extras }, { data: discount }, { data: operationSettings }] = await Promise.all([
      client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId }),
      client.from('appointment_extras').select('name_snapshot,quantity').eq('appointment_id', appointmentId),
      client.from('appointment_discounts').select('code_snapshot,calculated_discount_amount').eq('appointment_id', appointmentId).maybeSingle(),
      client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope }),
    ])
    if (financialError) throw new Error('FINANCIAL_SUMMARY_FAILED')

    const values: Record<string, string> = {
      'appointment.public_code': String(appointment.public_code ?? ''),
      'appointment.start_at': dateTime(appointment.start_at),
      'appointment.end_at': dateTime(appointment.end_at),
      'appointment.duration': `${Math.max(0, Math.round(numeric(appointment.duration_minutes)))} min`,
      'customer.name': String(customer.name ?? ''),
      'customer.email': recipient,
      'employee.name': '',
      'service.name': String(appointment.service_name_snapshot ?? service.name ?? ''),
      'service.description': String(appointment.service_description_snapshot ?? service.full_description ?? ''),
      'operation.name': String(operationSettings?.public_name ?? sender.brandName),
      'operation.email': String(operationSettings?.public_email ?? ''),
      'operation.phone': String(operationSettings?.public_phone ?? ''),
      'operation.address': String(operationSettings?.public_address ?? ''),
      'operation.site_url': String(operationSettings?.public_site_url ?? ''),
      'payment.total': money(appointment.commercial_value),
      'payment.paid': money(financial?.contract_settled),
      'payment.balance': money(financial?.contract_balance),
      'payment.status': String(appointment.financial_status ?? ''),
      'extras.summary': (extras ?? []).map((item: any) => `${item.name_snapshot} × ${item.quantity}`).join(', '),
      'coupon.code': String(discount?.code_snapshot ?? ''),
      'coupon.discount': money(discount?.calculated_discount_amount ?? 0),
    }
    const message = renderNotificationMessage(template, values, sender.brandName)
    const providerIdempotencyKey = `notification:${template.id}:${appointmentId}:v${entityVersion}:EMAIL:CUSTOMER`
    const delivery = await beginNotificationDelivery(client, {
      templateId: template.id,
      eventKey,
      audience: 'CUSTOMER',
      appointmentId,
      customerId: customer.id,
      recipient,
      idempotencyKey: providerIdempotencyKey,
      payloadSnapshot: { template_id: template.id, appointment_id: appointmentId, entity_version: entityVersion, operation_scope: scope },
    })
    deliveryLogId = delivery.id
    if (delivery.alreadySent) {
      return jsonResponse({ stale: false, skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', provider_message_id: delivery.providerMessageId })
    }

    const providerPayload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    try {
      const providerMessageId = await sendEmailWithProvider(providerPayload, providerIdempotencyKey)
      await markNotificationSent(client, deliveryLogId, providerMessageId)
      return jsonResponse({ stale: false, skipped: false, appointment_id: appointmentId, entity_version: entityVersion, reason, operation_scope: scope, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: template.id })
    } catch (sendError) {
      await markNotificationFailed(client, deliveryLogId, sendError)
      throw sendError
    }
  } catch (error) {
    const code = error instanceof Error ? error.message : 'TRANSACTIONAL_EMAIL_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
