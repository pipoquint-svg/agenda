import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from './email-provider.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from './transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  sha256,
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

function paymentResumeBaseUrl(): string {
  const configured = (Deno.env.get('PAYMENT_RESUME_PUBLIC_BASE_URL') ?? '').trim().replace(/\/+$/, '')
  const raw = configured || 'https://www.sabrinapierri.com.br'
  const parsed = new URL(raw)
  if (parsed.protocol !== 'https:') throw new Error('PAYMENT_RESUME_PUBLIC_BASE_URL_INVALID')
  return parsed.toString().replace(/\/+$/, '')
}

function randomAccessToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

export async function sendPaymentResumeEmail(
  client: any,
  input: { appointmentId: string },
): Promise<{ sent: boolean; reason: string; providerMessageId?: string | null }> {
  // This message is part of the Sabrina PAY_NOW recovery contract, not an optional
  // campaign notification. Scope, recipient and template gates below still apply.
  if (!input.appointmentId) throw new Error('PAYMENT_RESUME_EMAIL_CONTEXT_INVALID')

  const { data: appointment, error: appointmentError } = await client
    .from('appointments')
    .select('id,public_code,service_id,primary_customer_id,status,start_at,duration_minutes,service_name_snapshot,hold_expires_at,payment_provider_snapshot')
    .eq('id', input.appointmentId)
    .maybeSingle()
  if (appointmentError || !appointment) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (appointment.status !== 'AWAITING_PAYMENT') {
    return { sent: false, reason: 'PAYMENT_RESUME_NOT_AWAITING_PAYMENT' }
  }
  const expiresAt = new Date(String(appointment.hold_expires_at ?? ''))
  if (Number.isNaN(expiresAt.getTime()) || expiresAt.getTime() <= Date.now()) {
    return { sent: false, reason: 'PAYMENT_RESUME_HOLD_EXPIRED' }
  }

  const [serviceResult, customerResult] = await Promise.all([
    client.from('services').select('id,name,operation_scope').eq('id', appointment.service_id).maybeSingle(),
    client.from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle(),
  ])
  if (serviceResult.error || !serviceResult.data) throw new Error('SERVICE_LOOKUP_FAILED')
  if (customerResult.error || !customerResult.data) throw new Error('CUSTOMER_LOOKUP_FAILED')

  const service = serviceResult.data
  const customer = customerResult.data
  const scope = String(service.operation_scope ?? '').trim().toUpperCase()
  if (scope !== 'SABRINA') return { sent: false, reason: 'PAYMENT_RESUME_SCOPE_NOT_ENABLED' }
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

  const eventKey = 'PAYMENT_PENDING_CREATED'
  const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
    p_event_key: eventKey,
    p_channel: 'EMAIL',
    p_audience: 'CUSTOMER',
    p_service_id: appointment.service_id,
  })
  if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
  const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
  if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')

  const idempotencyKey = `notification:${template.id}:${appointment.id}:EMAIL:CUSTOMER`
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
      expires_at: appointment.hold_expires_at,
      operation_scope: scope,
      payment_provider: appointment.payment_provider_snapshot,
      recipient_masked: maskEmail(recipient),
      token_scope: 'PAY',
    },
  })
  if (delivery.alreadySent) {
    return { sent: true, reason: 'NOTIFICATION_ALREADY_SENT', providerMessageId: delivery.providerMessageId }
  }

  let issuedTokenId: string | null = null
  try {
    const paymentToken = randomAccessToken()
    const { data: issuedToken, error: tokenError } = await client
      .from('appointment_access_tokens')
      .insert({
        appointment_id: appointment.id,
        token_hash: await sha256(paymentToken),
        scope: 'PAY',
        expires_at: appointment.hold_expires_at,
        delivery_channel: 'EMAIL',
        destination_masked: maskEmail(recipient),
      })
      .select('id')
      .single()
    if (tokenError || !issuedToken) throw new Error('PAYMENT_RESUME_TOKEN_ISSUE_FAILED')
    issuedTokenId = String(issuedToken.id)

    const { data: operationSettings } = await client.rpc('service_admin_get_operation_settings_v2', {
      p_operation_scope: scope,
    })
    const resumeUrl = `${paymentResumeBaseUrl()}/retomar-pagamento.html#token=${encodeURIComponent(paymentToken)}`
    const values: Record<string, string> = {
      'operation.name': String(operationSettings?.public_name ?? sender.brandName),
      'customer.name': String(customer.name ?? ''),
      'service.name': String(appointment.service_name_snapshot ?? service.name ?? ''),
      'appointment.public_code': String(appointment.public_code ?? ''),
      'appointment.start_at': dateTime(appointment.start_at),
      'appointment.duration': `${Math.max(0, Math.round(Number(appointment.duration_minutes ?? 0)))} min`,
      'payment.expires_at': dateTime(appointment.hold_expires_at),
      'payment.resume_url': resumeUrl,
    }
    const message = renderNotificationMessage(template, values, sender.brandName)
    const providerPayload: EmailProviderPayload = {
      from: sender.from,
      to: [recipient],
      subject: message.subject,
      text: message.text,
      html: message.html,
    }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    const providerMessageId = await sendEmailWithProvider(providerPayload, idempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)
    return { sent: true, reason: eventKey, providerMessageId }
  } catch (error) {
    if (issuedTokenId) {
      await client.from('appointment_access_tokens').update({ revoked_at: new Date().toISOString() }).eq('id', issuedTokenId)
    }
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}
