import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
import { senderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { recordOpsEdgeFailure } from '../_shared/ops-alerts.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function token(value: unknown, code: string): string {
  if (typeof value !== 'string' || value.trim().length < 32) throw new Error(code)
  return value.trim()
}

function verificationCode(value: unknown): string {
  const code = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9]{6}$/.test(code)) throw new Error('CUSTOMER_VERIFICATION_CODE_INVALID')
  return code
}

function maskEmail(value: string): string {
  const [local, domain] = value.trim().split('@')
  if (!local || !domain) return 'seu e-mail'
  const visible = local.slice(0, Math.min(2, local.length))
  return `${visible}${'*'.repeat(Math.max(3, local.length - visible.length))}@${domain}`
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

async function sendVerificationEmail(email: string, code: string, checkoutToken: string): Promise<void> {
  const sender = senderForScope('BLACKSHEEP')
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
  const subject = `Seu código de verificação | ${sender.brandName}`
  const text = [
    'Confirmação de identidade',
    '',
    `Seu código para acessar seus benefícios no checkout é: ${code}`,
    '',
    'O código expira em poucos minutos e só funciona neste checkout.',
    'Não compartilhe este código com ninguém.',
    '',
    'Se você não solicitou esta verificação, ignore esta mensagem.',
    '',
    sender.brandName,
  ].join('\n')
  const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#111"><div style="max-width:620px;margin:0 auto;padding:24px 14px"><div style="background:#fff;border:1px solid #ddd;border-radius:12px;padding:28px"><div style="font-size:13px;font-weight:700;letter-spacing:.04em;margin-bottom:12px">BLACKSHEEP ESTÚDIO CRIATIVO</div><h1 style="font-size:24px;line-height:1.2;margin:0 0 16px">Confirmação de identidade</h1><p style="font-size:16px;line-height:1.55;margin:0 0 18px">Use este código para acessar seus benefícios no checkout:</p><div style="font-size:30px;font-weight:800;letter-spacing:.16em;padding:16px 18px;background:#f4f4f4;border-radius:10px;text-align:center">${code}</div><p style="font-size:13px;line-height:1.5;color:#666;margin:20px 0 0">O código expira em poucos minutos e só funciona neste checkout. Não compartilhe este código com ninguém.</p><p style="font-size:13px;line-height:1.5;color:#666;margin:8px 0 0">Se você não solicitou esta verificação, ignore esta mensagem.</p></div></div></body></html>`
  const payload: EmailProviderPayload = { from: sender.from, to: [email], subject, text, html }
  if (sender.replyTo) payload.reply_to = sender.replyTo
  const key = await sha256(`checkout-benefit:${checkoutToken}:${code}`)
  await sendEmailWithProvider(payload, `checkout-benefit:${key}`)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, { scope: 'CHECKOUT_TOKEN', limit: 30, windowSeconds: 600 })
    const body = await req.json()
    const action = typeof body?.action === 'string' ? body.action.trim().toUpperCase() : ''
    const checkoutToken = token(body?.checkout_hold_token, 'CHECKOUT_HOLD_TOKEN_REQUIRED')

    if (action === 'BENEFIT_STATE') {
      const { data, error } = await client.rpc('service_public_checkout_benefit_hint', { p_checkout_hold_token: checkoutToken })
      if (error) throw new Error(error.message)
      return response({ data })
    }

    if (action === 'REQUEST_BENEFIT_VERIFICATION') {
      await enforceDistributedPublicRateLimit(client, req, { scope: 'CHECKOUT_CUSTOMER_VERIFICATION', limit: 10, windowSeconds: 600 })
      const { data, error } = await client.rpc('service_request_checkout_customer_verification', { p_checkout_hold_token: checkoutToken })
      if (error) throw new Error(error.message)
      const row = (data ?? {}) as Record<string, unknown>
      if (row.verification_required !== true || row.should_send !== true) {
        return response({ data: { verification_required: false, sent: false } })
      }
      const email = typeof row.email === 'string' ? row.email : ''
      const code = typeof row.code === 'string' ? row.code : ''
      if (!email || !/^[0-9]{6}$/.test(code)) throw new Error('CUSTOMER_VERIFICATION_DELIVERY_FAILED')
      await sendVerificationEmail(email, code, checkoutToken)
      return response({ data: { verification_required: true, sent: true, destination: maskEmail(email), expires_at: row.expires_at ?? null } })
    }

    if (action === 'VERIFY_BENEFIT_CODE') {
      await enforceDistributedPublicRateLimit(client, req, { scope: 'CHECKOUT_CUSTOMER_VERIFY_CODE', limit: 20, windowSeconds: 600 })
      const { data, error } = await client.rpc('service_verify_checkout_customer_code', {
        p_checkout_hold_token: checkoutToken,
        p_code: verificationCode(body?.code),
      })
      if (error) throw new Error(error.message)
      return response({ data })
    }

    if (action === 'BENEFITS' || action === 'LIST_PACKAGES') {
      const sessionToken = token(body?.customer_session_token, 'CUSTOMER_VERIFICATION_REQUIRED')
      const { data, error } = await client.rpc('service_public_checkout_benefits', {
        p_checkout_hold_token: checkoutToken,
        p_customer_session_token: sessionToken,
      })
      if (error) throw new Error(error.message)
      if (action === 'LIST_PACKAGES') return response({ data: (data as Record<string, unknown> | null)?.packages ?? [] })
      return response({ data })
    }

    let rpcName = ''
    let args: Record<string, unknown> = {}
    switch (action) {
      case 'CONTEXT':
        rpcName = 'public_get_checkout_context'; args = { p_checkout_hold_token: checkoutToken }; break
      case 'PREBOOK_OPTION':
        rpcName = 'service_public_get_checkout_prebook_option'; args = { p_checkout_hold_token: checkoutToken }; break
      case 'COUPON_STATE':
        rpcName = 'get_checkout_coupon_state'; args = { p_checkout_hold_token: checkoutToken }; break
      case 'APPLY_COUPON':
        rpcName = 'apply_checkout_coupon'; args = { p_checkout_hold_token: checkoutToken, p_coupon_code: typeof body?.coupon_code === 'string' ? body.coupon_code : '' }; break
      case 'CLEAR_COUPON':
        rpcName = 'clear_checkout_coupon'; args = { p_checkout_hold_token: checkoutToken }; break
      case 'UPDATE_SELECTION': {
        const peopleCount = Number.isInteger(body?.people_count) ? body.people_count as number : NaN
        if (!Number.isInteger(peopleCount)) throw new Error('INVALID_PEOPLE_COUNT')
        rpcName = 'public_update_checkout_hold_selection'
        args = { p_checkout_hold_token: checkoutToken, p_extra_selections: Array.isArray(body?.extra_selections) ? body.extra_selections : [], p_people_count: peopleCount }
        break
      }
      case 'BIND_CUSTOMER':
        rpcName = 'public_bind_checkout_customer'
        args = { p_checkout_hold_token: checkoutToken, p_name: typeof body?.name === 'string' ? body.name : '', p_email: typeof body?.email === 'string' ? body.email : '', p_phone: typeof body?.phone === 'string' ? body.phone : '', p_tax_id: typeof body?.tax_id === 'string' && body.tax_id.trim() ? body.tax_id.trim() : null, p_recovery_enabled: false }
        break
      case 'SELECT_PACKAGE':
        rpcName = 'service_public_select_checkout_hour_package_secure'
        args = { p_checkout_hold_token: checkoutToken, p_customer_session_token: token(body?.customer_session_token, 'CUSTOMER_VERIFICATION_REQUIRED'), p_hour_package_id: typeof body?.hour_package_id === 'string' ? body.hour_package_id : '' }
        break
      case 'CLEAR_PACKAGE':
        rpcName = 'service_public_clear_checkout_hour_package_secure'
        args = { p_checkout_hold_token: checkoutToken, p_customer_session_token: token(body?.customer_session_token, 'CUSTOMER_VERIFICATION_REQUIRED') }
        break
      default:
        throw new Error('CHECKOUT_ACTION_INVALID')
    }

    const { data, error } = await client.rpc(rpcName, args)
    if (error) throw new Error(error.message)
    return response({ data })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'CHECKOUT_ACTION_FAILED'
    const knownCode = code.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|CHECKOUT_ACTION_INVALID|CHECKOUT_HOLD_TOKEN_REQUIRED|CHECKOUT_HOLD_NOT_ACTIVE|CHECKOUT_HOLD_NOT_FOUND|CHECKOUT_CUSTOMER_REQUIRED|CHECKOUT_CUSTOMER_MISSING|PREBOOK_NOT_AVAILABLE|CUSTOMER_NAME_INVALID|CUSTOMER_EMAIL_INVALID|CUSTOMER_EMAIL_MISMATCH|CUSTOMER_PHONE_INVALID|CUSTOMER_PHONE_MISMATCH|CUSTOMER_TAX_ID_INVALID|CUSTOMER_TAX_ID_MISMATCH|CUSTOMER_IDENTITY_AMBIGUOUS|CUSTOMER_IDENTITY_CONFLICT|CUSTOMER_VERIFICATION_REQUIRED|CUSTOMER_VERIFICATION_EMAIL_REQUIRED|CUSTOMER_VERIFICATION_COOLDOWN|CUSTOMER_VERIFICATION_RATE_LIMITED|CUSTOMER_VERIFICATION_NOT_PENDING|CUSTOMER_VERIFICATION_EXPIRED|CUSTOMER_VERIFICATION_ATTEMPTS_EXCEEDED|CUSTOMER_VERIFICATION_CODE_INVALID|CUSTOMER_VERIFICATION_DELIVERY_FAILED|INVALID_PEOPLE_COUNT|INVALID_EXTRA_SELECTION|REQUIRED_EXTRA_MISSING|HOLD_SELECTION_UPDATE_NOT_ALLOWED|HOLD_SELECTION_LOCKED|HOLD_SELECTION_REQUIRES_NEW_SLOT|RESOURCE_NOT_AVAILABLE|SERVICE_HAS_NO_REQUIRED_RESOURCES|HOUR_PACKAGE_NOT_FOUND|HOUR_PACKAGE_NOT_USABLE|HOUR_PACKAGE_INSUFFICIENT_BALANCE|HOUR_PACKAGE_CUSTOMER_MISMATCH|INVALID_COUPON|COUPON_USAGE_LIMIT_REACHED|COUPON_CUSTOMER_MISMATCH|COUPON_CUSTOMER_USAGE_LIMIT_REACHED|COUPON_PACKAGE_POLICY_REQUIRES_DECISION|HOLD_NOT_FOUND|HOLD_EXPIRED|EMAIL_SCOPE_SENDER_NOT_CONFIGURED|EMAIL_PROVIDER_[A-Z0-9_]+)/)?.[1]
    const publicCode = knownCode ?? code.split(':')[0]
    const status = ['RATE_LIMITED', 'CUSTOMER_VERIFICATION_RATE_LIMITED', 'CUSTOMER_VERIFICATION_COOLDOWN'].includes(publicCode) ? 429
      : publicCode === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : ['CHECKOUT_HOLD_NOT_ACTIVE', 'RESOURCE_NOT_AVAILABLE', 'HOLD_SELECTION_REQUIRES_NEW_SLOT', 'COUPON_USAGE_LIMIT_REACHED', 'COUPON_CUSTOMER_USAGE_LIMIT_REACHED'].includes(publicCode) ? 409
      : publicCode.startsWith('EMAIL_') || publicCode === 'CUSTOMER_VERIFICATION_DELIVERY_FAILED' ? 503
      : 400
    await recordOpsEdgeFailure(adminClient, 'booking-checkout', publicCode, status, !knownCode)
    return response({ error: { code: publicCode } }, status)
  }
})
