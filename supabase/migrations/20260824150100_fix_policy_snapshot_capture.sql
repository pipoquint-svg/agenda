-- Keep the policy row and service-level reschedule configuration as separate
-- lookups so the typed row target remains valid in PL/pgSQL.
create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id=new.id
  ) then return new; end if;

  select * into v_policy
  from public.service_change_policies
  where service_id=new.service_id;
  if not found then return new; end if;

  select coalesce(s.max_reschedules,3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if v_max_reschedules is null then
    raise exception using errcode='P0001',message='SERVICE_RESCHEDULE_CONFIGURATION_MISSING';
  end if;

  v_effective_at := case
    when new.status='AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at,new.created_at)
  end;

  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;
