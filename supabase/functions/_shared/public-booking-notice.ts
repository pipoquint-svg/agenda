export function normalizePublicMinimumBookingNoticeHours(value: unknown): number {
  const next = Number(value)
  if (!Number.isInteger(next) || next < 0) throw new Error('PUBLIC_MINIMUM_BOOKING_NOTICE_HOURS_INVALID')
  return next
}
