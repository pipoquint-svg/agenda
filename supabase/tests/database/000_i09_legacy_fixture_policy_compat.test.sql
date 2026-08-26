create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(1);

-- Test-only compatibility for legacy fixtures created before I-09 made policy
-- ownership an invariant. These exact synthetic service IDs are used by older
-- tests that confirm appointments but do not exercise change-policy semantics.
-- Production migrations are not weakened and no commercial policy is inferred.
create or replace function public.test_attach_i09_legacy_fixture_policy()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.id = any(array[
    '30000000-0000-0000-0000-000000000030'::uuid,
    '70000000-0000-0000-0000-000000000010'::uuid,
    '80000000-0000-0000-0000-000000000010'::uuid,
    '90000000-0000-0000-0000-000000000010'::uuid,
    '94000000-0000-0000-0000-000000000030'::uuid,
    '97000000-0000-0000-0000-000000000010'::uuid,
    '98000000-0000-0000-0000-000000000010'::uuid,
    '97800000-0000-0000-0000-000000000005'::uuid,
    '94400000-0000-0000-0000-000000000005'::uuid,
    '61000000-0000-0000-0000-000000000004'::uuid,
    '96000000-0000-0000-0000-000000000010'::uuid,
    '95000000-0000-0000-0000-000000000010'::uuid,
    '97000000-0000-0000-0000-000000000022'::uuid,
    '95800000-0000-0000-0000-000000000010'::uuid
  ]) then
    insert into public.service_change_policies(
      service_id,
      notice_hours,
      reschedule_first_early_percent,
      reschedule_first_late_percent,
      reschedule_repeat_percent,
      cancellation_late_percent
    ) values (new.id, 48, 0, 0, 0, 0)
    on conflict (service_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists test_i09_legacy_fixture_policy on public.services;
create trigger test_i09_legacy_fixture_policy
after insert on public.services
for each row execute function public.test_attach_i09_legacy_fixture_policy();

select ok(
  exists(
    select 1 from pg_trigger
    where tgname = 'test_i09_legacy_fixture_policy'
      and not tgisinternal
  ),
  'legacy confirmation fixtures receive explicit test-only policies'
);

select * from finish();
