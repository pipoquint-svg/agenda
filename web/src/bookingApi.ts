import { supabase } from './supabase'

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
