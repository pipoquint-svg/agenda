import type { BookingSlot, ExtraSelection } from './bookingApi'
import { supabase } from './supabase'

export type BookingSlotInRange = BookingSlot & {
  local_date: string
}

const DAY_MS = 24 * 60 * 60 * 1000
const CONCURRENCY = 4

function parseDate(value: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('DATE_RANGE_INVALID')
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new Error('DATE_RANGE_INVALID')
  }
  return parsed
}

function datesBetween(startDate: string, endDate: string): string[] {
  const start = parseDate(startDate)
  const end = parseDate(endDate)
  const distance = Math.round((end.getTime() - start.getTime()) / DAY_MS)
  if (distance < 0 || distance > 62) throw new Error('DATE_RANGE_INVALID')

  return Array.from({ length: distance + 1 }, (_, index) => {
    const day = new Date(start)
    day.setUTCDate(day.getUTCDate() + index)
    return day.toISOString().slice(0, 10)
  })
}

async function listDay(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  extras: ExtraSelection[]
  peopleCount: number
  localDate: string
}): Promise<BookingSlotInRange[]> {
  const { data, error } = await supabase.rpc('public_list_available_slots', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.serviceId,
    p_service_employee_id: input.serviceEmployeeId,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
    p_local_date: input.localDate,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as BookingSlot[]).map((slot) => ({ ...slot, local_date: input.localDate }))
}

/**
 * Reuses the already-hardened daily availability RPC. Dates are queried in
 * small batches and the scan stops as soon as enough real slots are found.
 */
export async function listBookingSlotsRange(input: {
  pageSlug: string
  serviceId: string
  serviceEmployeeId: string
  startDate: string
  endDate: string
  extras: ExtraSelection[]
  peopleCount: number
  limit?: number
}): Promise<BookingSlotInRange[]> {
  const limit = input.limit ?? 5
  if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('LIMIT_INVALID')

  const days = datesBetween(input.startDate, input.endDate)
  const found: BookingSlotInRange[] = []

  for (let index = 0; index < days.length && found.length < limit; index += CONCURRENCY) {
    const batch = days.slice(index, index + CONCURRENCY)
    const results = await Promise.all(batch.map((localDate) => listDay({ ...input, localDate })))
    const ordered = results.flat().sort((left, right) => left.slot_start_at.localeCompare(right.slot_start_at))
    found.push(...ordered.slice(0, limit - found.length))
  }

  return found
}
