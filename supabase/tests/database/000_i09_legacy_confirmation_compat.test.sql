create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(1);

-- Test-only compatibility for legacy fixtures that predate the I-09 confirmed_at
-- invariant and insert CONFIRMED appointments directly. Keep the exception set
-- explicit so newly introduced fixtures cannot silently bypass the invariant.
create or replace function public.test_attach_i09_legacy_confirmation_timestamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'CONFIRMED'
     and new.confirmed_at is null
     and new.id = any(array[
       '30000000-0000-0000-0000-000000000090'::uuid,
       '94000000-0000-0000-0000-000000000070'::uuid,
       '97000000-0000-0000-0000-000000000043'::uuid,
       '97800000-0000-0000-0000-000000000010'::uuid,
       '96000000-0000-0000-0000-000000000030'::uuid,
       '96000000-0000-0000-0000-000000000031'::uuid,
       '95000000-0000-0000-0000-000000000030'::uuid,
       '97000000-0000-0000-0000-000000000030'::uuid,
       '96500000-0000-0000-0000-000000000008'::uuid,
       '96500000-0000-0000-0000-000000000010'::uuid,
       '96700000-0000-0000-0000-000000000006'::uuid
     ]) then
    -- Defaults are available to BEFORE INSERT triggers. Cap the timestamp before
    -- service start so historical/past synthetic appointments remain coherent.
    new.confirmed_at := least(
      coalesce(new.created_at, now()),
      new.start_at - interval '1 second'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists test_i09_legacy_confirmation_timestamp on public.appointments;
create trigger test_i09_legacy_confirmation_timestamp
before insert on public.appointments
for each row execute function public.test_attach_i09_legacy_confirmation_timestamp();

select ok(
  exists(
    select 1 from pg_trigger
    where tgname = 'test_i09_legacy_confirmation_timestamp'
      and not tgisinternal
  ),
  'legacy direct-confirmation fixtures receive explicit test-only confirmed_at values'
);

select * from finish();
