import type { BookingSlot, ExtraSelection } from './bookingApi'
import { supabase } from './supabase'

export type BookingSlotInRange = BookingSlot & {
  local_date: string
}

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
  const { data, error } = await supabase.rpc('public_list_available_slots_range', {
    p_booking_page_slug: input.pageSlug,
    p_service_id: input.serviceId,
    p_service_employee_id: input.serviceEmployeeId,
    p_start_date: input.startDate,
    p_end_date: input.endDate,
    p_extra_selections: input.extras,
    p_people_count: input.peopleCount,
    p_limit: input.limit ?? 5,
  })

  if (error) throw new Error(error.message)
  return (data ?? []) as BookingSlotInRange[]
}
