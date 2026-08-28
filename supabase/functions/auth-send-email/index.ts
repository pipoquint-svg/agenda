import { Webhook } from 'https://esm.sh/standardwebhooks@1.0.0'
import {
  emailProviderName,
  senderForScope,
  sendEmailWithProvider,
  type EmailProviderPayload,
} from '../_shared/email-provider.ts'

type AuthUser = {
  id: string
  email: string
  new_email?: string
}

type AuthEmailData = {
  token: string
  token_hash: string
  redirect_to: string
  email_action_type: string
  site_url: string
  token_new: string
  token_hash_new: string
  old_email?: string
  provider?: string
  factor_type?: string
}

type AuthHookPayload = {
  user: AuthUser
  email_data: AuthEmailData
}

type Delivery = {
  to: string
  token: string
  tokenHash: string
  variant?: 'current' | 'new'
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

function verificationUrl(emailData: AuthEmailData, tokenHash: string): string {
  const url = new URL('/auth/v1/verify', requiredEnv('SUPABASE_URL'))
  url.searchParams.set('token', tokenHash)
  url.searchParams.set('type', emailData.email_action_type)
  const redirectTo = emailData.redirect_to?.trim() || emailData.site_url?.trim()
  if (redirectTo) url.searchParams.set('redirect_to', redirectTo)
  return url.toString()
}

function deliveriesFor(payload: AuthHookPayload): Delivery[] {
  const { user, email_data: data } = payload
  if (data.email_action_type === 'email_change' && user.new_email) {
    if (data.token_hash_new && data.token_hash && data.token_new) {
      return [
        { to: user.email, token: data.token, tokenHash: data.token_hash_new, variant: 'current' },
        { to: user.new_email, token: data.token_new, tokenHash: data.token_hash, variant: 'new' },
      ]
    }
    return [{
      to: user.new_email,
      token: data.token_new || data.token,
      tokenHash: data.token_hash,
      variant: 'new',
    }]
  }
  return [{ to: user.email, token: data.token, tokenHash: data.token_hash }]
}

function contentFor(
  payload: AuthHookPayload,
  delivery: Delivery,
  brandName: string,
): { subject: string; text: string; html: string } {
  const action = payload.email_data.email_action_type
  const hasVerificationLink = ['signup', 'invite', 'magiclink', 'recovery', 'email_change', 'email'].includes(action)
  const link = hasVerificationLink && delivery.tokenHash
    ? verificationUrl(payload.email_data, delivery.tokenHash)
    : ''

  let subject = `Notificação de acesso | ${brandName}`
  let heading = 'Notificação de segurança'
  let instruction = 'Houve uma atualização relacionada ao seu acesso.'
  let button = ''

  switch (action) {
    case 'recovery':
      subject = `Redefina sua senha | ${brandName}`
      heading = 'Redefinição de senha'
      instruction = 'Recebemos uma solicitação para redefinir sua senha. Use o link abaixo para criar uma nova senha.'
      button = 'Criar nova senha'
      break
    case 'invite':
      subject = `Convite de acesso | ${brandName}`
      heading = 'Convite de acesso'
      instruction = 'Você recebeu um convite para acessar o sistema.'
      button = 'Aceitar convite'
      break
    case 'signup':
    case 'email':
      subject = `Confirme seu e-mail | ${brandName}`
      heading = 'Confirmação de e-mail'
      instruction = 'Confirme seu endereço de e-mail para concluir o acesso.'
      button = 'Confirmar e-mail'
      break
    case 'magiclink':
      subject = `Seu link de acesso | ${brandName}`
      heading = 'Link de acesso'
      instruction = 'Use o link abaixo para acessar o sistema.'
      button = 'Acessar'
      break
    case 'email_change':
      subject = `Confirme a alteração de e-mail | ${brandName}`
      heading = 'Alteração de e-mail'
      instruction = delivery.variant === 'current'
        ? 'Confirme a alteração solicitada a partir do seu endereço de e-mail atual.'
        : 'Confirme este endereço como o novo e-mail da sua conta.'
      button = 'Confirmar alteração'
      break
    case 'reauthentication':
      subject = `Código de verificação | ${brandName}`
      heading = 'Verificação de segurança'
      instruction = `Seu código de verificação é: ${delivery.token}`
      break
    case 'password_changed_notification':
      subject = `Senha alterada | ${brandName}`
      heading = 'Sua senha foi alterada'
      instruction = 'A senha da sua conta foi alterada. Se você não realizou essa alteração, entre em contato com a equipe imediatamente.'
      break
    case 'email_changed_notification':
      subject = `E-mail alterado | ${brandName}`
      heading = 'Seu e-mail foi alterado'
      instruction = 'O endereço de e-mail da sua conta foi alterado. Se você não realizou essa alteração, entre em contato com a equipe imediatamente.'
      break
    case 'phone_changed_notification':
      subject = `Telefone alterado | ${brandName}`
      heading = 'Seu telefone foi alterado'
      instruction = 'O telefone associado à sua conta foi alterado.'
      break
    case 'identity_linked_notification':
      subject = `Identidade vinculada | ${brandName}`
      heading = 'Nova identidade vinculada'
      instruction = 'Uma nova identidade de acesso foi vinculada à sua conta.'
      break
    case 'identity_unlinked_notification':
      subject = `Identidade removida | ${brandName}`
      heading = 'Identidade de acesso removida'
      instruction = 'Uma identidade de acesso foi removida da sua conta.'
      break
    case 'mfa_factor_enrolled_notification':
      subject = `Verificação em duas etapas ativada | ${brandName}`
      heading = 'Verificação em duas etapas ativada'
      instruction = 'Um novo fator de autenticação foi ativado na sua conta.'
      break
    case 'mfa_factor_unenrolled_notification':
      subject = `Verificação em duas etapas alterada | ${brandName}`
      heading = 'Fator de autenticação removido'
      instruction = 'Um fator de autenticação foi removido da sua conta.'
      break
  }

  const textLines = [heading, '', instruction]
  if (link) textLines.push('', `${button || 'Continuar'}: ${link}`)
  if (delivery.token && ['signup', 'invite', 'magiclink', 'recovery', 'reauthentication'].includes(action)) {
    textLines.push('', `Código: ${delivery.token}`)
  }
  textLines.push('', 'Se você não solicitou esta ação, ignore esta mensagem.', '', brandName)
  const text = textLines.join('\n')

  const safeLink = escapeHtml(link)
  const linkHtml = link
    ? `<p style="margin:24px 0"><a href="${safeLink}" style="display:inline-block;background:#111;color:#fff;text-decoration:none;font-weight:700;padding:13px 18px;border-radius:8px">${escapeHtml(button || 'Continuar')}</a></p>`
    : ''
  const codeHtml = delivery.token && ['signup', 'invite', 'magiclink', 'recovery', 'reauthentication'].includes(action)
    ? `<p style="font-size:14px;color:#444">Código: <strong>${escapeHtml(delivery.token)}</strong></p>`
    : ''

  const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#111"><div style="max-width:620px;margin:0 auto;padding:24px 14px"><div style="background:#fff;border:1px solid #ddd;border-radius:12px;padding:28px"><div style="font-size:13px;font-weight:700;letter-spacing:.04em;margin-bottom:12px">${escapeHtml(brandName.toUpperCase())}</div><h1 style="font-size:24px;line-height:1.2;margin:0 0 16px">${escapeHtml(heading)}</h1><p style="font-size:16px;line-height:1.55;margin:0">${escapeHtml(instruction)}</p>${linkHtml}${codeHtml}<p style="font-size:13px;line-height:1.5;color:#666;margin:24px 0 0">Se você não solicitou esta ação, ignore esta mensagem.</p></div></div></body></html>`
  return { subject, text, html }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('METHOD_NOT_ALLOWED', { status: 405 })

  const rawPayload = await req.text()
  try {
    const hookSecret = requiredEnv('SEND_EMAIL_HOOK_SECRET').replace(/^v1,whsec_/, '')
    const webhook = new Webhook(hookSecret)
    const payload = webhook.verify(rawPayload, Object.fromEntries(req.headers)) as AuthHookPayload

    if (!payload?.user?.id || !payload.user.email || !payload?.email_data?.email_action_type) {
      throw new Error('AUTH_EMAIL_HOOK_PAYLOAD_INVALID')
    }

    const scope = (Deno.env.get('AUTH_EMAIL_OPERATION_SCOPE') ?? 'BLACKSHEEP').trim().toUpperCase()
    const sender = senderForScope(scope)
    if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

    const payloadHash = await sha256(rawPayload)
    const deliveries = deliveriesFor(payload)
    for (let index = 0; index < deliveries.length; index += 1) {
      const delivery = deliveries[index]
      const message = contentFor(payload, delivery, sender.brandName)
      const providerPayload: EmailProviderPayload = {
        from: sender.from,
        to: [delivery.to],
        subject: message.subject,
        text: message.text,
        html: message.html,
      }
      if (sender.replyTo) providerPayload.reply_to = sender.replyTo
      await sendEmailWithProvider(
        providerPayload,
        `auth:${payload.user.id}:${payload.email_data.email_action_type}:${payloadHash}:${index}`,
      )
    }

    console.log('Auth email delivered', {
      provider: emailProviderName(),
      action: payload.email_data.email_action_type,
      deliveries: deliveries.length,
    })
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'AUTH_EMAIL_HOOK_FAILED'
    console.error('Auth email hook failed', { code: message })
    return new Response(JSON.stringify({ error: { http_code: 401, message } }), {
      status: 401,
      headers: { 'content-type': 'application/json' },
    })
  }
})
