import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import { renderNotificationMessage, type NotificationTemplate } from '../_shared/notification-email.ts'

const MAX_BATCH = 20

type ClaimedDelivery = {
  id: string
  template_id: string | null
  customer_id: string | null
  idempotency_key: string
  payload_snapshot: Record<string, unknown> | null
  attempt_count: number
}

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}
function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}
function deliveryEnabled(): boolean {
  return envEnabled('BIRTHDAY_EMAIL_DELIVERY_ENABLED')
    && envEnabled('TRANSACTIONAL_EMAIL_ENABLED')
    && envEnabled('NOTIFICATION_TEMPLATES_RUNTIME_ENABLED')
}
function allowRealRecipients(): boolean { return envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS') }
function formattedDate(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) throw new Error('BIRTHDAY_COUPON_EXPIRY_INVALID')
  return new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date)
}
function preserveDeliveryWindow(errorCode: string, providerSucceeded: boolean): boolean {
  if (providerSucceeded) return true
  return errorCode === 'EMAIL_PROVIDER_TIMEOUT'
    || errorCode === 'EMAIL_PROVIDER_NETWORK_ERROR'
    || errorCode === 'EMAIL_PROVIDER_INVALID_RESPONSE'
}

async function processDelivery(delivery: ClaimedDelivery): Promise<{ id: string; providerMessageId: string | null; recipientMasked: string }> {
  const client = adminClient()
  let providerSucceeded = false
  try {
    const payload = delivery.payload_snapshot ?? {}
    const scope = String(payload.operation_scope ?? '').trim().toUpperCase()
    const couponId = String(payload.coupon_id ?? '').trim() || null
    if (!['SABRINA', 'BLACKSHEEP'].includes(scope)) throw new Error('BIRTHDAY_DELIVERY_OPERATION_SCOPE_INVALID')
    if (!delivery.customer_id) throw new Error('BIRTHDAY_DELIVERY_CUSTOMER_MISSING')
    if (!delivery.template_id) throw new Error('BIRTHDAY_DELIVERY_TEMPLATE_MISSING')
    if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) throw new Error('EMAIL_SCOPE_DISABLED')

    const sender = notificationSenderForScope(scope)
    if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

    const [{ data: customer, error: customerError }, { data: template, error: templateError }, { data: operationSettings, error: operationError }] = await Promise.all([
      client.from('customers').select('id,name,email').eq('id', delivery.customer_id).maybeSingle(),
      client.from('notification_template_configs').select('id,event_key,title_template,body_template,html_template,is_active,variable_schema,operation_scope').eq('id', delivery.template_id).maybeSingle(),
      client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope }),
    ])
    if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')
    if (templateError || !template || !template.is_active) throw new Error('BIRTHDAY_TEMPLATE_NOT_ACTIVE')
    if (operationError) throw new Error('BIRTHDAY_OPERATION_SETTINGS_FAILED')

    const recipient = normalizedEmail(customer.email)
    if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) throw new Error('EMAIL_RECIPIENT_MISSING_OR_INVALID')
    if (!isRecipientAllowed(recipient, allowRealRecipients(), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) {
      throw new Error('EMAIL_RECIPIENT_NOT_ALLOWLISTED')
    }

    let coupon: { id: string; code: string } | null = null
    if (couponId) {
      const { data, error } = await client.from('coupons').select('id,code,source').eq('id', couponId).maybeSingle()
      if (error || !data || data.source !== 'BIRTHDAY') throw new Error('BIRTHDAY_COUPON_NOT_FOUND')
      coupon = { id: String(data.id), code: String(data.code) }
    }

    const { data: windowData, error: windowError } = await client.rpc('prepare_birthday_notification_delivery_window', { p_log_id: delivery.id })
    if (windowError || !windowData) throw new Error('BIRTHDAY_DELIVERY_WINDOW_PREPARE_FAILED')
    const expiresAt = String(windowData.coupon_expires_at ?? '')
    const siteUrl = String(operationSettings?.public_site_url ?? '').trim()
    if (!siteUrl) throw new Error('BIRTHDAY_OPERATION_SITE_URL_REQUIRED')

    const values: Record<string, string> = {
      'customer.name': String(customer.name ?? 'Cliente'),
      'customer.email': recipient,
      'coupon.code': coupon?.code ?? '',
      'coupon.discount': '',
      'coupon.expires_at': formattedDate(expiresAt),
      'operation.name': String(operationSettings?.public_name ?? sender.brandName),
      'operation.email': String(operationSettings?.public_email ?? ''),
      'operation.phone': String(operationSettings?.public_phone ?? ''),
      'operation.address': String(operationSettings?.public_address ?? ''),
      'operation.site_url': siteUrl,
    }
    const message = renderNotificationMessage(template as NotificationTemplate, values, sender.brandName)

    const providerPayload: EmailProviderPayload = {
      from: sender.from,
      to: [recipient],
      subject: message.subject,
      text: message.text,
      html: message.html,
    }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    const providerMessageId = await sendEmailWithProvider(providerPayload, delivery.idempotency_key)
    providerSucceeded = true
    const { error: finalizeError } = await client.rpc('finalize_birthday_notification_delivery', {
      p_log_id: delivery.id,
      p_provider_message_id: providerMessageId,
    })
    if (finalizeError) throw new Error('BIRTHDAY_DELIVERY_FINALIZE_FAILED')
    return { id: delivery.id, providerMessageId, recipientMasked: maskEmail(recipient) }
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'BIRTHDAY_EMAIL_DELIVERY_FAILED'
    await client.rpc('fail_birthday_notification_delivery', {
      p_log_id: delivery.id,
      p_error_code: code,
      p_preserve_window: preserveDeliveryWindow(code, providerSucceeded),
    })
    throw new Error(code)
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  try {
    requireInternal(req)
    if (!deliveryEnabled()) {
      return jsonResponse({ ok: true, skipped: true, reason: 'BIRTHDAY_EMAIL_DELIVERY_DISABLED', claimed: 0, sent: 0, failed: 0 })
    }

    const client = adminClient()
    const { data, error } = await client.rpc('claim_birthday_notification_deliveries', { p_limit: MAX_BATCH })
    if (error) throw new Error('BIRTHDAY_DELIVERY_CLAIM_FAILED')
    const claimed = (Array.isArray(data) ? data : []) as ClaimedDelivery[]
    let sent = 0
    let failed = 0
    const failures: string[] = []
    for (const delivery of claimed) {
      try {
        await processDelivery(delivery)
        sent += 1
      } catch (error) {
        failed += 1
        failures.push(error instanceof Error ? error.message : 'BIRTHDAY_EMAIL_DELIVERY_FAILED')
      }
    }
    if (failed > 0) {
      console.error('Birthday delivery batch has failures', { claimed: claimed.length, sent, failed, codes: failures })
      return errorResponse(new Error('BIRTHDAY_DELIVERY_BATCH_FAILED'), 502)
    }
    return jsonResponse({ ok: true, skipped: false, claimed: claimed.length, sent, failed })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'BIRTHDAY_EMAIL_WORKER_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
