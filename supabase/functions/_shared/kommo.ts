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

export type KommoCustomField = {
  id?: number | null
  name?: string | null
  code?: string | null
  type?: string | null
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

export type KommoResolvedLeadField = {
  id: number
  type: string
}

export type KommoLeadCardFields = {
  reservationDate: KommoResolvedLeadField
  balance: KommoResolvedLeadField
  rentalExtras: KommoResolvedLeadField
}

export type KommoRentalExtra = {
  name?: string | null
  quantity?: number | null
}

const KOMMO_TIMEOUT_MS = 15_000
const KOMMO_BASE_URL_RE = /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.kommo\.com\/api\/v4$/

export function assertKommoBaseUrl(baseUrl: string): void {
  if (!KOMMO_BASE_URL_RE.test(baseUrl)) throw new Error('KOMMO_BASE_URL_DENIED')
}

export function normalizeEmail(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim().toLowerCase()
  return normalized || null
}

export function normalizePhone(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const digits = value.replace(/\D+/g, '')
  if (!digits) return null
  if ((digits.length === 10 || digits.length === 11) && !digits.startsWith('55')) return `55${digits}`
  return digits
}

function fieldValues(contact: KommoContact, code: string): string[] {
  const field = (contact.custom_fields_values ?? []).find((candidate) => candidate.field_code === code)
  return (field?.values ?? [])
    .map((entry) => typeof entry.value === 'string' ? entry.value : '')
    .filter(Boolean)
}

export function contactMatchesExactly(contact: KommoContact, email: string | null, phone: string | null): boolean {
  const emailNeedle = normalizeEmail(email)
  const phoneNeedle = normalizePhone(phone)
  const emails = fieldValues(contact, 'EMAIL').map(normalizeEmail).filter(Boolean)
  const phones = fieldValues(contact, 'PHONE').map(normalizePhone).filter(Boolean)
  if (phoneNeedle && phones.includes(phoneNeedle)) return true
  if (emailNeedle && emails.includes(emailNeedle)) return true
  return false
}

export function exactContactCandidates(contacts: KommoContact[], email: string | null, phone: string | null): KommoContact[] {
  return contacts.filter((contact) => contactMatchesExactly(contact, email, phone))
}

export function stageIdForAppointment(settings: KommoPipelineSettings, appointmentStatus: string, eventKind: string): number {
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

function normalizeFieldName(value: unknown): string {
  return String(value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLocaleLowerCase('pt-BR')
}

function resolveUniqueLeadField(fields: KommoCustomField[], expectedName: string, allowedTypes: string[], errorPrefix: string): KommoResolvedLeadField {
  const needle = normalizeFieldName(expectedName)
  const named = fields.filter((field) => normalizeFieldName(field.name) === needle)
  if (named.length !== 1) throw new Error(named.length === 0 ? `${errorPrefix}_MISSING` : `${errorPrefix}_AMBIGUOUS`)
  const field = named[0]
  const type = String(field.type ?? '').trim().toLowerCase()
  if (!allowedTypes.includes(type)) throw new Error(`${errorPrefix}_INVALID_TYPE`)
  if (!Number.isInteger(field.id) || Number(field.id) <= 0) throw new Error(`${errorPrefix}_INVALID_ID`)
  return { id: Number(field.id), type }
}

export function findUniqueLeadDateFieldId(fields: KommoCustomField[], expectedName = 'Data'): number {
  return resolveUniqueLeadField(fields, expectedName, ['date', 'date_time'], 'KOMMO_RESERVATION_DATE_FIELD').id
}

export function resolveLeadCardFields(fields: KommoCustomField[]): KommoLeadCardFields {
  return {
    reservationDate: resolveUniqueLeadField(fields, 'Data', ['date', 'date_time'], 'KOMMO_RESERVATION_DATE_FIELD'),
    balance: resolveUniqueLeadField(fields, 'Saldo', ['numeric', 'monetary', 'text', 'textarea'], 'KOMMO_BALANCE_FIELD'),
    rentalExtras: resolveUniqueLeadField(fields, 'Extras locação', ['text', 'textarea'], 'KOMMO_RENTAL_EXTRAS_FIELD'),
  }
}

export function kommoReservationDateValue(startAt: string | null | undefined): string {
  if (!startAt) throw new Error('KOMMO_RESERVATION_START_REQUIRED')
  const instant = new Date(startAt)
  if (Number.isNaN(instant.getTime())) throw new Error('KOMMO_RESERVATION_START_INVALID')
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(instant)
  const year = parts.find((part) => part.type === 'year')?.value
  const month = parts.find((part) => part.type === 'month')?.value
  const day = parts.find((part) => part.type === 'day')?.value
  if (!year || !month || !day) throw new Error('KOMMO_RESERVATION_DATE_FORMAT_FAILED')
  return `${year}-${month}-${day}T12:00:00-03:00`
}

export function kommoLeadPrice(value: number | null | undefined): number {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error('KOMMO_COMMERCIAL_VALUE_INVALID')
  return Math.round(parsed)
}

export function kommoBalanceValue(value: number | null | undefined): string {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error('KOMMO_BALANCE_INVALID')
  return parsed.toFixed(2)
}

export function formatRentalExtras(extras: KommoRentalExtra[] | null | undefined): string {
  return (extras ?? [])
    .map((extra) => {
      const name = String(extra?.name ?? '').trim()
      if (!name) return ''
      const quantity = Number(extra?.quantity ?? 1)
      const safeQuantity = Number.isInteger(quantity) && quantity > 0 ? quantity : 1
      return safeQuantity > 1 ? `${safeQuantity}x ${name}` : name
    })
    .filter(Boolean)
    .join('\n')
}

export function buildLeadCardCustomFields(
  fields: KommoLeadCardFields,
  startAt: string | null | undefined,
  balance: number | null | undefined,
  extras: KommoRentalExtra[] | null | undefined,
): Array<{ field_id: number; values: Array<{ value: string }> }> {
  return [
    { field_id: fields.reservationDate.id, values: [{ value: kommoReservationDateValue(startAt) }] },
    { field_id: fields.balance.id, values: [{ value: kommoBalanceValue(balance) }] },
    { field_id: fields.rentalExtras.id, values: [{ value: formatRentalExtras(extras) }] },
  ]
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

export async function kommoJson<T = unknown>(baseUrl: string, token: string, path: string, init: RequestInit = {}): Promise<T> {
  assertKommoBaseUrl(baseUrl)
  if (!path.startsWith('/') || path.startsWith('//')) throw new Error('KOMMO_PATH_DENIED')

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), KOMMO_TIMEOUT_MS)
  let response: Response
  try {
    response = await fetch(`${baseUrl}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        accept: 'application/json',
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
        ...(init.headers ?? {}),
      },
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('KOMMO_TIMEOUT')
    throw new Error('KOMMO_NETWORK_ERROR')
  } finally {
    clearTimeout(timeout)
  }

  const text = await response.text()
  let payload: unknown = null
  try {
    payload = text ? JSON.parse(text) : null
  } catch {
    payload = null
  }

  if (!response.ok) {
    const error = new Error(`KOMMO_HTTP_${response.status}`) as Error & { status?: number }
    error.status = response.status
    throw error
  }
  return payload as T
}
