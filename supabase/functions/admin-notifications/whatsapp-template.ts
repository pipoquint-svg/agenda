export type WhatsAppCategory = 'UTILITY' | 'MARKETING'

export type WhatsAppTemplateDefinition = {
  name: string
  language: 'pt_BR'
  category: WhatsAppCategory
  body_text: string
  body_examples: string[]
  header_text: string | null
  header_example: string | null
  footer_text: string | null
  ttl_seconds: number | null
  button_text: string | null
  button_url: string | null
  button_example: string | null
}

export type WhatsAppSettings = {
  category: WhatsAppCategory
  header_text: string | null
  footer_text: string | null
  ttl_seconds: number | null
  /** Admin-provided sample per variable; missing ones fall back to defaults. */
  variable_examples: Record<string, string>
  /** Optional URL button: its label and the customer link it opens. */
  button_text: string | null
  button_variable: string | null
}

/** Customer links a URL button may open. */
export const WHATSAPP_BUTTON_VARIABLES = [
  'appointment.manage_url',
  'pre_reservation.payment_url',
  'balance.payment_url',
  'payment.resume_url',
  'booking.url',
]
const MAX_BUTTON_TEXT_LENGTH = 25

/** Validity choices offered to admins; Meta accepts 30 s to 12 h for utility. */
export const WHATSAPP_TTL_OPTIONS = [600, 1800, 3600, 10800, 21600, 43200]
const MAX_HEADER_LENGTH = 60
const MAX_FOOTER_LENGTH = 60

function optionalLine(value: unknown, max: number, code: string): string | null {
  if (value === null || value === undefined) return null
  if (typeof value !== 'string') throw new Error(code)
  const text = value.trim()
  if (!text) return null
  if (text.length > max || /[\r\n]/.test(text)) throw new Error(code)
  return text
}

/** Validates the WhatsApp-only fields an admin saves on a draft. */
export function whatsappSettings(value: unknown, catalog: string[]): WhatsAppSettings {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('WHATSAPP_SETTINGS_INVALID')
  const source = value as Record<string, unknown>
  const category = String(source.category ?? '').toUpperCase()
  if (category !== 'UTILITY' && category !== 'MARKETING') throw new Error('WHATSAPP_CATEGORY_INVALID')
  const header = optionalLine(source.header_text, MAX_HEADER_LENGTH, 'WHATSAPP_HEADER_INVALID')
  if (header) {
    const keys = [...header.matchAll(VARIABLE)].map((match) => match[1].trim())
    if (keys.length > 1) throw new Error('WHATSAPP_HEADER_VARIABLE_LIMIT')
    if (keys.some((key) => !catalog.includes(key))) throw new Error('WHATSAPP_TEMPLATE_VARIABLE_INVALID')
  }
  const footer = optionalLine(source.footer_text, MAX_FOOTER_LENGTH, 'WHATSAPP_FOOTER_INVALID')
  if (footer?.includes('{{')) throw new Error('WHATSAPP_FOOTER_VARIABLE')
  const ttl = source.ttl_seconds === null || source.ttl_seconds === undefined || source.ttl_seconds === '' ? null : Number(source.ttl_seconds)
  if (ttl !== null && (category !== 'UTILITY' || !WHATSAPP_TTL_OPTIONS.includes(ttl))) throw new Error('WHATSAPP_TTL_INVALID')
  const buttonText = optionalLine(source.button_text, MAX_BUTTON_TEXT_LENGTH, 'WHATSAPP_BUTTON_INVALID')
  const buttonVariable = typeof source.button_variable === 'string' && source.button_variable.trim() ? source.button_variable.trim() : null
  if (Boolean(buttonText) !== Boolean(buttonVariable) || buttonText?.includes('{{')) throw new Error('WHATSAPP_BUTTON_INVALID')
  if (buttonVariable && (!WHATSAPP_BUTTON_VARIABLES.includes(buttonVariable) || !catalog.includes(buttonVariable))) {
    throw new Error('WHATSAPP_BUTTON_LINK_INVALID')
  }
  return {
    category,
    header_text: header,
    footer_text: footer,
    ttl_seconds: ttl,
    variable_examples: variableExamples(source.variable_examples, catalog),
    button_text: buttonText,
    button_variable: buttonVariable,
  }
}

function variableExamples(value: unknown, catalog: string[]) {
  if (value === null || value === undefined) return {}
  if (typeof value !== 'object' || Array.isArray(value)) throw new Error('WHATSAPP_EXAMPLES_INVALID')
  const examples: Record<string, string> = {}
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (!catalog.includes(key) || typeof raw !== 'string') throw new Error('WHATSAPP_EXAMPLES_INVALID')
    const example = raw.trim()
    if (!example) continue
    if (example.length > MAX_EXAMPLE_LENGTH || /[\r\n\t]/.test(example)) throw new Error('WHATSAPP_EXAMPLE_INVALID')
    examples[key] = example
  }
  return examples
}

export type SubmissionStatus = 'PENDING_REVIEW' | 'APPROVED' | 'REJECTED' | 'FAILED'

const MAX_BODY_LENGTH = 1024
const MAX_EXAMPLE_LENGTH = 200
const VARIABLE = /\{\{\s*([^}]+?)\s*\}\}/g

/** Birthday and manual messages promote; everything else follows a booking. */
export function whatsappCategory(eventKey: string): WhatsAppCategory {
  return eventKey === 'BIRTHDAY' || eventKey === 'MANUAL' || eventKey.startsWith('REWARDS_') ? 'MARKETING' : 'UTILITY'
}

async function shortHash(value: string) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))
  return Array.from(bytes.slice(0, 4), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/**
 * Converts an Agenda draft into Meta's format: named variables become numbered
 * parameters in order of first use, each with a sample value. The name is
 * derived from the content, so the same text always maps to the same Meta
 * template and an edited draft maps to a new one.
 */
export async function whatsappTemplateDefinition(input: {
  templateId: string
  eventKey: string
  body: string
  catalog: string[]
  examples: Record<string, string>
  settings?: WhatsAppSettings | null
  /** Fixed URL with {{1}} and a full sample for a customer link button. */
  buttonLink?: (variable: string) => { url: string; example: string }
}): Promise<WhatsAppTemplateDefinition> {
  const examples = { ...input.examples, ...(input.settings?.variable_examples ?? {}) }
  const source = input.body.trim()
  if (!source) throw new Error('WHATSAPP_TEMPLATE_BODY_REQUIRED')
  const order: string[] = []
  const bodyText = source.replace(VARIABLE, (_match, rawKey: string) => {
    const key = rawKey.trim()
    if (!input.catalog.includes(key)) throw new Error('WHATSAPP_TEMPLATE_VARIABLE_INVALID')
    if (!order.includes(key)) order.push(key)
    return `{{${order.indexOf(key) + 1}}}`
  })
  if (bodyText.length > MAX_BODY_LENGTH) throw new Error('WHATSAPP_TEMPLATE_BODY_TOO_LONG')
  if (/^\{\{\d+\}\}/.test(bodyText) || /\{\{\d+\}\}$/.test(bodyText)) {
    throw new Error('WHATSAPP_TEMPLATE_PARAMETER_EDGE')
  }
  const bodyExamples = order.map((key) => {
    const example = String(examples[key] ?? '').replace(/\s+/g, ' ').trim()
    if (!example) throw new Error('WHATSAPP_TEMPLATE_EXAMPLE_MISSING')
    return example.slice(0, MAX_EXAMPLE_LENGTH)
  })
  const settings = input.settings ?? null
  const category = settings?.category ?? whatsappCategory(input.eventKey)
  // The header has its own numbering and accepts a single variable.
  let headerKey: string | null = null
  const headerText = settings?.header_text
    ? settings.header_text.replace(VARIABLE, (_match, rawKey: string) => {
      const key = rawKey.trim()
      if (!input.catalog.includes(key)) throw new Error('WHATSAPP_TEMPLATE_VARIABLE_INVALID')
      if (headerKey !== null) throw new Error('WHATSAPP_HEADER_VARIABLE_LIMIT')
      headerKey = key
      return '{{1}}'
    })
    : null
  let headerExample: string | null = null
  if (headerKey !== null) {
    headerExample = String(examples[headerKey] ?? '').replace(/\s+/g, ' ').trim().slice(0, MAX_EXAMPLE_LENGTH)
    if (!headerExample) throw new Error('WHATSAPP_TEMPLATE_EXAMPLE_MISSING')
  }
  const footerText = settings?.footer_text ?? null
  const ttlSeconds = category === 'UTILITY' ? settings?.ttl_seconds ?? null : null
  const id = input.templateId.replace(/-/g, '').slice(0, 8).toLowerCase()
  const event = input.eventKey.toLowerCase().replace(/[^a-z0-9_]/g, '_')
  // Body-only drafts keep the fingerprint used before header and footer existed,
  // so templates already sent to Meta keep their names.
  // Custom samples change what Meta reviews, so they also change the name: a
  // rejected template can then be sent again with better samples.
  const used = [...order, ...(headerKey ? [headerKey] : [])]
  const customSamples = used.filter((key) => input.settings?.variable_examples?.[key]).sort()
    .map((key) => `${key}=${input.settings?.variable_examples[key]}`).join('\n')
  let button: { text: string; url: string; example: string } | null = null
  if (settings?.button_text && settings.button_variable) {
    if (!input.buttonLink) throw new Error('WHATSAPP_BUTTON_LINK_UNAVAILABLE')
    button = { text: settings.button_text, ...input.buttonLink(settings.button_variable) }
  }
  const buttonPart = button ? `button=${button.text}|${button.url}` : ''
  const fingerprint = headerText || footerText || ttlSeconds || customSamples || buttonPart
    ? [category, headerText ?? '', bodyText, footerText ?? '', ttlSeconds ?? '', customSamples, buttonPart].filter((part, index) => index < 6 || part).join('\n')
    : `${category}\n${bodyText}`
  return {
    name: `agenda_${event}_${id}_${await shortHash(fingerprint)}`,
    language: 'pt_BR',
    category,
    body_text: bodyText,
    body_examples: bodyExamples,
    header_text: headerText,
    header_example: headerExample,
    footer_text: footerText,
    ttl_seconds: ttlSeconds,
    button_text: button?.text ?? null,
    button_url: button?.url ?? null,
    button_example: button?.example ?? null,
  }
}

/** Maps Meta's template status onto Agenda's submission states. */
export function submissionStatus(metaStatus: unknown): { status: SubmissionStatus; errorCode: string | null } | null {
  switch (String(metaStatus ?? '').toUpperCase()) {
    case 'APPROVED': return { status: 'APPROVED', errorCode: null }
    case 'PENDING':
    case 'IN_APPEAL': return { status: 'PENDING_REVIEW', errorCode: null }
    case 'REJECTED': return { status: 'REJECTED', errorCode: null }
    case 'PAUSED': return { status: 'FAILED', errorCode: 'META_TEMPLATE_PAUSED' }
    case 'DISABLED':
    case 'DELETED':
    case 'PENDING_DELETION': return { status: 'FAILED', errorCode: 'META_TEMPLATE_DISABLED' }
    case 'LIMIT_EXCEEDED': return { status: 'FAILED', errorCode: 'META_TEMPLATE_LIMIT_EXCEEDED' }
    case 'NOT_FOUND': return null
    default: return { status: 'FAILED', errorCode: 'META_TEMPLATE_STATUS_UNKNOWN' }
  }
}

export type SubmissionRow = {
  notification_template_id: string
  status: string
  provider_error_code: string | null
  provider_error_message: string | null
  submitted_at: string | null
  approved_at: string | null
  updated_at: string | null
}

/** Browser-safe view; the provider template id never leaves the server. */
export function submissionView(row: SubmissionRow, templateUpdatedAt: string | null) {
  const submittedAt = row.submitted_at ? Date.parse(row.submitted_at) : NaN
  const editedAt = templateUpdatedAt ? Date.parse(templateUpdatedAt) : NaN
  return {
    notification_template_id: row.notification_template_id,
    status: row.status,
    rejected_reason: row.status === 'REJECTED' ? row.provider_error_message : null,
    error_code: row.provider_error_code,
    submitted_at: row.submitted_at,
    approved_at: row.approved_at,
    checked_at: row.updated_at,
    changed_since_submission: Number.isFinite(submittedAt) && Number.isFinite(editedAt) && editedAt > submittedAt,
  }
}
