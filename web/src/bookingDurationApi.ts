import { attributionForBackend, trackFunnelStep, trackHoldCreated, trackServiceSelected } from './tracking'
import { functionsBaseUrl, publicApiKey, supabase } from './supabase'
import type {
  BookingEmployee,
  BookingExtra,
  BookingField,
  BookingQuote,
  BookingSlot,
  CheckoutHold,
  ExtraSelection,
} from './bookingApi'

export type DurationPricingTier = { id: string; min_blocks: number; max_blocks: number | null; price_per_block: number | string }
export type DurationPreset = { id: string; block_count: number; title: string; description: string | null; badge: string | null; is_featured: boolean }

export type DurationBookingService = {
  id: string; name: string; slug: string; short_description: string | null; cover_image_url: string | null
  base_duration_minutes: number; base_price: number | string; duration_mode: 'FIXED' | 'BLOCKS'
  booking_block_minutes: number | null; minimum_booking_blocks: number | null; maximum_booking_blocks: number | null
  price_per_block: number | string | null; buffer_before_minutes: number; buffer_after_minutes: number
  minimum_people: number; maximum_people: number; requires_terms: boolean
  duration_pricing_tiers: DurationPricingTier[]; duration_presets: DurationPreset[]
  employees: BookingEmployee[]; extras: BookingExtra[]; fields: BookingField[]
}

export type DurationBookingPageData = {
  id: string; slug: string; display_name: string; title: string; subtitle: string | null; brand_key: string
  logo_url: string | null; accent_color: string | null; services: DurationBookingService[]
}

const pageCache = new Map<string, DurationBookingPageData>()

function unwrapRpc<T>(data: unknown, error: { message: string } | null): T {
  if (error) throw new Error(error.message)
  return data as T
}

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

export function initialDurationBlocks(service: DurationBookingService | null): number | null {
  return service?.duration_mode === 'BLOCKS' ? (service.minimum_booking_blocks ?? 1) : null
}

export function contractedMinutes(service: DurationBookingService, blocks: number | null): number {
  if (service.duration_mode === 'BLOCKS') return (service.booking_block_minutes ?? 30) * (blocks ?? service.minimum_booking_blocks ?? 1)
  return service.base_duration_minutes
}

export function durationUnitPrice(service: DurationBookingService, blocks: number): number {
  const tier = (service.duration_pricing_tiers ?? []).find((candidate) => blocks >= candidate.min_blocks && (candidate.max_blocks === null || blocks <= candidate.max_blocks))
  return tier ? numeric(tier.price_per_block) : numeric(service.price_per_block)
}

export function durationBasePrice(service: DurationBookingService, blocks: number): number { return durationUnitPrice(service, blocks) * blocks }
export function startingPrice(service: DurationBookingService): number {
  if (service.duration_mode === 'BLOCKS') return durationBasePrice(service, service.minimum_booking_blocks ?? 1)
  return numeric(service.base_price)
}

export async function loadDurationBookingPage(slug: string): Promise<DurationBookingPageData | null> {
  const { data, error } = await supabase.rpc('public_get_booking_page', { p_slug: slug })
  const result = unwrapRpc<DurationBookingPageData | null>(data, error)
  if (result) pageCache.set(slug, result)
  return result
}

export async function quoteDurationBooking(input: {
  pageSlug: string; service: DurationBookingService; serviceEmployeeId: string; contractedMinutes: number; extras: ExtraSelection[]; peopleCount: number
}): Promise<BookingQuote> {
  const { data, error } = await supabase.rpc('public_quote_booking_minutes', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.service.id,
    p_service_employee_id: input.serviceEmployeeId,
    p_contracted_minutes: input.contractedMinutes,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
  })
  const result = unwrapRpc<BookingQuote>(data, error)
  trackServiceSelected({ brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug, serviceId: input.service.id, serviceName: input.service.name, value: startingPrice(input.service) })
  trackFunnelStep('booking_duration_selected', {
    bs_brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug,
    service_id: input.service.id,
    duration_mode: input.service.duration_mode,
    contracted_minutes: input.contractedMinutes,
    currency: 'BRL', value: numeric(result.commercial_value),
  })
  return result
}

export async function listDurationBookingSlots(input: {
  pageSlug: string; service: DurationBookingService; serviceEmployeeId: string; contractedMinutes: number; extras: ExtraSelection[]; peopleCount: number; localDate: string
}): Promise<BookingSlot[]> {
  const { data, error } = await supabase.rpc('public_list_available_slots_minutes', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.service.id,
    p_service_employee_id: input.serviceEmployeeId,
    p_contracted_minutes: input.contractedMinutes,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
    p_local_date: input.localDate,
  })
  const result = unwrapRpc<BookingSlot[]>(data ?? [], error)
  trackFunnelStep('availability_searched', {
    bs_brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug,
    service_id: input.service.id, service_name: input.service.name, desired_date: input.localDate,
    people_count: input.peopleCount, contracted_minutes: input.contractedMinutes, slot_count: result.length,
  })
  if (result.length === 0) trackFunnelStep('availability_empty', {
    bs_brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug,
    service_id: input.service.id, desired_date: input.localDate, contracted_minutes: input.contractedMinutes,
  })
  return result
}

export async function createDurationBookingHold(input: {
  pageSlug: string; service: DurationBookingService; serviceEmployeeId: string; contractedMinutes: number; extras: ExtraSelection[]; peopleCount: number; requestedStartAt: string
}): Promise<CheckoutHold & { contracted_minutes?: number }> {
  const res = await fetch(`${functionsBaseUrl}/booking-hold`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', apikey: publicApiKey, authorization: `Bearer ${publicApiKey}` },
    body: JSON.stringify({
      booking_page_slug: input.pageSlug,
      service_id: input.service.id,
      service_employee_id: input.serviceEmployeeId,
      contracted_minutes: input.contractedMinutes,
      extra_selections: input.extras,
      people_count: input.peopleCount,
      requested_start_at: input.requestedStartAt,
      attribution_json: attributionForBackend() ?? {},
    }),
  })
  const payload = await res.json().catch(() => ({})) as { hold?: CheckoutHold & { contracted_minutes?: number }; error?: { code?: string } }
  if (!res.ok || !payload.hold) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  const result = payload.hold
  trackFunnelStep('slot_selected', {
    bs_brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug,
    service_id: input.service.id, requested_start_at: input.requestedStartAt, contracted_minutes: result.contracted_minutes ?? input.contractedMinutes,
  })
  trackHoldCreated({ holdId: result.checkout_hold_id, brand: pageCache.get(input.pageSlug)?.brand_key ?? input.pageSlug, serviceId: input.service.id, serviceName: input.service.name, value: numeric(result.commercial_value), people: input.peopleCount })
  return result
}
