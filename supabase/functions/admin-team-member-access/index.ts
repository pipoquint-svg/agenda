import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

const INVITE_EVENT = 'ADMIN_USER_INVITE'
const OPERATION_SCOPE = 'BLACKSHEEP'
const OFFICIAL_SITE_URL = 'https://www.blacksheepestudiocriativo.com.br'
const DEFAULT_FROM = 'BlackSheep Estúdio Criativo <agenda@blacksheepestudiocriativo.com.br>'
const RESEND_ENDPOINT = 'https://api.resend.com/emails'

type AdminRow = {
  id: string
  auth_user_id: string
  display_name: string
  role: string
  is_active: boolean
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function secretKey(): string {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim()
  if (legacy) return legacy

  const raw = Deno.env.get('SUPABASE_SECRET_KEYS')?.trim()
  if (!raw) throw new Error('MISSING_ENV:SUPABASE_SECRET_KEYS')
  const parsed = JSON.parse(raw)
  const value = parsed.default ?? Object.values(parsed)[0]
  if (typeof value !== 'string' || !value) throw new Error('INVALID_ENV:SUPABASE_SECRET_KEYS')
  return value
}

function adminClient(): SupabaseClient {
  return createClient(requiredEnv('SUPABASE_URL'), secretKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  })
}

function uuid(value: unknown): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)) {
    throw new Error('ADMIN_USER_ID_INVALID')
  }
  return text
}

function normalizedEmail(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

function maskEmail(value: string): string {
  const email = normalizedEmail(value)
  const at = email.lastIndexOf('@')
  if (at <= 0 || at === email.length - 1) return '***'
  return `${email.slice(0, 1)}***@${email.slice(at + 1)}`
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function render(source: string, values: Record<string, string>): string {
  return String(source ?? '').replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, rawKey) => {
    const key = String(rawKey).trim()
    return values[key] ?? ''
  })
}

function brandedHtml(brandName: string, text: string): string {
  const lines = text.split('\n').map((line) => {
    const trimmed = line.trim()
    if (!trimmed) return '<div style="height:10px;line-height:10px">&nbsp;</div>'
    const parts = trimmed.split(/(https:\/\/[^\s]+)/g)
    const html = parts.map((part) => /^https:\/\//i.test(part)
      ? `<a href="${escapeHtml(part)}" style="color:#111;text-decoration:underline;font-weight:600">${escapeHtml(part)}</a>`
      : escapeHtml(part)).join('')
    return `<div style="font-size:15px;line-height:1.65;margin:0 0 8px">${html}</div>`
  }).join('')

  return `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#111"><div style="max-width:640px;margin:0 auto;padding:24px 14px"><div style="background:#fff;border:1px solid #dedede;border-radius:12px;padding:28px"><div style="font-size:12px;font-weight:700;letter-spacing:.08em;margin:0 0 20px;color:#444">${escapeHtml(brandName.toUpperCase())}</div>${lines}<div style="border-top:1px solid #ececec;margin-top:24px;padding-top:16px;font-size:12px;color:#777">${escapeHtml(brandName)}</div></div></div></body></html>`
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

async function requireTeamManager(req: Request, client: SupabaseClient): Promise<{ adminId: string; role: string }> {
  const { adminId } = await requireAdminPermission(req, 'TEAM_MANAGE')
  const { data: actor, error: actorError } = await client
    .from('admin_users')
    .select('role,is_active')
    .eq('id', adminId)
    .maybeSingle()
  if (actorError || !actor?.is_active) throw new Error('ADMIN_ACCESS_DENIED')

  return { adminId, role: String(actor.role ?? '') }
}

async function loadTarget(client: SupabaseClient, memberId: string): Promise<AdminRow> {
  const { data, error } = await client
    .from('admin_users')
    .select('id,auth_user_id,display_name,role,is_active')
    .eq('id', memberId)
    .maybeSingle()
  if (error) throw new Error('ADMIN_TARGET_QUERY_FAILED')
  if (!data) throw new Error('ADMIN_USER_NOT_FOUND')
  return data as AdminRow
}

async function reactivateMember(req: Request, client: SupabaseClient, memberId: string): Promise<Response> {
  const actor = await requireTeamManager(req, client)
  const target = await loadTarget(client, memberId)
  if (target.role === 'OWNER' && actor.role !== 'OWNER') throw new Error('ADMIN_OWNER_REQUIRED')

  const authLookup = await client.auth.admin.getUserById(target.auth_user_id)
  if (authLookup.error || !authLookup.data.user) throw new Error('ADMIN_AUTH_USER_NOT_FOUND')

  const wasActive = target.is_active === true
  const { error: unbanError } = await client.auth.admin.updateUserById(target.auth_user_id, { ban_duration: 'none' })
  if (unbanError) throw new Error('ADMIN_AUTH_UNBAN_FAILED')

  if (!wasActive) {
    const { error: activateError } = await client
      .from('admin_users')
      .update({ is_active: true, updated_at: new Date().toISOString() })
      .eq('id', target.id)
      .eq('auth_user_id', target.auth_user_id)

    if (activateError) {
      await client.auth.admin.updateUserById(target.auth_user_id, { ban_duration: '876000h' }).catch(() => undefined)
      throw new Error('ADMIN_USER_REACTIVATE_FAILED')
    }

    try {
      await client.from('audit_logs').insert({
        admin_user_id: actor.adminId,
        entity_type: 'ADMIN_USER',
        entity_id: target.id,
        action: 'USER_REACTIVATED',
        before_json: { is_active: false },
        after_json: { is_active: true },
        origin: 'ADMIN',
      })
    } catch {
      // Audit remains best-effort and must not undo a successful reactivation.
    }
  }

  return json({
    member_id: target.id,
    is_active: true,
    access_restored: true,
    already_active: wasActive,
  })
}

async function resendInvite(req: Request, client: SupabaseClient, memberId: string): Promise<Response> {
  const actor = await requireTeamManager(req, client)
  const target = await loadTarget(client, memberId)
  if (!target.is_active) throw new Error('ADMIN_TARGET_INACTIVE')
  if (target.role === 'OWNER' && actor.role !== 'OWNER') throw new Error('ADMIN_OWNER_REQUIRED')

  const authLookup = await client.auth.admin.getUserById(target.auth_user_id)
  if (authLookup.error || !authLookup.data.user) throw new Error('ADMIN_AUTH_USER_NOT_FOUND')
  const authUser = authLookup.data.user
  const memberEmail = normalizedEmail(authUser.email)
  if (!memberEmail) throw new Error('ADMIN_EMAIL_INVALID')
  if (authUser.email_confirmed_at || authUser.last_sign_in_at) throw new Error('ADMIN_INVITE_ALREADY_COMPLETED')

  const redirectTo = `${OFFICIAL_SITE_URL}/gestao/primeiro-acesso`
  const { data: linkData, error: linkError } = await client.auth.admin.generateLink({
    type: 'magiclink',
    email: memberEmail,
    options: { redirectTo },
  })
  if (linkError || !linkData?.properties?.action_link) throw new Error('ADMIN_INVITE_LINK_CREATE_FAILED')

  const [{ data: template, error: templateError }, { data: operationSettings, error: operationError }] = await Promise.all([
    client.from('notification_template_configs')
      .select('id,title_template,body_template')
      .eq('event_key', INVITE_EVENT)
      .eq('channel', 'EMAIL')
      .eq('audience', 'EMPLOYEE')
      .eq('operation_scope', OPERATION_SCOPE)
      .eq('is_active', true)
      .is('category_id', null)
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    client.rpc('service_admin_get_operation_settings_v2', { p_operation_scope: OPERATION_SCOPE }),
  ])
  if (templateError || !template) throw new Error('ADMIN_INVITE_TEMPLATE_NOT_FOUND')
  if (operationError) throw new Error('ADMIN_INVITE_OPERATION_SETTINGS_FAILED')

  const brandName = String(operationSettings?.public_name ?? 'BlackSheep Estúdio Criativo')
  const values: Record<string, string> = {
    'employee.name': target.display_name,
    'auth.invite_url': linkData.properties.action_link,
    'operation.name': brandName,
    'operation.site_url': OFFICIAL_SITE_URL,
  }
  const subject = render(String(template.title_template ?? 'Convite de acesso'), values)
  const text = render(String(template.body_template ?? ''), values)
  const html = brandedHtml(brandName, text)

  const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() || DEFAULT_FROM
  const replyTo = Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim() || undefined
  const idempotencyKey = `admin-user-invite:${target.auth_user_id}:resend:${crypto.randomUUID()}`
  const recipientHash = await sha256(memberEmail)

  const { data: delivery, error: deliveryError } = await client.from('notification_delivery_logs').insert({
    template_id: template.id,
    event_key: INVITE_EVENT,
    channel: 'EMAIL',
    audience: 'EMPLOYEE',
    recipient_hash: recipientHash,
    recipient_masked: maskEmail(memberEmail),
    status: 'PENDING',
    attempt_count: 1,
    idempotency_key: idempotencyKey,
    payload_snapshot: { admin_user_id: target.id, role: target.role, operation_scope: OPERATION_SCOPE, resend: true },
    is_test: false,
  }).select('id').single()
  if (deliveryError || !delivery) throw new Error('NOTIFICATION_DELIVERY_LOG_INSERT_FAILED')

  try {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 15_000)
    let response: Response
    try {
      response = await fetch(RESEND_ENDPOINT, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${requiredEnv('RESEND_API_KEY')}`,
          'content-type': 'application/json',
          'idempotency-key': idempotencyKey,
        },
        body: JSON.stringify({ from, to: [memberEmail], subject, text, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
        signal: controller.signal,
      })
    } finally {
      clearTimeout(timeout)
    }

    const responseText = await response.text()
    if (!response.ok) throw new Error(`EMAIL_PROVIDER_HTTP_${response.status}`)
    let providerMessageId: string | null = null
    if (responseText) {
      try {
        const parsed = JSON.parse(responseText)
        providerMessageId = typeof parsed?.id === 'string' ? parsed.id : null
      } catch {
        throw new Error('EMAIL_PROVIDER_INVALID_RESPONSE')
      }
    }

    await client.from('notification_delivery_logs').update({
      status: 'SENT',
      provider_message_id: providerMessageId,
      last_error_code: null,
      updated_at: new Date().toISOString(),
    }).eq('id', delivery.id)

    try {
      await client.from('audit_logs').insert({
        admin_user_id: actor.adminId,
        entity_type: 'ADMIN_USER',
        entity_id: target.id,
        action: 'USER_INVITE_RESENT',
        before_json: null,
        after_json: { recipient_masked: maskEmail(memberEmail) },
        origin: 'ADMIN',
      })
    } catch {
      // Audit remains best-effort and must not turn a successful send into a failure.
    }

    return json({
      member_id: target.id,
      invite_email_sent: true,
      recipient_masked: maskEmail(memberEmail),
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'EMAIL_PROVIDER_FAILED'
    await client.from('notification_delivery_logs').update({
      status: 'FAILED',
      last_error_code: code.slice(0, 120),
      updated_at: new Date().toISOString(),
    }).eq('id', delivery.id)
    throw error
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const memberId = uuid(body.member_id)
    const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
    const client = adminClient()

    if (action === 'REACTIVATE') return await reactivateMember(req, client, memberId)
    if (action === 'RESEND_INVITE') return await resendInvite(req, client, memberId)
    throw new Error('ADMIN_TEAM_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_TEAM_ACCESS_FAILED'
    const status = code === 'ADMIN_AUTH_REQUIRED' || code === 'ADMIN_AUTH_INVALID' || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_OWNER_REQUIRED' ? 403
      : code === 'ADMIN_USER_NOT_FOUND' || code === 'ADMIN_AUTH_USER_NOT_FOUND' ? 404
      : code === 'ADMIN_TARGET_INACTIVE' || code === 'ADMIN_INVITE_ALREADY_COMPLETED' ? 409
      : code.startsWith('EMAIL_PROVIDER_') || code === 'ADMIN_AUTH_UNBAN_FAILED' ? 502
      : 400
    return json({ error: { code } }, status)
  }
})
