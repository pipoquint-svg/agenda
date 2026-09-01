export type NotificationTemplate = {
  id: string
  event_key?: string
  title_template: string
  body_template: string
  html_template?: string | null
  variable_schema: unknown
  operation_scope?: string | null
  is_active?: boolean
}

export type NotificationMessage = {
  subject: string
  text: string
  html: string
}

type DeliveryInput = {
  templateId: string | null
  eventKey: string
  audience: 'CUSTOMER' | 'EMPLOYEE'
  appointmentId?: string | null
  customerId?: string | null
  employeeId?: string | null
  recipient: string
  idempotencyKey: string
  payloadSnapshot?: Record<string, unknown>
  isTest?: boolean
}

const MAX_CUSTOM_HTML_BYTES = 90_000
const UNSAFE_HTML_PATTERNS = [
  /<\s*(script|iframe|object|embed|form|base|link|svg|math)\b/i,
  /\son[a-z]+\s*=/i,
  /\bsrcdoc\s*=/i,
  /javascript\s*:/i,
  /data\s*:\s*text\/html/i,
  /<\s*meta\b[^>]*http-equiv\s*=/i,
]

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function maskRecipient(value: string): string {
  const email = value.trim().toLowerCase()
  const at = email.lastIndexOf('@')
  if (at <= 0 || at === email.length - 1) return '***'
  return `${email.slice(0, 1)}***@${email.slice(at + 1)}`
}

function linkify(line: string): string {
  const parts = line.split(/(https:\/\/[^\s]+)/g)
  return parts.map((part) => {
    if (/^https:\/\//i.test(part)) {
      const safe = escapeHtml(part)
      return `<a href="${safe}" style="color:#111;text-decoration:underline;font-weight:600">${safe}</a>`
    }
    return escapeHtml(part)
  }).join('')
}

export function templateVariableKeys(schema: unknown): Set<string> {
  if (!Array.isArray(schema)) return new Set()
  return new Set(schema.map((item) => {
    if (typeof item === 'string') return item.trim()
    if (item && typeof item === 'object' && typeof (item as { key?: unknown }).key === 'string') {
      return String((item as { key: string }).key).trim()
    }
    return ''
  }).filter(Boolean))
}

export function renderTemplate(source: string, schema: unknown, values: Record<string, string>): string {
  const allowed = templateVariableKeys(schema)
  return String(source ?? '').replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, rawKey) => {
    const key = String(rawKey).trim()
    if (!allowed.has(key)) throw new Error(`NOTIFICATION_TEMPLATE_VARIABLE_NOT_ALLOWED:${key}`)
    return values[key] ?? ''
  })
}

export function assertSafeCustomHtml(source: string | null | undefined): void {
  const html = String(source ?? '').trim()
  if (!html) return
  if (new TextEncoder().encode(html).byteLength > MAX_CUSTOM_HTML_BYTES) {
    throw new Error('NOTIFICATION_HTML_TOO_LARGE')
  }
  if (UNSAFE_HTML_PATTERNS.some((pattern) => pattern.test(html))) {
    throw new Error('NOTIFICATION_HTML_UNSAFE')
  }
}

export function renderCustomEmailHtml(
  source: string,
  schema: unknown,
  values: Record<string, string>,
): string {
  assertSafeCustomHtml(source)
  const escapedValues = Object.fromEntries(
    Object.entries(values).map(([key, value]) => [key, escapeHtml(String(value ?? ''))]),
  )
  const rendered = renderTemplate(source, schema, escapedValues).trim()
  if (/<\s*html\b/i.test(rendered)) return rendered
  return `<!doctype html><html lang="pt-BR"><body>${rendered}</body></html>`
}

export function brandedEmailHtml(brandName: string, text: string): string {
  const brand = brandName.trim() || 'BlackSheep'
  const lines = text.split('\n')
  const body = lines.map((line) => line.trim()
    ? `<div style="font-size:15px;line-height:1.65;margin:0 0 8px">${linkify(line)}</div>`
    : '<div style="height:10px;line-height:10px">&nbsp;</div>').join('')

  return `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#111"><div style="max-width:640px;margin:0 auto;padding:24px 14px"><div style="background:#fff;border:1px solid #dedede;border-radius:12px;padding:28px"><div style="font-size:12px;font-weight:700;letter-spacing:.08em;margin:0 0 20px;color:#444">${escapeHtml(brand.toUpperCase())}</div>${body}<div style="border-top:1px solid #ececec;margin-top:24px;padding-top:16px;font-size:12px;color:#777">${escapeHtml(brand)}</div></div></div></body></html>`
}

export function renderNotificationMessage(
  template: NotificationTemplate,
  values: Record<string, string>,
  brandName: string,
): NotificationMessage {
  const subject = renderTemplate(template.title_template, template.variable_schema, values)
  const text = renderTemplate(template.body_template, template.variable_schema, values)
  const customHtml = String(template.html_template ?? '').trim()
  const html = customHtml
    ? renderCustomEmailHtml(customHtml, template.variable_schema, values)
    : brandedEmailHtml(brandName, text)
  return { subject, text, html }
}

export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

export async function beginNotificationDelivery(client: any, input: DeliveryInput): Promise<{ id: string; alreadySent: boolean; providerMessageId: string | null }> {
  const { data: existing, error: lookupError } = await client
    .from('notification_delivery_logs')
    .select('id,status,attempt_count,provider_message_id')
    .eq('idempotency_key', input.idempotencyKey)
    .maybeSingle()
  if (lookupError) throw new Error('NOTIFICATION_DELIVERY_LOG_LOOKUP_FAILED')

  if (existing?.status === 'SENT' || existing?.provider_message_id) {
    return { id: String(existing.id), alreadySent: true, providerMessageId: existing.provider_message_id ?? null }
  }

  const recipientMasked = maskRecipient(input.recipient)
  if (existing) {
    const { error } = await client.from('notification_delivery_logs').update({
      template_id: input.templateId,
      event_key: input.eventKey,
      status: 'PENDING',
      attempt_count: Number(existing.attempt_count ?? 0) + 1,
      last_error_code: null,
      is_test: input.isTest === true,
      recipient_masked: recipientMasked,
      updated_at: new Date().toISOString(),
    })
      .eq('id', existing.id)
      .neq('status', 'SENT')
      .is('provider_message_id', null)
    if (error) throw new Error('NOTIFICATION_DELIVERY_LOG_UPDATE_FAILED')
    return { id: String(existing.id), alreadySent: false, providerMessageId: null }
  }

  const recipientHash = await sha256(input.recipient)
  const { data: inserted, error } = await client.from('notification_delivery_logs').insert({
    template_id: input.templateId,
    event_key: input.eventKey,
    channel: 'EMAIL',
    audience: input.audience,
    appointment_id: input.appointmentId ?? null,
    customer_id: input.customerId ?? null,
    employee_id: input.employeeId ?? null,
    recipient_hash: recipientHash,
    recipient_masked: recipientMasked,
    status: 'PENDING',
    attempt_count: 1,
    idempotency_key: input.idempotencyKey,
    payload_snapshot: input.payloadSnapshot ?? {},
    is_test: input.isTest === true,
  }).select('id').single()
  if (error || !inserted) throw new Error('NOTIFICATION_DELIVERY_LOG_INSERT_FAILED')
  return { id: String(inserted.id), alreadySent: false, providerMessageId: null }
}

export async function markNotificationSent(client: any, logId: string, providerMessageId: string | null): Promise<void> {
  const { error } = await client.from('notification_delivery_logs').update({
    status: 'SENT',
    provider_message_id: providerMessageId,
    last_error_code: null,
    updated_at: new Date().toISOString(),
  }).eq('id', logId)
  if (error) throw new Error('NOTIFICATION_DELIVERY_LOG_SENT_FAILED')
}

export async function markNotificationFailed(client: any, logId: string, error: unknown): Promise<void> {
  const code = error instanceof Error ? error.message : 'EMAIL_PROVIDER_FAILED'
  await client.from('notification_delivery_logs').update({
    status: 'FAILED',
    last_error_code: code.slice(0, 120),
    updated_at: new Date().toISOString(),
  })
    .eq('id', logId)
    .neq('status', 'SENT')
    .is('provider_message_id', null)
}
