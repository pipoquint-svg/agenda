import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from './email-provider.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from './transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  type NotificationTemplate,
} from './notification-email.ts'

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
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

function paymentBaseUrl(): string {
  const configured = (Deno.env.get('PREBOOK_PUBLIC_BASE_URL') ?? '').trim().replace(/\/+$/, '')
  if (configured) {
    const parsed = new URL(configured)
    if (parsed.protocol !== 'https:') throw new Error('PREBOOK_PUBLIC_BASE_URL_INVALID')
    return parsed.toString().replace(/\/+$/, '')
  }
  return 'https://blacksheepestudiocriativo.com.br'
}

export async function sendPreReservationCreatedEmail(
  client: any,
  input: { appointmentId: string; accessToken: string },
): Promise<{ sent: boolean; reason: string; providerMessageId?: string | null }> {
  if (!envEnabled('TRANSACTIONAL_EMAIL_ENABLED')) {
    return { sent: false, reason: 'TRANSACTIONAL_EMAIL_DISABLED' }
  }
  if (!input.appointmentId || input.accessToken.trim().length < 32) {
    throw new Error('PRE_RESERVATION_EMAIL_CONTEXT_INVALID')
  }

  const { data: appointment, error: appointmentError } = await client
    .from('appointments')
    .select('id,public_code,service_id,primary_customer_id,status,start_at,end_at,duration_minutes,service_name_snapshot,source_pre_reservation_id')
    .eq('id', input.appointmentId)
    .maybeSingle()
  if (appointmentError || !appointment) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (appointment.status !== 'AWAITING_PAYMENT' || !appointment.source_pre_reservation_id) {
    return { sent: false, reason: 'PRE_RESERVATION_NOT_AWAITING_PAYMENT' }
  }

  const [prebookResult, serviceResult, customerResult] = await Promise.all([
    client.from('pre_reservations').select('id,status,expires_at').eq('id', appointment.source_pre_reservation_id).maybeSingle(),
    client.from('services').select('id,name,operation_scope').eq('id', appointment.service_id).maybeSingle(),
    client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle(),
  ])
  if (prebookResult.error || !prebookResult.data) throw new Error('PRE_RESERVATION_LOOKUP_FAILED')
  if (serviceResult.error || !serviceResult.data) throw new Error('SERVICE_LOOKUP_FAILED')
  if (customerResult.error || !customerResult.data) throw new Error('CUSTOMER_LOOKUP_FAILED')

  const prebook = prebookResult.data
  const service = serviceResult.data
  const customer = customerResult.data
  if (prebook.status !== 'ACTIVE') return { sent: false, reason: 'PRE_RESERVATION_NOT_ACTIVE' }

  const scope = String(service.operation_scope ?? '').trim().toUpperCase()
  if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) {
    return { sent: false, reason: 'EMAIL_SCOPE_DISABLED' }
  }
  const sender = notificationSenderForScope(scope)
  if (!sender) return { sent: false, reason: 'EMAIL_SCOPE_SENDER_NOT_CONFIGURED' }

  const recipient = normalizedEmail(customer.email)
  if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
    return { sent: false, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' }
  }
  if (!isRecipientAllowed(recipient, envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS'), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) {
    return { sent: false, reason: 'EMAIL_RECIPIENT_NOT_ALLOWLISTED' }
  }

  const eventKey = 'PRE_RESERVATION_CREATED'
  const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
    p_event_key: eventKey,
    p_channel: 'EMAIL',
    p_audience: 'CUSTOMER',
    p_service_id: appointment.service_id,
  })
  if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
  const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
  if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')

  const { data: operationSettings } = await client.rpc('service_admin_get_operation_settings_v2', {
    p_operation_scope: scope,
  })
  const paymentUrl = `${paymentBaseUrl()}/pre-reserva/confirmar?token=${encodeURIComponent(input.accessToken.trim())}`
  const values: Record<string, string> = {
    'operation.name': String(operationSettings?.public_name ?? sender.brandName),
    'customer.name': String(customer.name ?? ''),
    'service.name': String(appointment.service_name_snapshot ?? service.name ?? ''),
    'appointment.public_code': String(appointment.public_code ?? ''),
    'appointment.start_at': dateTime(appointment.start_at),
    'appointment.duration': `${Math.max(0, Math.round(Number(appointment.duration_minutes ?? 0)))} min`,
    'pre_reservation.expires_at': dateTime(prebook.expires_at),
    'pre_reservation.payment_url': paymentUrl,
  }
  const message = renderNotificationMessage(template, values, sender.brandName)
  const idempotencyKey = `notification:${template.id}:${prebook.id}:EMAIL:CUSTOMER`
  const delivery = await beginNotificationDelivery(client, {
    templateId: template.id,
    eventKey,
    audience: 'CUSTOMER',
    appointmentId: appointment.id,
    customerId: customer.id,
    recipient,
    idempotencyKey,
    payloadSnapshot: {
      template_id: template.id,
      appointment_id: appointment.id,
      pre_reservation_id: prebook.id,
      expires_at: prebook.expires_at,
      operation_scope: scope,
      recipient_masked: maskEmail(recipient),
    },
  })
  if (delivery.alreadySent) {
    return { sent: true, reason: 'NOTIFICATION_ALREADY_SENT', providerMessageId: delivery.providerMessageId }
  }

  const providerPayload: EmailProviderPayload = {
    from: sender.from,
    to: [recipient],
    subject: message.subject,
    text: message.text,
    html: message.html,
  }
  if (sender.replyTo) providerPayload.reply_to = sender.replyTo

  try {
    const providerMessageId = await sendEmailWithProvider(providerPayload, idempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)
    return { sent: true, reason: eventKey, providerMessageId }
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}
