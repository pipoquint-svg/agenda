-- Manual/admin booking must never inherit the public minimum booking notice.
--
-- Public lead time is canonical in services.public_minimum_booking_notice_hours
-- and is applied only by public availability wrappers. The legacy
-- minimum_booking_notice_minutes field still participates in the internal
-- availability engine, so any non-zero historical value leaks the public
-- restriction into admin/manual bookings.
--
-- Normalize the legacy core field back to its canonical neutral value. There
-- are no runtime writers for this field; new services already default to 0.
-- Public booking behavior remains unchanged because it is controlled by
-- public_minimum_booking_notice_hours.

update public.services
set minimum_booking_notice_minutes = 0,
    updated_at = now()
where minimum_booking_notice_minutes <> 0;

comment on column public.services.minimum_booking_notice_minutes is
  'LEGACY core/global lead time. Must remain 0. Public lead time belongs exclusively to public_minimum_booking_notice_hours so admin/manual bookings are not restricted by advance notice.';
