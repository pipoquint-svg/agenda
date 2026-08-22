-- Temporary compatibility gate required by the issued-credit inventory stop.
-- Existing production service rows were explicitly migrated to V2 in the prior
-- migration. Rows that still use only the historical shape remain V1-compatible
-- until the issued cancellation-credit inventory is presented and decided.
-- This prevents accidental semantic conversion/removal before that mandatory gate.

create or replace function public.enforce_consolidated_change_policy_v2()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_v2_count integer;
begin
  v_v2_count :=
    (case when new.reschedule_first_early_percent is null then 0 else 1 end) +
    (case when new.reschedule_first_late_percent is null then 0 else 1 end) +
    (case when new.reschedule_repeat_percent is null then 0 else 1 end) +
    (case when new.cancellation_late_percent is null then 0 else 1 end);

  -- Historical-only rows are deliberately left untouched until the issued-credit
  -- inventory gate is resolved. They create V1 snapshots and preserve contracted
  -- legacy behavior. No forward service in the live catalog should remain here,
  -- because the previous migration explicitly converted every configured row.
  if v_v2_count = 0 then
    return new;
  end if;

  if v_v2_count <> 4 then
    raise exception using errcode='P0001', message='CHANGE_POLICY_V2_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  if new.cancellation_early_penalty_type <> 'NONE'
     or new.cancellation_early_penalty_value <> 0 then
    raise exception using errcode='P0001', message='CHANGE_POLICY_V2_EARLY_CANCELLATION_MUST_BE_ZERO';
  end if;

  -- V2 supports percentages only. The legacy columns are compatibility mirrors,
  -- never an independent calculation source.
  new.reschedule_first_penalty_type := case
    when new.reschedule_first_early_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_first_penalty_value := new.reschedule_first_early_percent;

  new.reschedule_late_penalty_type := case
    when new.reschedule_first_late_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_late_penalty_value := new.reschedule_first_late_percent;

  new.reschedule_repeat_penalty_type := case
    when new.reschedule_repeat_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_repeat_penalty_value := new.reschedule_repeat_percent;

  new.cancellation_early_penalty_type := 'NONE';
  new.cancellation_early_penalty_value := 0;
  new.cancellation_late_penalty_type := case
    when new.cancellation_late_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.cancellation_late_penalty_value := new.cancellation_late_percent;

  return new;
end;
$$;
