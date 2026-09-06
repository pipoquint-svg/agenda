alter table public.notification_template_configs
  drop constraint notification_template_configs_event_key_check;

alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check
  check (
    event_key = any (
      array[
        'APPOINTMENT_APPROVED'::text,
        'APPOINTMENT_PENDING'::text,
        'APPOINTMENT_REJECTED'::text,
        'APPOINTMENT_CANCELLED'::text,
        'APPOINTMENT_CHANGED'::text,
        'APPOINTMENT_RESCHEDULED'::text,
        'APPOINTMENT_REMINDER'::text,
        'WAITLIST_AVAILABLE'::text,
        'WAITLIST_SIGNUP_TEAM'::text,
        'BIRTHDAY'::text,
        'RENTAL_BALANCE_DUE'::text,
        'ADMIN_USER_INVITE'::text,
        'MANUAL'::text,
        'REFUND_FAILED'::text,
        'REFUND_COMPLETED'::text,
        'PRE_RESERVATION_CREATED'::text,
        'PAYMENT_PENDING_CREATED'::text
      ]
    )
  );
