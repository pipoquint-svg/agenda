export type WhatsAppCategory = 'UTILITY' | 'MARKETING'

export type WhatsAppTemplateDefinition = {
  name: string
  language: 'pt_BR'
  category: WhatsAppCategory
  body_text: string
  body_examples: string[]
}

export type SubmissionStatus = 'PENDING_REVIEW' | 'APPROVED' | 'REJECTED' | 'FAILED'

const MAX_BODY_LENGTH = 1024
const MAX_EXAMPLE_LENGTH = 200
const VARIABLE = /\{\{\s*([^}]+?)\s*\}\}/g

/** Birthday and manual messages promote; everything else follows a booking. */
export function whatsappCategory(eventKey: string): WhatsAppCategory {
  return eventKey === 'BIRTHDAY' || eventKey === 'MANUAL' ? 'MARKETING' : 'UTILITY'
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
}): Promise<WhatsAppTemplateDefinition> {
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
    const example = String(input.examples[key] ?? '').replace(/\s+/g, ' ').trim()
    if (!example) throw new Error('WHATSAPP_TEMPLATE_EXAMPLE_MISSING')
    return example.slice(0, MAX_EXAMPLE_LENGTH)
  })
  const category = whatsappCategory(input.eventKey)
  const id = input.templateId.replace(/-/g, '').slice(0, 8).toLowerCase()
  const event = input.eventKey.toLowerCase().replace(/[^a-z0-9_]/g, '_')
  return {
    name: `agenda_${event}_${id}_${await shortHash(`${category}\n${bodyText}`)}`,
    language: 'pt_BR',
    category,
    body_text: bodyText,
    body_examples: bodyExamples,
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
