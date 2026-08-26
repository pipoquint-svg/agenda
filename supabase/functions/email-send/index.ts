import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import {
  buildConfirmationEmail,
  isRecipientAllowed,
  isScopeEnabled,
  maskEmail,
  normalizedEmail,
} from '../_shared/transactional-email.ts'

const PROVIDER_TIMEOUT_MS = 15_000

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function envEnabled(name: string): boolean {
  return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true'
}
function isEnabled(): boolean { return envEnabled('TRANSACTIONAL_EMAIL_ENABLED') }
function templateRuntimeEnabled(): boolean { return envEnabled('NOTIFICATION_TEMPLATES_RUNTIME_ENABLED') }
function allowRealRecipients(): boolean { return envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS') }

function numeric(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}
function money(value: unknown): string {
  return numeric(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}
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
async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

function senderForScope(scope: string): { brandName: string; from: string; replyTo: string | null } | null {
  if (scope === 'BLACKSHEEP') {
    const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() ?? ''
    if (!from) return null
    return { brandName: 'BlackSheep Estúdio Criativo', from, replyTo: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim() || null }
  }
  if (scope === 'SABRINA') {
    const from = Deno.env.get('EMAIL_FROM_SABRINA')?.trim() ?? ''
    if (!from) return null
    return { brandName: 'Sabrina Pierri', from, replyTo: Deno.env.get('EMAIL_REPLY_TO_SABRINA')?.trim() || null }
  }
  return null
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

    const { data: financial, error: financialError } = await client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId })
    if (financialError) throw new Error('FINANCIAL_SUMMARY_FAILED')

    let message: { subject: string; text: string; html: string }
    let templateId: string | null = null
    let providerIdempotencyKey = `appointment-confirmed-email:${appointmentId}:v${entityVersion}`

    if (templateRuntimeEnabled()) {
      const eventKey = 'APPOINTMENT_APPROVED'
      const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template', {
        p_event_key: eventKey, p_channel: 'EMAIL', p_audience: 'CUSTOMER', p_service_id: appointment.service_id,
      })
      if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
      const template = Array.isArray(rows) ? rows[0] : null
      if (!template) return jsonResponse({ stale: false, skipped: true, reason: 'NOTIFICATION_TEMPLATE_NOT_FOUND', event_key: eventKey })
      templateId = String(template.id)

      const [{ data: extras }, { data: discount }, { data: operationSettings }] = await Promise.all([
        client.from('appointment_extras').select('name_snapshot,quantity').eq('appointment_id', appointmentId),
        client.from('appointment_discounts').select('code_snapshot,calculated_discount_amount').eq('appointment_id', appointmentId).maybeSingle(),
        client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope }),
      ])
      const values: Record<string, string> = {
        'appointment.public_code': String(appointment.public_code ?? ''),
        'appointment.start_at': String(appointment.start_at ?? ''),
        'appointment.end_at': String(appointment.end_at ?? ''),
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
        'payment.status': String(appointment.financial_status ?? ''),
        'extras.summary': (extras ?? []).map((item: any) => `${item.name_snapshot} × ${item.quantity}`).join(', '),
        'coupon.code': String(discount?.code_snapshot ?? ''),
        'coupon.discount': money(discount?.calculated_discount_amount ?? 0),
      }
      const allowed = new Set(Array.isArray(template.variable_schema) ? template.variable_schema.map(String) : [])
      const subject = renderTemplate(String(template.title_template ?? ''), allowed, values)
      const text = renderTemplate(String(template.body_template ?? ''), allowed, values)
      message = { subject, text, html: `<p>${htmlEscape(text).replaceAll('\n', '<br>')}</p>` }
      providerIdempotencyKey = `notification:${templateId}:${appointmentId}:v${entityVersion}:EMAIL:CUSTOMER`

      const recipientHash = await sha256(recipient)
      const { data: existing } = await client.from('notification_delivery_logs').select('id,status,attempt_count,provider_message_id').eq('idempotency_key', providerIdempotencyKey).maybeSingle()
      if (existing?.status === 'SENT') {
        return jsonResponse({ stale: false, skipped: true, reason: 'NOTIFICATION_ALREADY_SENT', provider_message_id: existing.provider_message_id ?? null })
      }
      if (existing) {
        deliveryLogId = existing.id
        const { error: updateLogError } = await client.from('notification_delivery_logs').update({ status: 'PENDING', attempt_count: Number(existing.attempt_count ?? 0) + 1, last_error_code: null, updated_at: new Date().toISOString() }).eq('id', existing.id)
        if (updateLogError) throw new Error('NOTIFICATION_DELIVERY_LOG_UPDATE_FAILED')
      } else {
        const { data: inserted, error: insertLogError } = await client.from('notification_delivery_logs').insert({
          template_id: templateId, event_key: eventKey, channel: 'EMAIL', audience: 'CUSTOMER', appointment_id: appointmentId,
          customer_id: customer.id, recipient_hash: recipientHash, status: 'PENDING', attempt_count: 1,
          idempotency_key: providerIdempotencyKey,
          payload_snapshot: { template_id: templateId, appointment_id: appointmentId, entity_version: entityVersion, operation_scope: scope },
        }).select('id').single()
        if (insertLogError || !inserted) throw new Error('NOTIFICATION_DELIVERY_LOG_INSERT_FAILED')
        deliveryLogId = inserted.id
      }
    } else {
      message = buildConfirmationEmail({
        brandName: sender.brandName, customerName: String(customer.name ?? 'Cliente'),
        serviceName: String(appointment.service_name_snapshot ?? service.name ?? 'Reserva'), startAt: String(appointment.start_at),
        durationMinutes: numeric(appointment.duration_minutes), publicCode: String(appointment.public_code ?? ''),
        totalValue: numeric(appointment.commercial_value), paidValue: numeric(financial?.contract_settled), balanceValue: numeric(financial?.contract_balance),
      })
    }

    const apiKey = Deno.env.get('RESEND_API_KEY')?.trim() ?? ''
    if (!apiKey) throw new Error('MISSING_ENV:RESEND_API_KEY')
    const providerPayload: Record<string, unknown> = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    try {
      const providerMessageId = await sendWithResend(apiKey, providerPayload, providerIdempotencyKey)
      if (deliveryLogId) {
        const { error: sentLogError } = await client.from('notification_delivery_logs').update({ status: 'SENT', provider_message_id: providerMessageId, updated_at: new Date().toISOString() }).eq('id', deliveryLogId)
        if (sentLogError) throw new Error('NOTIFICATION_DELIVERY_LOG_SENT_FAILED')
      }
      return jsonResponse({ stale: false, skipped: false, appointment_id: appointmentId, entity_version: entityVersion, reason, operation_scope: scope, recipient_masked: maskEmail(recipient), provider: 'RESEND', provider_message_id: providerMessageId, template_id: templateId })
    } catch (sendError) {
      if (deliveryLogId) {
        await client.from('notification_delivery_logs').update({ status: 'FAILED', last_error_code: sendError instanceof Error ? sendError.message.slice(0, 120) : 'EMAIL_PROVIDER_FAILED', updated_at: new Date().toISOString() }).eq('id', deliveryLogId)
      }
      throw sendError
    }
  } catch (error) {
    const code = error instanceof Error ? error.message : 'TRANSACTIONAL_EMAIL_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
