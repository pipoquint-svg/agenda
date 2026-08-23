export type KommoFieldValue = {
  field_code?: string | null
  field_id?: number | null
  values?: Array<{ value?: unknown; enum_code?: string | null }> | null
}

export type KommoContact = {
  id: number
  name?: string | null
  custom_fields_values?: KommoFieldValue[] | null
}

export type KommoPipelineSettings = {
  pipeline_id: number | null
  stage_awaiting_payment_id: number | null
  stage_confirmed_id: number | null
  stage_rescheduled_id: number | null
  stage_cancelled_id: number | null
  stage_completed_id: number | null
  stage_no_show_id: number | null
  stage_expired_id: number | null
}

export function normalizeEmail(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim().toLowerCase()
  return normalized || null
}

export function normalizePhone(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const digits = value.replace(/\D+/g, '')
  return digits || null
}

function fieldValues(contact: KommoContact, code: string): string[] {
  const field = (contact.custom_fields_values ?? []).find((candidate) => candidate.field_code === code)
  return (field?.values ?? [])
    .map((entry) => typeof entry.value === 'string' ? entry.value : '')
    .filter(Boolean)
}

export function contactMatchesExactly(
  contact: KommoContact,
  email: string | null,
  phone: string | null,
): boolean {
  const emailNeedle = normalizeEmail(email)
  const phoneNeedle = normalizePhone(phone)
  const emails = fieldValues(contact, 'EMAIL').map(normalizeEmail).filter(Boolean)
  const phones = fieldValues(contact, 'PHONE').map(normalizePhone).filter(Boolean)

  if (emailNeedle && emails.includes(emailNeedle)) return true
  if (phoneNeedle && phones.includes(phoneNeedle)) return true
  return false
}

export function exactContactCandidates(
  contacts: KommoContact[],
  email: string | null,
  phone: string | null,
): KommoContact[] {
  return contacts.filter((contact) => contactMatchesExactly(contact, email, phone))
}

export function stageIdForAppointment(
  settings: KommoPipelineSettings,
  appointmentStatus: string,
  eventKind: string,
): number {
  const event = eventKind.trim().toUpperCase()
  const status = appointmentStatus.trim().toUpperCase()

  const stage = event === 'RESCHEDULED'
    ? settings.stage_rescheduled_id
    : status === 'CONFIRMED'
      ? settings.stage_confirmed_id
      : status === 'CANCELLED'
        ? settings.stage_cancelled_id
        : status === 'COMPLETED'
          ? settings.stage_completed_id
          : status === 'NO_SHOW'
            ? settings.stage_no_show_id
            : status === 'EXPIRED'
              ? settings.stage_expired_id
              : settings.stage_awaiting_payment_id

  if (!Number.isInteger(stage) || Number(stage) <= 0) throw new Error(`KOMMO_STAGE_NOT_CONFIGURED:${event}:${status}`)
  return Number(stage)
}

export function kommoLeadName(serviceName: string | null | undefined, publicCode: string | null | undefined): string {
  const service = (serviceName ?? 'Reserva BlackSheep').trim() || 'Reserva BlackSheep'
  const code = (publicCode ?? '').trim()
  return code ? `${service} · ${code}` : service
}

export function buildContactCustomFields(
  emailFieldId: number | null,
  phoneFieldId: number | null,
  email: string | null,
  phone: string | null,
): Array<{ field_id: number; values: Array<{ value: string; enum_code: string }> }> {
  const fields: Array<{ field_id: number; values: Array<{ value: string; enum_code: string }> }> = []
  const normalizedEmail = normalizeEmail(email)
  const normalizedPhone = typeof phone === 'string' ? phone.trim() : ''

  if (normalizedEmail && Number.isInteger(emailFieldId) && Number(emailFieldId) > 0) {
    fields.push({ field_id: Number(emailFieldId), values: [{ value: normalizedEmail, enum_code: 'WORK' }] })
  }
  if (normalizedPhone && Number.isInteger(phoneFieldId) && Number(phoneFieldId) > 0) {
    fields.push({ field_id: Number(phoneFieldId), values: [{ value: normalizedPhone, enum_code: 'MOB' }] })
  }
  return fields
}

export async function kommoJson<T = unknown>(
  baseUrl: string,
  token: string,
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      accept: 'application/json',
      'content-type': 'application/json',
      authorization: `Bearer ${token}`,
      ...(init.headers ?? {}),
    },
  })

  const text = await response.text()
  let payload: unknown = null
  try {
    payload = text ? JSON.parse(text) : null
  } catch {
    payload = { raw: text.slice(0, 500) }
  }

  if (!response.ok) {
    const error = new Error(`KOMMO_HTTP_${response.status}:${JSON.stringify(payload).slice(0, 1000)}`) as Error & { status?: number }
    error.status = response.status
    throw error
  }
  return payload as T
}
