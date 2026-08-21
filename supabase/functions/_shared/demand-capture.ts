export const DEMAND_PERIODS = ['MANHA', 'TARDE', 'NOITE', 'INDIFERENTE'] as const
export const DEMAND_STATUSES = ['NEW', 'CONTACTED', 'CONVERTED', 'DISCARDED'] as const

const VALID_DDDS = new Set([
  '11','12','13','14','15','16','17','18','19',
  '21','22','24','27','28',
  '31','32','33','34','35','37','38',
  '41','42','43','44','45','46','47','48','49',
  '51','53','54','55',
  '61','62','63','64','65','66','67','68','69',
  '71','73','74','75','77','79',
  '81','82','83','84','85','86','87','88','89',
  '91','92','93','94','95','96','97','98','99',
])

export type DemandSubmission = {
  name: string
  whatsapp: string
  email: string
  brand: string
  service_id: string
  desired_date: string | null
  desired_period: typeof DEMAND_PERIODS[number] | null
  notes: string | null
  campaign: string | null
  consent_contact: true
}

export function parseConfiguredBrands(raw: string | undefined): string[] {
  if (!raw) throw new Error('DEMAND_CAPTURE_BRANDS_NOT_CONFIGURED')
  const value = raw.trim()
  let brands: string[]
  if (value.startsWith('[')) {
    const parsed = JSON.parse(value)
    if (!Array.isArray(parsed)) throw new Error('DEMAND_CAPTURE_BRANDS_INVALID')
    brands = parsed.map(String)
  } else {
    brands = value.split(',')
  }
  const normalized = [...new Set(brands.map((item) => item.trim()).filter(Boolean))]
  if (normalized.length === 0) throw new Error('DEMAND_CAPTURE_BRANDS_INVALID')
  return normalized
}

export function normalizeBrazilWhatsapp(value: string): string {
  let digits = String(value ?? '').replace(/\D/g, '')
  if (digits.startsWith('55') && (digits.length === 12 || digits.length === 13)) {
    digits = digits.slice(2)
  }
  if (digits.length !== 10 && digits.length !== 11) throw new Error('WHATSAPP_INVALID')
  const ddd = digits.slice(0, 2)
  if (!VALID_DDDS.has(ddd)) throw new Error('WHATSAPP_INVALID')
  const subscriber = digits.slice(2)
  if (digits.length === 11 && subscriber[0] !== '9') throw new Error('WHATSAPP_INVALID')
  if (digits.length === 10 && !/^[2-5]/.test(subscriber)) throw new Error('WHATSAPP_INVALID')
  return `55${digits}`
}

export function validEmail(value: string): boolean {
  const email = String(value ?? '').trim()
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
}

export function todaySaoPaulo(now = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now)
  const pick = (type: string) => parts.find((part) => part.type === type)?.value ?? ''
  return `${pick('year')}-${pick('month')}-${pick('day')}`
}

function nullableText(value: unknown, maxLength?: number): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new Error('INVALID_REQUEST')
  const text = value.trim()
  if (!text) return null
  if (maxLength && text.length > maxLength) throw new Error('INVALID_REQUEST')
  return text
}

export function validateDemandSubmission(
  input: unknown,
  allowedBrands: string[],
  now = new Date(),
): DemandSubmission {
  if (!input || typeof input !== 'object') throw new Error('INVALID_REQUEST')
  const body = input as Record<string, unknown>

  const name = typeof body.name === 'string' ? body.name.trim() : ''
  if (name.length < 2) throw new Error('NAME_INVALID')

  const whatsapp = normalizeBrazilWhatsapp(String(body.whatsapp ?? ''))
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : ''
  if (!validEmail(email)) throw new Error('EMAIL_INVALID')

  const brand = typeof body.brand === 'string' ? body.brand.trim() : ''
  if (!allowedBrands.includes(brand)) throw new Error('BRAND_INVALID')

  const serviceId = typeof body.service_id === 'string' ? body.service_id.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(serviceId)) {
    throw new Error('SERVICE_INVALID')
  }

  const desiredDate = nullableText(body.desired_date, 10)
  if (desiredDate !== null) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(desiredDate)) throw new Error('DESIRED_DATE_INVALID')
    if (desiredDate < todaySaoPaulo(now)) throw new Error('DESIRED_DATE_IN_PAST')
  }

  const desiredPeriod = nullableText(body.desired_period, 12)
  if (desiredPeriod !== null && !DEMAND_PERIODS.includes(desiredPeriod as typeof DEMAND_PERIODS[number])) {
    throw new Error('DESIRED_PERIOD_INVALID')
  }

  const notes = nullableText(body.notes, 300)
  const campaign = nullableText(body.campaign, 160)

  if (body.consent_contact !== true) throw new Error('CONSENT_REQUIRED')

  return {
    name,
    whatsapp,
    email,
    brand,
    service_id: serviceId,
    desired_date: desiredDate,
    desired_period: desiredPeriod as DemandSubmission['desired_period'],
    notes,
    campaign,
    consent_contact: true,
  }
}
