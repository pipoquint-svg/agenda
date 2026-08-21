create or replace function public.touch_service_extra_schedule_version()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.schedule_placement is distinct from old.schedule_placement
     or new.default_schedule_minutes is distinct from old.default_schedule_minutes
     or new.max_quantity is distinct from old.max_quantity
     or new.is_required is distinct from old.is_required then
    new.schedule_updated_at := now();
  end if;
  return new;
end;
$$;

create trigger service_extras_schedule_version_trg
before update on public.service_extras
for each row execute function public.touch_service_extra_schedule_version();

create or replace function public.touch_extra_schedule_rule_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger service_extra_schedule_rules_updated_at_trg
before update on public.service_extra_schedule_rules
for each row execute function public.touch_extra_schedule_rule_updated_at();

comment on column public.service_extras.schedule_updated_at is
  'Version timestamp included in booking schedule snapshots so timing changes invalidate stale slot selections.';
