import { functionsBaseUrl, publicApiKey, supabase } from './supabase'
import {
  attributionForBackend,
  trackAppointmentConfirmed,
  trackAppointmentCreated,
  trackCustomerDetailsCompleted,
  trackFunnelStep,
  trackHoldCreated,
  trackServiceSelected,
} from './tracking'

export type BookingEmployee = {
  service_employee_id: string
  employee_id: string
  name: string
}

export type BookingExtra = {
  id: string
  name: string
  description: string | null
  price: number | string
  duration_delta_minutes: number
  is_required: boolean
  max_quantity: number
  schedule_placement: 'PREPEND' | 'APPEND'
  default_schedule_minutes: number | null
}

export type BookingField = {
  id: string
  field_key: string
  label: string
  field_type: 'TEXT' | 'TEXTAREA' | 'NUMBER' | 'DATE' | 'SELECT' | 'BOOLEAN'
  help_text: string | null
  placeholder: string | null
  is_required: boolean
  options: unknown
}

export type BookingService = {
  id: string
  name: string
  slug: string
  short_description: string | null
  cover_image_url: string | null
  base_duration_minutes: number
  base_price: number | string
  minimum_people: number
  maximum_people: number
  requires_terms: boolean
  employees: BookingEmployee[]
  extras: BookingExtra[]
  fields: BookingField[]
}

export type BookingPageData = {
  id: string
  slug: string
  display_name: string
  title: string
  subtitle: string | null
  brand_key: string
  logo_url: string | null
  accent_color: string | null
  services: BookingService[]
}

export type ExtraSelection = {
  extra_id: string
  quantity: number
}

export type BookingQuote = {
  commercial_value: number | string
  duration_minutes: number
  core_duration_minutes?: number
  pre_service_minutes?: number
  post_service_minutes?: number
  extras_total?: number | string
}

export type BookingSlot = {
  slot_start_at: string
  slot_end_at: string
  core_start_at: string
  core_end_at: string
  pre_service_minutes: number
  post_service_minutes: number
  duration_minutes: number
  commercial_value: number | string
}

export type CheckoutHold = {
  checkout_hold_token: string
  checkout_hold_id: string
  status: 'ACTIVE'
  expires_at: string
  slot_start_at: string
  slot_end_at: string
  core_start_at: string
  core_end_at: string
  pre_service_minutes: number
  post_service_minutes: number
  commercial_value: number | string
  duration_minutes: number
  pricing_version: string
}

export type CheckoutTerm = {
  id: string
  name: string
  version: string
  content: string
  published_at: string
}

export type CheckoutContext = {
  checkout_hold_id: string
  expires_at: string
  booking_page_slug: string
  brand_key: string
  require_tax_id: boolean
  customer_bound: boolean
  service: { id: string; name: string; requires_terms: boolean }
  schedule: {
    slot_start_at: string
    slot_end_at: string
    core_start_at: string
    core_end_at: string
    pre_service_minutes: number
    post_service_minutes: number
  }
  summary: {
    people_count: number
    commercial_value: number | string
    duration_minutes: number
    extra_selections: ExtraSelection[]
  }
  fields: BookingField[]
  terms: CheckoutTerm[]
  package_selected: boolean
}

export type CheckoutPackage = {
  hour_package_id: string
  name: string
  valid_until: string
  available_seconds: number
  required_seconds: number
  surcharge_seconds: number
  charged_seconds: number
  is_special_period: boolean
  usable: boolean
  cash_due: number | string
}

export type AppointmentCheckoutResult = {
  appointment_id: string
  public_code: string
  status: 'AWAITING_PAYMENT' | 'CONFIRMED'
  financial_status: string
  hold_expires_at: string | null
  cash_due: number | string
  package_reserved: boolean
  coupon_applied: boolean
  access_token: string
}

export type ServiceAnswer = {
  service_field_id: string
  value: string | number | boolean | null
}

type QuoteFingerprint = { extras: string; people: number }

const bookingPageCache = new Map<string, BookingPageData>()
const checkoutContextCache = new Map<string, CheckoutContext>()
const quoteFingerprintCache = new Map<string, QuoteFingerprint>()

function numeric(value: number | string | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function pageAndService(pageSlug: string, serviceId: string): { page: BookingPageData | null; service: BookingService | null } {
  const page = bookingPageCache.get(pageSlug) ?? null
  return { page, service: page?.services.find((item) => item.id === serviceId) ?? null }
}

function unwrapRpc<T>(data: unknown, error: { message: string } | null): T {
  if (error) throw new Error(error.message)
  return data as T
}

async function callPublicGateway<T>(name: 'booking-hold' | 'booking-checkout', body: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${functionsBaseUrl}/${name}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
    },
    body: JSON.stringify(body),
  })
  const payload = await res.json().catch(() => ({})) as { hold?: T; data?: T; error?: { code?: string } }
  if (!res.ok) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  const value = name === 'booking-hold' ? payload.hold : payload.data
  if (value === undefined) throw new Error('PUBLIC_GATEWAY_INVALID_RESPONSE')
  return value as T
}

export async function loadBookingPage(slug: string): Promise<BookingPageData | null> {
  const { data, error } = await supabase.rpc('public_get_booking_page', { p_slug: slug })
  const result = unwrapRpc<BookingPageData | null>(data, error)
  if (result) bookingPageCache.set(slug, result)
  return result
}

export async function quoteBooking(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  extras: ExtraSelection[]
  peopleCount: number
}): Promise<BookingQuote> {
  const { data, error } = await supabase.rpc('public_quote_booking', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.serviceId,
    p_service_employee_id: input.serviceEmployeeId,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
  })
  const result = unwrapRpc<BookingQuote>(data, error)
  const { page, service } = pageAndService(input.pageSlug, input.serviceId)
  if (page && service) {
    trackServiceSelected({
      brand: page.brand_key,
      serviceId: service.id,
      serviceName: service.name,
      value: numeric(service.base_price),
    })

    const key = `${input.pageSlug}:${input.serviceId}:${input.serviceEmployeeId}`
    const nextFingerprint: QuoteFingerprint = {
      extras: JSON.stringify([...input.extras].sort((a, b) => a.extra_id.localeCompare(b.extra_id))),
      people: input.peopleCount,
    }
    const previous = quoteFingerprintCache.get(key)
    if (previous && previous.extras !== nextFingerprint.extras) {
      trackFunnelStep('booking_extras_changed', {
        bs_brand: page.brand_key,
        service_id: service.id,
        extra_quantity: input.extras.reduce((sum, extra) => sum + extra.quantity, 0),
        currency: 'BRL',
        value: numeric(result.commercial_value),
      })
    }
    if (previous && previous.people !== nextFingerprint.people) {
      trackFunnelStep('booking_people_changed', {
        bs_brand: page.brand_key,
        service_id: service.id,
        people_count: input.peopleCount,
        currency: 'BRL',
        value: numeric(result.commercial_value),
      })
    }
    quoteFingerprintCache.set(key, nextFingerprint)
  }
  return result
}

export async function listBookingSlots(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  extras: ExtraSelection[]
  peopleCount: number
  localDate: string
}): Promise<BookingSlot[]> {
  const { data, error } = await supabase.rpc('public_list_available_slots', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.serviceId,
    p_service_employee_id: input.serviceEmployeeId,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
    p_local_date: input.localDate,
  })
  const result = unwrapRpc<BookingSlot[]>(data ?? [], error)
  const { page, service } = pageAndService(input.pageSlug, input.serviceId)
  trackFunnelStep('availability_searched', {
    bs_brand: page?.brand_key ?? input.pageSlug,
    service_id: input.serviceId,
    service_name: service?.name,
    desired_date: input.localDate,
    people_count: input.peopleCount,
    slot_count: result.length,
  })
  if (result.length === 0) {
    trackFunnelStep('availability_empty', {
      bs_brand: page?.brand_key ?? input.pageSlug,
      service_id: input.serviceId,
      desired_date: input.localDate,
    })
  }
  return result
}

export async function createBookingHold(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  extras: ExtraSelection[]
  peopleCount: number
  requestedStartAt: string
}): Promise<CheckoutHold> {
  const result = await callPublicGateway<CheckoutHold>('booking-hold', {
    booking_page_slug: input.pageSlug,
    service_id: input.serviceId,
    service_employee_id: input.serviceEmployeeId,
    extra_selections: input.extras,
    people_count: input.peopleCount,
    requested_start_at: input.requestedStartAt,
    attribution_json: attributionForBackend() ?? {},
  })
  const { page, service } = pageAndService(input.pageSlug, input.serviceId)
  trackFunnelStep('slot_selected', {
    bs_brand: page?.brand_key ?? input.pageSlug,
    service_id: input.serviceId,
    requested_start_at: input.requestedStartAt,
  })
  trackHoldCreated({
    holdId: result.checkout_hold_id,
    brand: page?.brand_key ?? input.pageSlug,
    serviceId: input.serviceId,
    serviceName: service?.name ?? input.serviceId,
    value: numeric(result.commercial_value),
    people: input.peopleCount,
  })
  return result
}

export async function loadCheckoutContext(token: string): Promise<CheckoutContext> {
  const result = await callPublicGateway<CheckoutContext>('booking-checkout', {
    action: 'CONTEXT', checkout_hold_token: token,
  })
  checkoutContextCache.set(token, result)
  return result
}

export async function bindCheckoutCustomer(input: {
  token: string
  name: string
  email: string
  phone: string
  taxId: string
}): Promise<{ customer_bound: boolean; customer_created: boolean; recovery_enabled: boolean; has_tax_id: boolean }> {
  const result = await callPublicGateway<{ customer_bound: boolean; customer_created: boolean; recovery_enabled: boolean; has_tax_id: boolean }>('booking-checkout', {
    action: 'BIND_CUSTOMER',
    checkout_hold_token: input.token,
    name: input.name,
    email: input.email,
    phone: input.phone,
    tax_id: input.taxId || null,
  })
  const context = checkoutContextCache.get(input.token)
  if (context) {
    trackCustomerDetailsCompleted({
      holdId: context.checkout_hold_id,
      brand: context.brand_key,
      serviceId: context.service.id,
      value: numeric(context.summary.commercial_value),
    })
  }
  return result
}

export async function listCheckoutPackages(token: string): Promise<CheckoutPackage[]> {
  return callPublicGateway<CheckoutPackage[]>('booking-checkout', {
    action: 'LIST_PACKAGES', checkout_hold_token: token,
  })
}

export async function selectCheckoutPackage(token: string, packageId: string): Promise<void> {
  await callPublicGateway<unknown>('booking-checkout', {
    action: 'SELECT_PACKAGE', checkout_hold_token: token, hour_package_id: packageId,
  })
  const context = checkoutContextCache.get(token)
  trackFunnelStep('hour_package_selected', {
    bs_brand: context?.brand_key,
    service_id: context?.service.id,
    package_selected: true,
  })
}

export async function clearCheckoutPackage(token: string): Promise<void> {
  await callPublicGateway<unknown>('booking-checkout', {
    action: 'CLEAR_PACKAGE', checkout_hold_token: token,
  })
  const context = checkoutContextCache.get(token)
  trackFunnelStep('hour_package_selected', {
    bs_brand: context?.brand_key,
    service_id: context?.service.id,
    package_selected: false,
  })
}

export async function submitBookingCheckout(input: {
  token: string
  termVersionIds: string[]
  answers: ServiceAnswer[]
}): Promise<AppointmentCheckoutResult> {
  const res = await fetch(`${functionsBaseUrl}/booking-submit`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
    },
    body: JSON.stringify({
      checkout_hold_token: input.token,
      term_version_ids: input.termVersionIds,
      answers: input.answers,
    }),
  })

  const payload = await res.json().catch(() => ({})) as { appointment?: AppointmentCheckoutResult; error?: { code?: string } }
  if (!res.ok || !payload.appointment) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)

  const context = checkoutContextCache.get(input.token)
  const value = numeric(context?.summary.commercial_value)
  if (context) {
    trackFunnelStep('booking_terms_submitted', {
      bs_brand: context.brand_key,
      service_id: context.service.id,
      accepted_terms: input.termVersionIds.length,
      service_answers: input.answers.length,
    })
  }
  trackAppointmentCreated({
    appointmentId: payload.appointment.appointment_id,
    publicCode: payload.appointment.public_code,
    serviceName: context?.service.name ?? 'Reserva',
    value,
    status: payload.appointment.status,
    packageReserved: payload.appointment.package_reserved,
  })
  if (payload.appointment.status === 'CONFIRMED') {
    trackAppointmentConfirmed({
      appointmentId: payload.appointment.appointment_id,
      publicCode: payload.appointment.public_code,
      serviceName: context?.service.name ?? 'Reserva',
      commercialValue: value,
      paymentMethod: payload.appointment.package_reserved ? 'HOUR_PACKAGE' : 'NO_CASH_DUE',
      cashCollected: 0,
    })
  }
  return payload.appointment
}
