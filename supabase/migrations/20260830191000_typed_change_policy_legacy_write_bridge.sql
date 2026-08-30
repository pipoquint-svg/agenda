-- Compatibility bridge for legacy V2 writes after typed V3 penalty columns became authoritative.
-- Old callers that still write only *_percent remain valid and are deterministically
-- represented as PERCENT rules. FIXED rules always require an explicit typed value.

create or replace function public.service_change_policy_typed_legacy_bridge()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- INSERT: hydrate typed values from the legacy percentage fields when omitted.
  if tg_op = 'INSERT' then
    new.reschedule_first_early_penalty_type := coalesce(new.reschedule_first_early_penalty_type, 'PERCENT'::public.change_penalty_type);
    new.reschedule_first_late_penalty_type := coalesce(new.reschedule_first_late_penalty_type, 'PERCENT'::public.change_penalty_type);
    new.reschedule_repeat_penalty_type := coalesce(new.reschedule_repeat_penalty_type, 'PERCENT'::public.change_penalty_type);
    new.cancellation_late_penalty_type := coalesce(new.cancellation_late_penalty_type, 'PERCENT'::public.change_penalty_type);

    if new.reschedule_first_early_penalty_value is null and new.reschedule_first_early_penalty_type = 'PERCENT' then
      new.reschedule_first_early_penalty_value := coalesce(new.reschedule_first_early_percent, 0);
    end if;
    if new.reschedule_first_late_penalty_value is null and new.reschedule_first_late_penalty_type = 'PERCENT' then
      new.reschedule_first_late_penalty_value := coalesce(new.reschedule_first_late_percent, 0);
    end if;
    if new.reschedule_repeat_penalty_value is null and new.reschedule_repeat_penalty_type = 'PERCENT' then
      new.reschedule_repeat_penalty_value := coalesce(new.reschedule_repeat_percent, 0);
    end if;
    if new.cancellation_late_penalty_value is null and new.cancellation_late_penalty_type = 'PERCENT' then
      new.cancellation_late_penalty_value := coalesce(new.cancellation_late_percent, 0);
    end if;
    return new;
  end if;

  -- UPDATE: if a legacy percentage changes and the caller did not explicitly alter
  -- the typed pair, keep the two representations synchronized as PERCENT.
  if new.reschedule_first_early_percent is distinct from old.reschedule_first_early_percent
     and new.reschedule_first_early_penalty_type is not distinct from old.reschedule_first_early_penalty_type
     and new.reschedule_first_early_penalty_value is not distinct from old.reschedule_first_early_penalty_value then
    new.reschedule_first_early_penalty_type := 'PERCENT'::public.change_penalty_type;
    new.reschedule_first_early_penalty_value := new.reschedule_first_early_percent;
  end if;

  if new.reschedule_first_late_percent is distinct from old.reschedule_first_late_percent
     and new.reschedule_first_late_penalty_type is not distinct from old.reschedule_first_late_penalty_type
     and new.reschedule_first_late_penalty_value is not distinct from old.reschedule_first_late_penalty_value then
    new.reschedule_first_late_penalty_type := 'PERCENT'::public.change_penalty_type;
    new.reschedule_first_late_penalty_value := new.reschedule_first_late_percent;
  end if;

  if new.reschedule_repeat_percent is distinct from old.reschedule_repeat_percent
     and new.reschedule_repeat_penalty_type is not distinct from old.reschedule_repeat_penalty_type
     and new.reschedule_repeat_penalty_value is not distinct from old.reschedule_repeat_penalty_value then
    new.reschedule_repeat_penalty_type := 'PERCENT'::public.change_penalty_type;
    new.reschedule_repeat_penalty_value := new.reschedule_repeat_percent;
  end if;

  if new.cancellation_late_percent is distinct from old.cancellation_late_percent
     and new.cancellation_late_penalty_type is not distinct from old.cancellation_late_penalty_type
     and new.cancellation_late_penalty_value is not distinct from old.cancellation_late_penalty_value then
    new.cancellation_late_penalty_type := 'PERCENT'::public.change_penalty_type;
    new.cancellation_late_penalty_value := new.cancellation_late_percent;
  end if;

  return new;
end;
$$;

revoke all on function public.service_change_policy_typed_legacy_bridge() from public;

DROP TRIGGER IF EXISTS service_change_policy_typed_legacy_bridge ON public.service_change_policies;
CREATE TRIGGER service_change_policy_typed_legacy_bridge
BEFORE INSERT OR UPDATE ON public.service_change_policies
FOR EACH ROW EXECUTE FUNCTION public.service_change_policy_typed_legacy_bridge();

-- Existing rows must remain fully typed after the bridge is installed.
update public.service_change_policies
set reschedule_first_early_penalty_type = coalesce(reschedule_first_early_penalty_type, 'PERCENT'::public.change_penalty_type),
    reschedule_first_early_penalty_value = coalesce(reschedule_first_early_penalty_value, reschedule_first_early_percent),
    reschedule_first_late_penalty_type = coalesce(reschedule_first_late_penalty_type, 'PERCENT'::public.change_penalty_type),
    reschedule_first_late_penalty_value = coalesce(reschedule_first_late_penalty_value, reschedule_first_late_percent),
    reschedule_repeat_penalty_type = coalesce(reschedule_repeat_penalty_type, 'PERCENT'::public.change_penalty_type),
    reschedule_repeat_penalty_value = coalesce(reschedule_repeat_penalty_value, reschedule_repeat_percent),
    cancellation_late_penalty_type = coalesce(cancellation_late_penalty_type, 'PERCENT'::public.change_penalty_type),
    cancellation_late_penalty_value = coalesce(cancellation_late_penalty_value, cancellation_late_percent);
