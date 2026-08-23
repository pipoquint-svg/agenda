begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);

select ok(
  strpos(
    pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure),
    $$case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end$$
  ) > 0,
  'cancellation final audit preserves client origin'
);
select ok(
  strpos(
    pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure),
    $$),'ADMIN');$$
  ) = 0,
  'cancellation no longer hardcodes ADMIN for final audit'
);
select ok(
  strpos(
    pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure),
    $$case when v_action.change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end$$
  ) > 0,
  'reschedule apply final audit preserves client origin'
);
select ok(
  strpos(
    pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure),
    $$),'ADMIN');$$
  ) = 0,
  'reschedule apply no longer hardcodes ADMIN for final audit'
);

select * from finish();
rollback;
