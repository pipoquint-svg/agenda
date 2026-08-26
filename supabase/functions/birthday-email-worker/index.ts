import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import { adminClient } from '../_shared/supabase.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import { assertGitHubBirthdayClaims, GITHUB_BIRTHDAY_AUDIENCE, GITHUB_OIDC_ISSUER } from '../_shared/github-oidc.ts'

const PROVIDER_TIMEOUT_MS = 15_000
const MAX_ATTEMPTS = 4
const BATCH_LIMIT = 20
const GITHUB_JWKS = createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'))

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8' } })
}
function envEnabled(name: string): boolean { return (Deno.env.get(name) ?? '').trim().toLowerCase() === 'true' }
function bearerToken(req: Request): string {
  const match = (req.headers.get('authorization') ?? '').match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('GITHUB_OIDC_REQUIRED')
  return match[1]
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
function formatDate(value: unknown): string {
  if (typeof value !== 'string' || !value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
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
      body: JSON.stringify(payload), signal: controller.signal,
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
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  try {
    const token = bearerToken(req)
    const { payload } = await jwtVerify(token, GITHUB_JWKS, { issuer: GITHUB_OIDC_ISSUER, audience: GITHUB_BIRTHDAY_AUDIENCE })
    assertGitHubBirthdayClaims(payload as Record<string, unknown>)

    if (!envEnabled('BIRTHDAY_EMAIL_DELIVERY_ENABLED')) return json({ ok: true, skipped: true, reason: 'BIRTHDAY_EMAIL_DELIVERY_DISABLED' })
    if (!envEnabled('TRANSACTIONAL_EMAIL_ENABLED')) return json({ ok: true, skipped: true, reason: 'TRANSACTIONAL_EMAIL_DISABLED' })
    if (!envEnabled('NOTIFICATION_TEMPLATES_RUNTIME_ENABLED')) return json({ ok: true, skipped: true, reason: 'NOTIFICATION_TEMPLATES_RUNTIME_DISABLED' })

    const apiKey = Deno.env.get('RESEND_API_KEY')?.trim() ?? ''
    if (!apiKey) throw new Error('MISSING_ENV_RESEND_API_KEY')
    const client = adminClient()
    const { data: logs, error: logsError } = await client.from('notification_delivery_logs')
      .select('id,template_id,customer_id,attempt_count,idempotency_key,payload_snapshot')
      .eq('event_key', 'BIRTHDAY').eq('channel', 'EMAIL').eq('audience', 'CUSTOMER').eq('status', 'PENDING')
      .lt('attempt_count', MAX_ATTEMPTS).order('created_at', { ascending: true }).limit(BATCH_LIMIT)
    if (logsError) throw new Error('BIRTHDAY_DELIVERY_LOOKUP_FAILED')

    let sent = 0
    let deferred = 0
    let failed = 0
    let skipped = 0

    for (const log of logs ?? []) {
      const snapshot = log.payload_snapshot && typeof log.payload_snapshot === 'object' ? log.payload_snapshot as Record<string, unknown> : {}
      const scope = String(snapshot.operation_scope ?? '').trim().toUpperCase()
      const cycleId = String(snapshot.birthday_cycle_id ?? '').trim()
      const couponId = String(snapshot.coupon_id ?? '').trim()
      const nextAttempt = Number(log.attempt_count ?? 0) + 1

      const fail = async (code: string, terminal = true) => {
        await client.from('notification_delivery_logs').update({
          status: terminal ? 'FAILED' : 'PENDING', attempt_count: nextAttempt,
          last_error_code: code.slice(0, 120), updated_at: new Date().toISOString(),
        }).eq('id', log.id)
        if (terminal && cycleId) {
          await client.from('birthday_automation_cycles').update({ message_status: 'FAILED', updated_at: new Date().toISOString() }).eq('id', cycleId)
        }
        failed += 1
      }

      if (!['BLACKSHEEP', 'SABRINA'].includes(scope) || !cycleId || !log.template_id || !log.customer_id) {
        await fail('BIRTHDAY_DELIVERY_CONTEXT_INVALID')
        continue
      }
      if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) { deferred += 1; continue }
      const sender = senderForScope(scope)
      if (!sender) { deferred += 1; continue }

      const templatePromise = client.from('notification_template_configs')
        .select('id,event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema')
        .eq('id', log.template_id).maybeSingle()
      const customerPromise = client.from('customers').select('id,name,email').eq('id', log.customer_id).maybeSingle()
      const couponPromise = couponId
        ? client.from('coupons').select('id,code,valid_until,source,customer_id,is_active').eq('id', couponId).maybeSingle()
        : Promise.resolve({ data: null, error: null })
      const operationPromise = client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: scope })
      const [templateResult, customerResult, couponResult, operationResult] = await Promise.all([templatePromise, customerPromise, couponPromise, operationPromise])
      const { data: template, error: templateError } = templateResult
      const { data: customer, error: customerError } = customerResult
      const { data: coupon, error: couponError } = couponResult
      const { data: operationSettings, error: operationError } = operationResult

      if (templateError || customerError || couponError || operationError || !template || !customer) {
        await fail('BIRTHDAY_DELIVERY_CONTEXT_LOOKUP_FAILED', nextAttempt >= MAX_ATTEMPTS)
        continue
      }
      if (!template.is_active || template.event_key !== 'BIRTHDAY' || template.channel !== 'EMAIL' || template.audience !== 'CUSTOMER' || (template.operation_scope && template.operation_scope !== scope)) {
        await fail('BIRTHDAY_TEMPLATE_INVALID')
        continue
      }
      if (couponId && (!coupon || coupon.source !== 'BIRTHDAY' || coupon.customer_id !== customer.id || !coupon.is_active)) {
        await fail('BIRTHDAY_COUPON_INVALID')
        continue
      }

      const recipient = normalizedEmail(customer.email)
      if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
        const now = new Date().toISOString()
        await Promise.all([
          client.from('notification_delivery_logs').update({ status: 'SKIPPED', attempt_count: nextAttempt, last_error_code: 'EMAIL_RECIPIENT_MISSING_OR_INVALID', updated_at: now }).eq('id', log.id),
          client.from('birthday_automation_cycles').update({ message_status: 'SKIPPED', updated_at: now }).eq('id', cycleId),
        ])
        skipped += 1
        continue
      }
      if (!isRecipientAllowed(recipient, envEnabled('ALLOW_REAL_EMAIL_RECIPIENTS'), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) { deferred += 1; continue }

      const allowed = new Set<string>(Array.isArray(template.variable_schema) ? template.variable_schema.map((item: unknown) => String(item)) : [])
      const values: Record<string, string> = {
        'customer.name': String(customer.name ?? ''), 'customer.email': recipient,
        'coupon.code': String(coupon?.code ?? ''), 'coupon.discount': '', 'coupon.expires_at': formatDate(coupon?.valid_until),
        'operation.name': String(operationSettings?.public_name ?? sender.brandName),
        'operation.email': String(operationSettings?.public_email ?? ''), 'operation.phone': String(operationSettings?.public_phone ?? ''),
        'operation.address': String(operationSettings?.public_address ?? ''), 'operation.site_url': String(operationSettings?.public_site_url ?? ''),
      }

      let subject: string
      let text: string
      try {
        subject = renderTemplate(String(template.title_template ?? ''), allowed, values)
        text = renderTemplate(String(template.body_template ?? ''), allowed, values)
      } catch (error) {
        await fail(error instanceof Error ? error.message.split(':')[0] : 'BIRTHDAY_TEMPLATE_RENDER_FAILED')
        continue
      }

      const providerPayload: Record<string, unknown> = {
        from: sender.from, to: [recipient], subject, text,
        html: `<p>${htmlEscape(text).replaceAll('\n', '<br>')}</p>`,
      }
      if (sender.replyTo) providerPayload.reply_to = sender.replyTo

      try {
        const providerMessageId = await sendWithResend(apiKey, providerPayload, String(log.idempotency_key))
        const { error: finalizeError } = await client.rpc('finalize_birthday_email_delivery', {
          p_delivery_log_id: log.id,
          p_cycle_id: cycleId,
          p_provider_message_id: providerMessageId ?? '',
          p_recipient_masked: maskEmail(recipient),
        })
        if (finalizeError) throw new Error('BIRTHDAY_DELIVERY_FINALIZE_FAILED')
        sent += 1
      } catch (error) {
        await fail(error instanceof Error ? error.message.split(':')[0] : 'EMAIL_PROVIDER_FAILED', nextAttempt >= MAX_ATTEMPTS)
      }
    }

    return json({ ok: true, skipped: false, selected: logs?.length ?? 0, sent, deferred, failed, skipped_count: skipped })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'BIRTHDAY_EMAIL_WORKER_FAILED'
    console.error('Birthday email worker failed', { code: message.split(':')[0] })
    return json({ error: { code: message.split(':')[0] } }, message.startsWith('GITHUB_') ? 401 : 500)
  }
})
