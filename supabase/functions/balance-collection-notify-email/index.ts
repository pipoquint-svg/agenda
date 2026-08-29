import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { senderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { isRecipientAllowed, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
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

function enabled(): boolean {
  return (Deno.env.get('TRANSACTIONAL_EMAIL_ENABLED') ?? '').trim().toLowerCase() === 'true'
}

function allowRealRecipients(): boolean {
  return (Deno.env.get('ALLOW_REAL_EMAIL_RECIPIENTS') ?? '').trim().toLowerCase() === 'true'
}

function money(value: unknown): string {
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number(value ?? 0))
}

function dateTime(value: string): string {
  return new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Sao_Paulo' }).format(new Date(value))
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  let deliveryLogId: string | null = null
  try {
    requireInternal(req)
    const body = await req.json().catch(() => ({}))
    const collectionId = String(body?.collection_id ?? '').trim()
    if (!/^[0-9a-f-]{36}$/i.test(collectionId)) throw new Error('BALANCE_COLLECTION_ID_INVALID')
    if (!enabled()) return jsonResponse({ skipped: true, reason: 'TRANSACTIONAL_EMAIL_DISABLED' })

    const client = adminClient()
    const { data: collection, error: collectionError } = await client
      .from('appointment_balance_collections')
      .select('id,appointment_id,sequence,status,amount_snapshot,expires_at')
      .eq('id', collectionId).maybeSingle()
    if (collectionError || !collection) throw new Error('BALANCE_COLLECTION_NOT_FOUND')
    if (collection.status !== 'PENDING') return jsonResponse({ skipped: true, reason: 'BALANCE_COLLECTION_NOT_PENDING' })

    const { data: appointment, error: appointmentError } = await client
      .from('appointments')
      .select('id,service_id,primary_customer_id,start_at,service_name_snapshot')
      .eq('id', collection.appointment_id).maybeSingle()
    if (appointmentError || !appointment?.primary_customer_id || !appointment?.service_id) throw new Error('APPOINTMENT_LOOKUP_FAILED')

    const { data: customer, error: customerError } = await client
      .from('customers').select('id,name,email').eq('id', appointment.primary_customer_id).maybeSingle()
    if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')
    const recipient = normalizedEmail(customer.email)
    if (!recipient || !isRecipientAllowed(recipient, allowRealRecipients(), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) {
      return jsonResponse({ skipped: true, reason: 'EMAIL_RECIPIENT_NOT_ALLOWED', recipient_masked: recipient ? maskEmail(recipient) : '***' })
    }

    const { data: description, error: descriptionError } = await client.rpc('appointment_commercial_description', { p_appointment_id: appointment.id })
    if (descriptionError) throw new Error('COMMERCIAL_DESCRIPTION_FAILED')
    const commercialDescription = String(description ?? appointment.service_name_snapshot ?? 'Locação de estúdio')
    const baseUrl = Deno.env.get('PUBLIC_BOOKING_BASE_URL')?.trim().replace(/\/$/, '') ?? ''
    if (!/^https:\/\//i.test(baseUrl)) throw new Error('PUBLIC_BOOKING_BASE_URL_INVALID')
    const payUrl = `${baseUrl}/reserva/saldo?collection=${encodeURIComponent(collection.id)}`

    const eventKey = 'RENTAL_BALANCE_DUE'
    const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
      p_event_key: eventKey,
      p_channel: 'EMAIL',
      p_audience: 'CUSTOMER',
      p_service_id: appointment.service_id,
    })
    if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
    const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
    if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')

    const sender = senderForScope('BLACKSHEEP')
    if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
    const values: Record<string, string> = {
      'customer.name': String(customer.name ?? 'Cliente').trim() || 'Cliente',
      'service.description': commercialDescription,
      'appointment.start_at': dateTime(appointment.start_at),
      'balance.amount': money(collection.amount_snapshot),
      'balance.expires_at': dateTime(collection.expires_at),
      'balance.payment_url': payUrl,
    }
    const message = renderNotificationMessage(template, values, sender.brandName)
    const providerIdempotencyKey = `notification:${template.id}:${collection.id}:EMAIL:CUSTOMER`
    const delivery = await beginNotificationDelivery(client, {
      templateId: template.id,
      eventKey,
      audience: 'CUSTOMER',
      appointmentId: appointment.id,
      customerId: customer.id,
      recipient,
      idempotencyKey: providerIdempotencyKey,
      payloadSnapshot: { template_id: template.id, appointment_id: appointment.id, collection_id: collection.id, operation_scope: 'BLACKSHEEP' },
    })
    deliveryLogId = delivery.id
    if (delivery.alreadySent) {
      const { error: retryEvidenceError } = await client.from('appointment_balance_collections').update({ email_delivered_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', collection.id)
      if (retryEvidenceError) throw new Error('BALANCE_EMAIL_DELIVERY_EVIDENCE_FAILED')
      return jsonResponse({ skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', collection_id: collection.id, provider_message_id: delivery.providerMessageId })
    }

    const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
    if (sender.replyTo) payload.reply_to = sender.replyTo

    let providerMessageId: string | null
    try {
      providerMessageId = await sendEmailWithProvider(payload, providerIdempotencyKey)
      await markNotificationSent(client, deliveryLogId, providerMessageId)
    } catch (sendError) {
      if (deliveryLogId) await markNotificationFailed(client, deliveryLogId, sendError)
      throw sendError
    }

    const { error: deliveredError } = await client.from('appointment_balance_collections').update({ email_delivered_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', collection.id)
    if (deliveredError) throw new Error('BALANCE_EMAIL_DELIVERY_EVIDENCE_FAILED')
    return jsonResponse({ skipped: false, collection_id: collection.id, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: template.id })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'BALANCE_EMAIL_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
