import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'

const PROVIDER_TIMEOUT_MS = 15_000
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
function htmlEscape(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;')
}
function renderTemplate(source: string, allowed: Set<string>, values: Record<string, string>): string {
  return source.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, rawKey) => {
    const key = String(rawKey).trim()
    if (!allowed.has(key)) throw new Error(`NOTIFICATION_TEMPLATE_VARIABLE_NOT_ALLOWED:${key}`)
    return values[key] ?? ''
  })
}
function senderForScope(scope: string): { brandName: string; from: string; replyTo: string | null } | null {
  if (scope === 'BLACKSHEEP') {
    const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() ?? ''
    return from ? { brandName: 'BlackSheep Estúdio Criativo', from, replyTo: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim() || null } : null
  }
  if (scope === 'SABRINA') {
    const from = Deno.env.get('EMAIL_FROM_SABRINA')?.trim() ?? ''
    return from ? { brandName: 'Sabrina Pierri', from, replyTo: Deno.env.get('EMAIL_REPLY_TO_SABRINA')?.trim() || null } : null
  }
  return null
}
function formattedDate(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) throw new Error('BIRTHDAY_COUPON_EXPIRY_INVALID')
  return new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date)
}
async function sendWithResend(apiKey: string, payload: Record<string, unknown>, idempotencyKey: string): Promise<string | null> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS)
  let response: Response
  try {
    response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', 'idempotency-key': idempotencyKey },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('EMAIL_PROVIDER_TIMEOUT')
    throw new Error('EMAIL_PROVIDER_NETWORK_ERROR')
  } finally { clearTimeout(timeout) }
  const responseText = await response.text()
  if (!response.ok) throw new Error(`EMAIL_PROVIDER_HTTP_${response.status}`)
  if (!responseText) return null
  try {
    const parsed = JSON.parse(responseText)
    return typeof parsed?.id === 'string' ? parsed.id : null
  } catch { throw new Error('EMAIL_PROVIDER_INVALID_RESPONSE') }
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

    const sender = senderForScope(scope)
    if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

    const [{ data: customer, error: customerError }, { data: template, error: templateError }, { data: operationSettings, error: operationError }] = await Promise.all([
      client.from('customers').select('id,name,email').eq('id', delivery.customer_id).maybeSingle(),
      client.from('notification_template_configs').select('id,title_template,body_template,is_active,variable_schema').eq('id', delivery.template_id).maybeSingle(),
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
    const allowed = new Set<string>(Array.isArray(template.variable_schema) ? template.variable_schema.map((item: unknown) => String(item)) : [])
    const subject = renderTemplate(String(template.title_template ?? ''), allowed, values)
    const text = renderTemplate(String(template.body_template ?? ''), allowed, values)

    const apiKey = Deno.env.get('RESEND_API_KEY')?.trim() ?? ''
    if (!apiKey) throw new Error('MISSING_ENV:RESEND_API_KEY')
    const providerPayload: Record<string, unknown> = {
      from: sender.from,
      to: [recipient],
      subject,
      text,
      html: `<p>${htmlEscape(text).replaceAll('\n', '<br>')}</p>`,
    }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    const providerMessageId = await sendWithResend(apiKey, providerPayload, delivery.idempotency_key)
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
