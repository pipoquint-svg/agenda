begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);

select like(
  pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure),
  '%case when p_change_origin=''CLIENT'' then ''CLIENT'' else ''ADMIN'' end%',
  'cancellation final audit preserves client origin'
);
select unlike(
  pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure),
  '%reason'',nullif(btrim(coalesce(p_reason,'''')),'''')),''ADMIN'');%',
  'cancellation no longer hardcodes ADMIN for final audit'
);
select like(
  pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure),
  '%case when v_action.change_origin=''CLIENT'' then ''CLIENT'' else ''ADMIN'' end%',
  'reschedule apply final audit preserves client origin'
);
select unlike(
  pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure),
  '%package_reconciliation'',v_package_reconciliation),''ADMIN'');%',
  'reschedule apply no longer hardcodes ADMIN for final audit'
);

select * from finish();
rollback;
