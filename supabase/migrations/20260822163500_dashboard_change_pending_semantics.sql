-- Dashboard pending-center semantics after retained-penalty migration.
-- Patch the authoritative read model without duplicating the large function body.
do $$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.service_admin_get_dashboard(timestamptz,timestamptz,text)'::regprocedure)
    into v_definition;
  if v_definition is null then
    raise exception using errcode='P0001',message='ADMIN_DASHBOARD_FUNCTION_MISSING';
  end if;
  if position('RESCHEDULE_PENALTY_PENDING' in v_definition)=0
     or position('AWAITING_PENALTY_PAYMENT' in v_definition)=0 then
    raise exception using errcode='P0001',message='ADMIN_DASHBOARD_LEGACY_PENDING_SIGNATURE_NOT_FOUND';
  end if;
  v_definition:=replace(v_definition,'RESCHEDULE_PENALTY_PENDING','RESCHEDULE_DIFFERENCE_PENDING');
  v_definition:=replace(v_definition,'AWAITING_PENALTY_PAYMENT','AWAITING_DIFFERENCE_PAYMENT');
  execute v_definition;
end;
$$;

comment on function public.service_admin_get_dashboard(timestamptz,timestamptz,text) is
'Dashboard V1 read model. Reschedule pending items represent contractual difference still due, never a separate penalty charge.';
