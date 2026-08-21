import { functionsBaseUrl, publicApiKey, supabase } from './supabase'

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

function unwrapRpc<T>(data: unknown, error: { message: string } | null): T {
  if (error) throw new Error(error.message)
  return data as T
}

export async function loadBookingPage(slug: string): Promise<BookingPageData | null> {
  const { data, error } = await supabase.rpc('public_get_booking_page', { p_slug: slug })
  return unwrapRpc<BookingPageData | null>(data, error)
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
  return unwrapRpc<BookingQuote>(data, error)
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
  return unwrapRpc<BookingSlot[]>(data ?? [], error)
}

export async function createBookingHold(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  extras: ExtraSelection[]
  peopleCount: number
  requestedStartAt: string
}): Promise<CheckoutHold> {
  const { data, error } = await supabase.rpc('public_create_checkout_hold', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.serviceId,
    p_service_employee_id: input.serviceEmployeeId,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
    p_requested_start_at: input.requestedStartAt,
  })
  return unwrapRpc<CheckoutHold>(data, error)
}

export async function loadCheckoutContext(token: string): Promise<CheckoutContext> {
  const { data, error } = await supabase.rpc('public_get_checkout_context', {
    p_checkout_hold_token: token,
  })
  return unwrapRpc<CheckoutContext>(data, error)
}

export async function setBookingRecoveryContact(token: string, phone: string, enabled = true): Promise<void> {
  const { error } = await supabase.rpc('set_checkout_hold_recovery_contact', {
    p_checkout_hold_token: token,
    p_phone: phone,
    p_enabled: enabled,
  })
  if (error) throw new Error(error.message)
}

export async function bindCheckoutCustomer(input: {
  token: string
  name: string
  email: string
  phone: string
  taxId: string
  recoveryEnabled: boolean
}): Promise<{ customer_bound: boolean; customer_created: boolean; recovery_enabled: boolean; has_tax_id: boolean }> {
  const { data, error } = await supabase.rpc('public_bind_checkout_customer', {
    p_checkout_hold_token: input.token,
    p_name: input.name,
    p_email: input.email,
    p_phone: input.phone,
    p_tax_id: input.taxId || null,
    p_recovery_enabled: input.recoveryEnabled,
  })
  return unwrapRpc(data, error)
}

export async function listCheckoutPackages(token: string): Promise<CheckoutPackage[]> {
  const { data, error } = await supabase.rpc('public_list_checkout_hour_packages', {
    p_checkout_hold_token: token,
  })
  return unwrapRpc<CheckoutPackage[]>(data ?? [], error)
}

export async function selectCheckoutPackage(token: string, packageId: string): Promise<void> {
  const { error } = await supabase.rpc('public_select_checkout_hour_package', {
    p_checkout_hold_token: token,
    p_hour_package_id: packageId,
  })
  if (error) throw new Error(error.message)
}

export async function clearCheckoutPackage(token: string): Promise<void> {
  const { error } = await supabase.rpc('public_clear_checkout_hour_package', {
    p_checkout_hold_token: token,
  })
  if (error) throw new Error(error.message)
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
  return payload.appointment
}
