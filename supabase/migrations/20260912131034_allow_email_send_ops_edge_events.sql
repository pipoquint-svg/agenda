alter table public.ops_edge_failure_events
  drop constraint if exists ops_edge_failure_events_function_name_check;

alter table public.ops_edge_failure_events
  add constraint ops_edge_failure_events_function_name_check
  check (
    function_name = any (
      array[
        'booking-hold'::text,
        'booking-checkout'::text,
        'booking-submit'::text,
        'mercado-pago-payment'::text,
        'email-send'::text
      ]
    )
  );
