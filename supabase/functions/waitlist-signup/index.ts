import { adminClient } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { isRecipientAllowed, isScopeEnabled, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function enabled(name: string): boolean {
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

async function eligibleTeamEmails(client: any): Promise<string[]> {
  const { data: admins, error } = await client
    .from('admin_users')
    .select('id,auth_user_id,is_active')
    .eq('is_active', true)
  if (error) throw new Error('WAITLIST_TEAM_LOOKUP_FAILED')

  const emails = new Set<string>()
  for (const admin of admins ?? []) {
    if (!admin.auth_user_id) continue
    const { data: allowed, error: permissionError } = await client.rpc('service_admin_has_permission', {
      p_admin_id: admin.id,
      p_permission: 'WAITLIST_VIEW',
    })
    if (permissionError) throw new Error('WAITLIST_TEAM_PERMISSION_LOOKUP_FAILED')
    if (allowed !== true) continue

    const { data: authData, error: authError } = await client.auth.admin.getUserById(admin.auth_user_id)
    if (authError || !authData?.user) continue
    const email = normalizedEmail(authData.user.email)
    if (email && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) emails.add(email)
  }
  return [...emails]
}

async function notifyTeam(client: any, signup: Record<string, unknown>): Promise<{ sent: boolean; recipients: number }> {
  const scope = String(signup.operation_scope ?? '').trim().toUpperCase()
  const serviceId = String(signup.service_id ?? '').trim()
  const idempotencyKey = String(signup.notification_idempotency_key ?? '').trim()
  if (!serviceId || !idempotencyKey) throw new Error('WAITLIST_NOTIFICATION_CONTEXT_INVALID')

  if (!enabled('TRANSACTIONAL_EMAIL_ENABLED')) throw new Error('TRANSACTIONAL_EMAIL_DISABLED')
  if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) throw new Error('EMAIL_SCOPE_DISABLED')
  const sender = notificationSenderForScope(scope)
  if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

  const recipients = (await eligibleTeamEmails(client)).filter((email) =>
    isRecipientAllowed(email, enabled('ALLOW_REAL_EMAIL_RECIPIENTS'), Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))
  )
  if (recipients.length === 0) throw new Error('WAITLIST_TEAM_EMAIL_MISSING')

  const { data: rows, error: resolverError } = await client.rpc('resolve_notification_template_v2', {
    p_event_key: 'WAITLIST_SIGNUP_TEAM',
    p_channel: 'EMAIL',
    p_audience: 'EMPLOYEE',
    p_service_id: serviceId,
  })
  if (resolverError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
  const template = (Array.isArray(rows) ? rows[0] : null) as NotificationTemplate | null
  if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')

  const values: Record<string, string> = {
    'service.name': String(signup.service_name ?? ''),
    'waitlist.name': String(signup.name ?? ''),
    'waitlist.email': String(signup.email ?? ''),
    'waitlist.whatsapp': String(signup.whatsapp ?? ''),
    'waitlist.created_at': dateTime(signup.created_at),
  }
  const message = renderNotificationMessage(template, values, sender.brandName)
  const delivery = await beginNotificationDelivery(client, {
    templateId: template.id,
    eventKey: 'WAITLIST_SIGNUP_TEAM',
    audience: 'EMPLOYEE',
    customerId: typeof signup.customer_id === 'string' ? signup.customer_id : null,
    recipient: recipients[0],
    idempotencyKey,
    payloadSnapshot: {
      waitlist_entry_id: signup.id,
      service_id: serviceId,
      operation_scope: scope,
      recipient_count: recipients.length,
    },
  })
  if (delivery.alreadySent) return { sent: true, recipients: recipients.length }

  const providerPayload: EmailProviderPayload = {
    from: sender.from,
    to: recipients,
    subject: message.subject,
    text: message.text,
    html: message.html,
  }
  if (sender.replyTo) providerPayload.reply_to = sender.replyTo

  try {
    const providerMessageId = await sendEmailWithProvider(providerPayload, idempotencyKey)
    await markNotificationSent(client, delivery.id, providerMessageId)
    return { sent: true, recipients: recipients.length }
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'WAITLIST_SIGNUP',
      limit: 12,
      windowSeconds: 600,
    })

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const { data, error } = await client.rpc('public_create_service_waitlist_entry', {
      p_booking_page_slug: String(body.booking_page_slug ?? ''),
      p_service_id: String(body.service_id ?? ''),
      p_name: String(body.name ?? ''),
      p_email: String(body.email ?? ''),
      p_whatsapp: String(body.whatsapp ?? ''),
    })
    if (error) {
      const known = error.message.match(/(WAITLIST_ALREADY_REGISTERED|WAITLIST_NAME_INVALID|WAITLIST_EMAIL_INVALID|WAITLIST_WHATSAPP_INVALID|WAITLIST_FIXED_ONLY|PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE)/)?.[1]
      throw new Error(known ?? 'WAITLIST_SIGNUP_FAILED')
    }

    const signup = data as Record<string, unknown>
    // The waitlist entry is authoritative even if the operational e-mail provider is
    // temporarily unavailable. The delivery log remains FAILED for team follow-up.
    let notification: { sent: boolean; recipients: number } | { sent: false; recipients: 0; error: string }
    try {
      const { data: entry } = await client.from('service_waitlist_entries')
        .select('id,name,email,whatsapp,created_at,customer_id,service_id')
        .eq('id', String(signup.id)).single()
      notification = await notifyTeam(client, { ...signup, ...entry })
    } catch (notifyError) {
      const code = notifyError instanceof Error ? notifyError.message : 'WAITLIST_NOTIFICATION_FAILED'
      const { data: pending } = await client.from('notification_delivery_logs')
        .select('id').eq('idempotency_key', String(signup.notification_idempotency_key ?? '')).maybeSingle()
      if (pending?.id) await markNotificationFailed(client, String(pending.id), new Error(code))
      notification = { sent: false, recipients: 0, error: code }
    }

    return response({
      ok: true,
      waitlist_entry_id: signup.id,
      created_at: signup.created_at,
      notification: { sent: notification.sent, recipients: notification.recipients },
      message: 'Inscrição recebida. Nossa equipe entrará em contato.',
    }, 201)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'WAITLIST_SIGNUP_FAILED'
    const status = code === 'WAITLIST_ALREADY_REGISTERED' ? 409
      : code === 'RATE_LIMITED' ? 429
      : code === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : 400
    return response({ error: { code } }, status)
  }
})