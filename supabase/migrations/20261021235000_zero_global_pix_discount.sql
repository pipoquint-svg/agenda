-- The Pix discount is turned off (owner decision of 2026-10-21).
-- Services already have an explicit 0%; this zeroes the global default so that a
-- service left on "usar padrão global" does not bring the discount back.
-- Reservations already made keep their frozen pix_discount_percent_snapshot.

update public.operation_settings
set pix_discount_percent = 0,
    updated_at = now()
where id = 1 and pix_discount_percent is distinct from 0;
