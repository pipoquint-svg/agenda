-- Rewards target services are selected by checkbox when the immutable version
-- is created. The typed projection lets S4 issue a SERVICE_ONLY coupon without
-- relying on a mutable JSON interpretation at checkout time.
create table public.marketing_campaign_version_services (
  campaign_version_id uuid not null references public.marketing_campaign_versions(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  primary key (campaign_version_id, service_id)
);

alter table public.marketing_campaign_version_services enable row level security;
revoke all on public.marketing_campaign_version_services from public, anon, authenticated, service_role;
grant select on public.marketing_campaign_version_services to service_role;

create or replace function public.capture_marketing_campaign_version_target_services()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_service_ids jsonb := new.eligibility_rules -> 'service_ids';
  v_service_id uuid;
begin
  if new.discount_scope <> 'SERVICE_ONLY' then
    return new;
  end if;

  if v_service_ids is null then
    return new;
  end if;

  if jsonb_typeof(v_service_ids) <> 'array' or jsonb_array_length(v_service_ids) = 0 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_INVALID';
  end if;

  for v_service_id in
    select value::uuid from jsonb_array_elements_text(v_service_ids)
  loop
    if not exists (
      select 1 from public.services s
      where s.id = v_service_id
        and s.operation_scope = 'BLACKSHEEP'
    ) then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICE_INVALID';
    end if;
    insert into public.marketing_campaign_version_services(campaign_version_id, service_id)
    values (new.id, v_service_id);
  end loop;

  return new;
end;
$function$;

create trigger marketing_campaign_versions_capture_target_services
after insert on public.marketing_campaign_versions
for each row execute function public.capture_marketing_campaign_version_target_services();

create or replace function public.enforce_marketing_campaign_target_services_on_activation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.state in ('SCHEDULED', 'ACTIVE')
    and not exists (
      select 1
      from public.marketing_campaign_version_services s
      where s.campaign_version_id = new.active_version_id
    ) then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_REQUIRED';
  end if;
  return new;
end;
$function$;

create trigger marketing_campaigns_require_target_services_on_activation
before update of state, active_version_id on public.marketing_campaigns
for each row execute function public.enforce_marketing_campaign_target_services_on_activation();

revoke all on function public.capture_marketing_campaign_version_target_services() from public, anon, authenticated, service_role;
revoke all on function public.enforce_marketing_campaign_target_services_on_activation() from public, anon, authenticated, service_role;

comment on table public.marketing_campaign_version_services is
  'Immutable projection of checkbox-selected BlackSheep services from a campaign version eligibility_rules.service_ids payload.';
