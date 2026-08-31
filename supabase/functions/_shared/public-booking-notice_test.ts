import { assertEquals, assertThrows } from "jsr:@std/assert"
import { normalizePublicMinimumBookingNoticeHours } from "./public-booking-notice.ts"

Deno.test('public booking notice accepts zero and positive integer hours', () => {
  assertEquals(normalizePublicMinimumBookingNoticeHours(0), 0)
  assertEquals(normalizePublicMinimumBookingNoticeHours('24'), 24)
})

Deno.test('public booking notice rejects negative and fractional hours', () => {
  assertThrows(() => normalizePublicMinimumBookingNoticeHours(-1), Error, 'PUBLIC_MINIMUM_BOOKING_NOTICE_HOURS_INVALID')
  assertThrows(() => normalizePublicMinimumBookingNoticeHours(12.5), Error, 'PUBLIC_MINIMUM_BOOKING_NOTICE_HOURS_INVALID')
})
