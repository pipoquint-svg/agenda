import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  templateVariableKeys,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

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
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(parsed)
}

async function resolveTemplate(
  client: any,
  eventKey: string,
  audience: 'CUSTOMER' | 'EMPLOYEE',
  serviceId: string,
): Promise<NotificationTemplate> {
  const { data: rows, error } = await client.rpc('resolve_notification_template_v2', {
    p_event_key: eventKey,
    p_channel: 'EMAIL',
    p_audience: audience,
    p_service_id: serviceId,
  })
  if (error) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
  const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
  if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
  return template
}

async function sendRefundFailedNotification(client: any, body: Record<string, unknown>) {
  const appointmentId = String(body.appointment_id ?? '').trim()
  const policyActionId = String(body.policy_action_id ?? '').trim()
  const actorAuthUserId = String(body.actor_auth_user_id ?? '').trim()
  const errorCode = String(body.error_code ?? 'REFUND_FAILED').trim().slice(0, 120)
  const refundAmount = numeric(body.refund_amount)
  if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
  if (!policyActionId) throw new Error('POLICY_ACTION_ID_REQUIRED')
  if (!actorAuthUserId) throw new Error('ACTOR_AUTH_USER_ID_REQUIRED')

  const [{ data: appointment, error: appointmentError }, { data: actorData, error: actorError }] = await Promise.all([
    client.from('appointments').select('id,public_code,service_id').eq('id', appointmentId).maybeSingle(),
    client.auth.admin.getUserById(actorAuthUserId),
  ])
  if (appointmentError || !appointment) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (actorError || !actorData?.user) throw new Error('ADMIN_EMAIL_LOOKUP_FAILED')

  const { data: service, error: serviceError } = await client
    .from('services').select('id,operation_scope').eq('id', appointment.service_id).maybeSingle()
  if (serviceError || !service) throw new Error('SERVICE_LOOKUP_FAILED')

  const scope = String(service.operation_scope ?? '').trim().toUpperCase()
  const sender = notificationSenderForScope(scope)
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
  const recipient = normalizedEmail(actorData.user.email)
  if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
    return jsonResponse({ skipped: true, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' })
  }

  const eventKey = 'REFUND_FAILED'
  const template = await resolveTemplate(client, eventKey, 'EMPLOYEE', appointment.service_id)
  const { data: operationSettings } = await client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope })
  const values: Record<string, string> = {
    'appointment.public_code': String(appointment.public_code ?? ''),
    'refund.amount': money(refundAmount),
    'refund.error_code': errorCode,
    'operation.name': String(operationSettings?.public_name ?? sender.brandName),
  }
  const providerIdempotencyKey = `notification:${template.id}:${policyActionId}:${errorCode}:EMAIL:EMPLOYEE`
  const delivery = await beginNotificationDelivery(client, {
    templateId: template.id,
    eventKey,
    audience: 'EMPLOYEE',
    appointmentId,
    recipient,
    idempotencyKey: providerIdempotencyKey,
    payloadSnapshot: { template_id: template.id, appointment_id: appointmentId, policy_action_id: policyActionId, error_code: errorCode, refund_amount: refundAmount, operation_scope: scope },
  })
  if (delivery.alreadySent) return jsonResponse({ skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', provider_message_id: delivery.providerMessageId })

  const message = renderNotificationMessage(template, values, sender.brandName)
  const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
  if (sender.replyTo) payload.reply_to = sender.replyTo
  try {
    const providerMessageId = await sendEmailWithProvider(payload, providerIdempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)
    return jsonResponse({ skipped: false, reason: eventKey, appointment_id: appointmentId, policy_action_id: policyActionId, operation_scope: scope, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: template.id })
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}

async function sendRefundCompletedNotification(client: any, body: Record<string, unknown>) {
  const appointmentId = String(body.appointment_id ?? '').trim()
  const policyActionId = String(body.policy_action_id ?? '').trim()
  const refundAmount = numeric(body.refund_amount)
  if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
  if (!policyActionId) throw new Error('POLICY_ACTION_ID_REQUIRED')
  if (refundAmount <= 0) throw new Error('REFUND_AMOUNT_REQUIRED')

  const { data: appointment, error: appointmentError } = await client
    .from('appointments').select('id,public_code,service_id,primary_customer_id').eq('id', appointmentId).maybeSingle()
  if (appointmentError || !appointment) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (!appointment.primary_customer_id) return jsonResponse({ skipped: true, reason: 'EMAIL_CUSTOMER_MISSING' })

  const [{ data: service, error: serviceError }, { data: customer, error: customerError }] = await Promise.all([
    client.from('services').select('id,operation_scope').eq('id', appointment.service_id).maybeSingle(),
    client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle(),
  ])
  if (serviceError || !service) throw new Error('SERVICE_LOOKUP_FAILED')
  if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')

  const scope = String(service.operation_scope ?? '').trim().toUpperCase()
  const sender = notificationSenderForScope(scope)
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
  const recipient = normalizedEmail(customer.email)
  if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
    return jsonResponse({ skipped: true, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' })
  }

  const eventKey = 'REFUND_COMPLETED'
  const template = await resolveTemplate(client, eventKey, 'CUSTOMER', appointment.service_id)
  const { data: operationSettings } = await client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope })
  const values: Record<string, string> = {
    'appointment.public_code': String(appointment.public_code ?? ''),
    'customer.name': String(customer.name ?? ''),
    'refund.amount': money(refundAmount),
    'operation.name': String(operationSettings?.public_name ?? sender.brandName),
  }
  const providerIdempotencyKey = `notification:${template.id}:${policyActionId}:EMAIL:CUSTOMER`
  const delivery = await beginNotificationDelivery(client, {
    templateId: template.id,
    eventKey,
    audience: 'CUSTOMER',
    appointmentId,
    customerId: customer.id,
    recipient,
    idempotencyKey: providerIdempotencyKey,
    payloadSnapshot: { template_id: template.id, appointment_id: appointmentId, policy_action_id: policyActionId, refund_amount: refundAmount, operation_scope: scope },
  })
  if (delivery.alreadySent) return jsonResponse({ skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', provider_message_id: delivery.providerMessageId })

  const message = renderNotificationMessage(template, values, sender.brandName)
  const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
  if (sender.replyTo) payload.reply_to = sender.replyTo
  try {
    const providerMessageId = await sendEmailWithProvider(payload, providerIdempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)
    return jsonResponse({ skipped: false, reason: eventKey, appointment_id: appointmentId, policy_action_id: policyActionId, operation_scope: scope, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: template.id })
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}

async function sendAppointmentConfirmation(client: any, body: Record<string, unknown>) {
  const appointmentId = String(body.appointment_id ?? '').trim()
  const entityVersion = Number(body.entity_version)
  const reason = String(body.reason ?? 'CONFIRMED').trim().toUpperCase()
  if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
  if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')

  const { data: appointment, error: appointmentError } = await client
    .from('appointments')
    .select('id,public_code,service_id,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,commercial_value,version,service_name_snapshot,service_description_snapshot')
    .eq('id', appointmentId).maybeSingle()
  if (appointmentError) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (!appointment) throw new Error('APPOINTMENT_NOT_FOUND')

  const currentVersion = Number(appointment.version)
  if (entityVersion < currentVersion) return jsonResponse({ stale: true, current_version: currentVersion, appointment_id: appointmentId })
  if (entityVersion > currentVersion) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')
  if (appointment.status !== 'CONFIRMED') return jsonResponse({ stale: false, skipped: true, reason: 'APPOINTMENT_NOT_CONFIRMED' })
  if (!appointment.primary_customer_id) return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_CUSTOMER_MISSING' })

  const [{ data: service, error: serviceError }, { data: customer, error: customerError }] = await Promise.all([
    client.from('services').select('id,name,full_description,operation_scope').eq('id', appointment.service_id).maybeSingle(),
    client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle(),
  ])
  if (serviceError || !service) throw new Error('SERVICE_LOOKUP_FAILED')
  if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')

  const scope = String(service.operation_scope ?? '').trim().toUpperCase()
  const sender = notificationSenderForScope(scope)
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
  const recipient = normalizedEmail(customer.email)
  if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
    return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' })
  }

  const eventKey = 'APPOINTMENT_APPROVED'
  const template = await resolveTemplate(client, eventKey, 'CUSTOMER', appointment.service_id)
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
  if (delivery.alreadySent) return jsonResponse({ stale: false, skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', provider_message_id: delivery.providerMessageId })

  try {
    const [{ data: financial, error: financialError }, { data: extras, error: extrasError }, { data: discount, error: discountError }, { data: operationSettings }] = await Promise.all([
      client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId }),
      client.from('appointment_extras').select('name_snapshot,quantity').eq('appointment_id', appointmentId),
      client.from('appointment_discounts').select('code_snapshot,calculated_discount_amount').eq('appointment_id', appointmentId).maybeSingle(),
      client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope }),
    ])
    if (financialError) throw new Error('FINANCIAL_SUMMARY_FAILED')
    if (extrasError) throw new Error('APPOINTMENT_EXTRAS_LOOKUP_FAILED')
    if (discountError) throw new Error('APPOINTMENT_DISCOUNT_LOOKUP_FAILED')

    let manageUrl = ''
    let tokenId: string | null = null
    const requestedVariables = templateVariableKeys(template.variable_schema)
    if (requestedVariables.has('appointment.manage_url')) {
      const requestId = `confirmation-email:${appointmentId}:v${entityVersion}`
      const { data: tokenResult, error: tokenError } = await client.rpc('service_issue_appointment_action_token', {
        p_appointment_id: appointmentId,
        p_scope: 'RESCHEDULE',
        p_channel: 'EMAIL',
        p_destination_masked: maskEmail(recipient),
        p_request_id: requestId,
      })
      if (tokenError || !tokenResult?.access_token || !tokenResult?.token_id) throw new Error('APPOINTMENT_MANAGE_TOKEN_ISSUE_FAILED')
      tokenId = String(tokenResult.token_id)
      manageUrl = `https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token=${encodeURIComponent(String(tokenResult.access_token))}&scope=RESCHEDULE`
    }

    const values: Record<string, string> = {
      'appointment.public_code': String(appointment.public_code ?? ''),
      'appointment.start_at': dateTime(appointment.start_at),
      'appointment.end_at': dateTime(appointment.end_at),
      'appointment.duration': `${Math.max(0, Math.round(numeric(appointment.duration_minutes)))} min`,
      'appointment.manage_url': manageUrl,
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
    const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
    if (sender.replyTo) payload.reply_to = sender.replyTo

    const providerMessageId = await sendEmailWithProvider(payload, providerIdempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)

    if (tokenId) {
      const { error: tokenDeliveryError } = await client.rpc('service_record_appointment_token_delivery', {
        p_token_id: tokenId,
        p_channel: 'EMAIL',
        p_destination_masked: maskEmail(recipient),
        p_request_id: `confirmation-email:${appointmentId}:v${entityVersion}`,
        p_provider_message_id: providerMessageId,
      })
      if (tokenDeliveryError) console.error('APPOINTMENT_TOKEN_DELIVERY_RECORD_FAILED')
    }

    return jsonResponse({ stale: false, skipped: false, appointment_id: appointmentId, entity_version: entityVersion, reason, operation_scope: scope, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: template.id })
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  try {
    requireInternal(req)
    const body = await req.json() as Record<string, unknown>
    const reason = String(body.reason ?? 'CONFIRMED').trim().toUpperCase()
    const client = adminClient()
    if (reason === 'REFUND_FAILED') return await sendRefundFailedNotification(client, body)
    if (reason === 'REFUND_COMPLETED') return await sendRefundCompletedNotification(client, body)
    return await sendAppointmentConfirmation(client, body)
  } catch (error) {
    const code = error instanceof Error ? error.message : 'TRANSACTIONAL_EMAIL_FAILED'
    console.error('EMAIL_SEND_FAILED', code)
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
