
-- BEGIN RC MIGRATION 20260824180000_customer_access_controls.sql
-- Customer access controls: append-only restrictions/blocking and free-visit policy.

alter table public.services add column if not exists booking_product_type text not null default 'STANDARD';
alter table public.services drop constraint if exists services_booking_product_type_check;
alter table public.services add constraint services_booking_product_type_check check (booking_product_type in ('STANDARD','FREE_VISIT'));

alter table public.appointments add column if not exists free_visit_confirmed_at timestamptz;
alter table public.appointments add column if not exists free_visit_confirmation_deadline timestamptz;

create table if not exists public.customer_access_policy_settings (
  id smallint primary key default 1 check (id=1),
  max_active_free_visits integer not null default 1 check (max_active_free_visits>=1),
  free_visit_confirmation_hours_before integer not null default 24 check (free_visit_confirmation_hours_before between 1 and 168),
  free_visit_no_show_threshold integer not null default 1 check (free_visit_no_show_threshold>=1),
  history_retention_years integer not null default 5 check (history_retention_years between 1 and 20),
  auto_no_free_visits boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.customer_access_policy_settings(id) values(1) on conflict(id) do nothing;

create table if not exists public.customer_identity_keys (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  key_type text not null check (key_type in ('TAX_ID','PHONE','EMAIL')),
  normalized_value text not null,
  first_seen_at timestamptz not null default now(),
  unique(customer_id,key_type,normalized_value)
);
create index if not exists customer_identity_keys_lookup_idx on public.customer_identity_keys(key_type,normalized_value);

create table if not exists public.customer_access_events (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  event_type text not null check (event_type in ('RESTRICTION_APPLIED','RESTRICTION_REMOVED','RESTRICTION_EXPIRED','BLOCK_APPLIED','BLOCK_REMOVED','BLOCKED_BOOKING_ATTEMPT','IDENTITY_REVIEW_REQUIRED','SECOND_NO_SHOW_ALERT')),
  restriction_type text check (restriction_type is null or restriction_type in ('REQUIRE_FULL_PAYMENT','NO_FREE_VISITS','NO_ONLINE_BOOKING')),
  subject_event_id uuid references public.customer_access_events(id) on delete restrict,
  reason_text text,
  related_appointment_ids uuid[] not null default '{}',
  effective_from timestamptz,
  effective_until timestamptz,
  communicated_at timestamptz,
  actor_admin_id uuid references public.admin_users(id) on delete restrict,
  automated boolean not null default false,
  permission_used text,
  used_key_type text,
  used_key_value text,
  ip_address inet,
  user_agent text,
  request_id uuid,
  created_at timestamptz not null default now(),
  check (event_type not in ('BLOCK_APPLIED','BLOCK_REMOVED') or length(btrim(coalesce(reason_text,'')))>=10),
  check (event_type not like 'RESTRICTION_%' or restriction_type is not null)
);
create index if not exists customer_access_events_customer_idx on public.customer_access_events(customer_id,created_at desc);
create index if not exists customer_access_events_subject_idx on public.customer_access_events(subject_event_id) where subject_event_id is not null;

alter table public.customer_identity_keys enable row level security;
alter table public.customer_access_events enable row level security;
alter table public.customer_access_policy_settings enable row level security;
revoke all on public.customer_identity_keys,public.customer_access_events,public.customer_access_policy_settings from public,anon,authenticated;
grant select,insert on public.customer_identity_keys,public.customer_access_events to service_role;
grant select on public.customer_access_policy_settings to service_role;

create or replace function public.guard_customer_access_append_only() returns trigger language plpgsql set search_path=public as $$
begin raise exception using errcode='42501',message='CUSTOMER_ACCESS_HISTORY_APPEND_ONLY'; end; $$;
drop trigger if exists customer_access_events_append_only on public.customer_access_events;
create trigger customer_access_events_append_only before update or delete on public.customer_access_events for each statement execute function public.guard_customer_access_append_only();
drop trigger if exists customer_identity_keys_append_only on public.customer_identity_keys;
create trigger customer_identity_keys_append_only before update or delete on public.customer_identity_keys for each statement execute function public.guard_customer_access_append_only();
revoke all on function public.guard_customer_access_append_only() from public,anon,authenticated;

create or replace function public.capture_customer_identity_keys(p_customer_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare c public.customers%rowtype;
begin
 select * into c from public.customers where id=p_customer_id;
 if not found then return; end if;
 if nullif(regexp_replace(coalesce(c.cpf_cnpj,''),'\D','','g'),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'TAX_ID',regexp_replace(c.cpf_cnpj,'\D','','g')) on conflict do nothing; end if;
 if nullif(regexp_replace(coalesce(c.phone,''),'\D','','g'),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'PHONE',regexp_replace(c.phone,'\D','','g')) on conflict do nothing; end if;
 if nullif(lower(btrim(coalesce(c.email,''))),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'EMAIL',lower(btrim(c.email))) on conflict do nothing; end if;
end; $$;

create or replace function public.customers_capture_identity_keys_trigger() returns trigger language plpgsql security definer set search_path=public as $$ begin perform public.capture_customer_identity_keys(new.id); return new; end; $$;
drop trigger if exists customers_capture_identity_keys on public.customers;
create trigger customers_capture_identity_keys after insert or update of cpf_cnpj,phone,email on public.customers for each row execute function public.customers_capture_identity_keys_trigger();

insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'TAX_ID',regexp_replace(cpf_cnpj,'\D','','g') from public.customers where nullif(regexp_replace(coalesce(cpf_cnpj,''),'\D','','g'),'') is not null on conflict do nothing;
insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'PHONE',regexp_replace(phone,'\D','','g') from public.customers where nullif(regexp_replace(coalesce(phone,''),'\D','','g'),'') is not null on conflict do nothing;
insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'EMAIL',lower(btrim(email)) from public.customers where nullif(lower(btrim(coalesce(email,''))),'') is not null on conflict do nothing;

create or replace view public.customer_effective_access as
with applies as (
 select e.*,
   exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type in ('RESTRICTION_REMOVED','RESTRICTION_EXPIRED','BLOCK_REMOVED')) as ended
 from public.customer_access_events e
 where e.event_type in ('RESTRICTION_APPLIED','BLOCK_APPLIED')
)
select customer_id,
 bool_or(event_type='BLOCK_APPLIED' and not ended) as online_blocked,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='REQUIRE_FULL_PAYMENT' and not ended and (effective_until is null or effective_until>now())) as require_full_payment,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='NO_FREE_VISITS' and not ended and (effective_until is null or effective_until>now())) as no_free_visits,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='NO_ONLINE_BOOKING' and not ended and (effective_until is null or effective_until>now())) as no_online_booking
from applies group by customer_id;

create or replace view public.customer_behavior_summary as
select c.id as customer_id,
 count(a.id)::integer as total_reservations,
 count(*) filter(where a.status='COMPLETED')::integer as attendances,
 count(*) filter(where a.status='NO_SHOW')::integer as no_shows,
 count(*) filter(where a.status='CANCELLED' and a.cancelled_at is not null and a.cancelled_at<=a.start_at-interval '48 hours')::integer as cancellations_over_48h,
 count(*) filter(where a.status='CANCELLED' and a.cancelled_at is not null and a.cancelled_at>a.start_at-interval '48 hours')::integer as cancellations_under_48h,
 coalesce((select count(*) from public.appointment_policy_actions pa join public.appointments aa on aa.id=pa.appointment_id where aa.primary_customer_id=c.id and pa.action_type='RESCHEDULE'),0)::integer as reschedules_requested,
 count(*) filter(where s.booking_product_type='FREE_VISIT')::integer as free_visits_scheduled,
 count(*) filter(where s.booking_product_type='FREE_VISIT' and a.status='COMPLETED')::integer as free_visits_attended,
 coalesce(sum(a.commercial_value),0)::numeric(14,2) as total_contract_value
from public.customers c
left join public.appointments a on a.primary_customer_id=c.id and a.deleted_at is null
left join public.services s on s.id=a.service_id
group by c.id;

revoke all on public.customer_effective_access,public.customer_behavior_summary from public,anon,authenticated;
grant select on public.customer_effective_access,public.customer_behavior_summary to service_role;

create or replace function public.expire_customer_restrictions() returns integer language plpgsql volatile security definer set search_path=public as $$
declare r record; n integer:=0;
begin
 for r in select e.* from public.customer_access_events e where e.event_type='RESTRICTION_APPLIED' and e.effective_until is not null and e.effective_until<=now() and not exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type in ('RESTRICTION_REMOVED','RESTRICTION_EXPIRED')) loop
  insert into public.customer_access_events(customer_id,event_type,restriction_type,subject_event_id,reason_text,automated,permission_used) values(r.customer_id,'RESTRICTION_EXPIRED',r.restriction_type,r.id,'Restrição expirada conforme prazo configurado.',true,'SYSTEM'); n:=n+1;
 end loop; return n;
end; $$;

create or replace function public.service_apply_customer_restriction(p_customer_id uuid,p_type text,p_reason text,p_admin_id uuid,p_until timestamptz default null,p_related uuid[] default '{}') returns uuid language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if p_type not in ('REQUIRE_FULL_PAYMENT','NO_FREE_VISITS','NO_ONLINE_BOOKING') then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_TYPE_INVALID'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_REASON_REQUIRED'; end if;
 perform public.capture_customer_identity_keys(p_customer_id);
 insert into public.customer_access_events(customer_id,event_type,restriction_type,reason_text,related_appointment_ids,effective_from,effective_until,actor_admin_id,permission_used) values(p_customer_id,'RESTRICTION_APPLIED',p_type,btrim(p_reason),coalesce(p_related,'{}'),now(),p_until,p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id; return v_id;
end; $$;

create or replace function public.service_remove_customer_restriction(p_event_id uuid,p_reason text,p_admin_id uuid) returns uuid language plpgsql volatile security definer set search_path=public as $$
declare r public.customer_access_events%rowtype; v_id uuid;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_REASON_REQUIRED'; end if;
 select * into r from public.customer_access_events where id=p_event_id and event_type='RESTRICTION_APPLIED'; if not found then raise exception using errcode='P0001',message='CUSTOMER_RESTRICTION_NOT_FOUND'; end if;
 insert into public.customer_access_events(customer_id,event_type,restriction_type,subject_event_id,reason_text,actor_admin_id,permission_used) values(r.customer_id,'RESTRICTION_REMOVED',r.restriction_type,r.id,btrim(p_reason),p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id; return v_id;
end; $$;

create or replace function public.service_set_customer_block(p_customer_id uuid,p_block boolean,p_reason text,p_admin_id uuid,p_related uuid[] default '{}',p_communicated_at timestamptz default null) returns uuid language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid; r public.customer_access_events%rowtype;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_BLOCK_REASON_REQUIRED'; end if;
 perform public.capture_customer_identity_keys(p_customer_id);
 if p_block then
  insert into public.customer_access_events(customer_id,event_type,reason_text,related_appointment_ids,effective_from,communicated_at,actor_admin_id,permission_used) values(p_customer_id,'BLOCK_APPLIED',btrim(p_reason),coalesce(p_related,'{}'),now(),p_communicated_at,p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id;
 else
  select * into r from public.customer_access_events e where e.customer_id=p_customer_id and e.event_type='BLOCK_APPLIED' and not exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type='BLOCK_REMOVED') order by e.created_at desc limit 1;
  if not found then raise exception using errcode='P0001',message='CUSTOMER_BLOCK_NOT_FOUND'; end if;
  insert into public.customer_access_events(customer_id,event_type,subject_event_id,reason_text,actor_admin_id,permission_used) values(p_customer_id,'BLOCK_REMOVED',r.id,btrim(p_reason),p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id;
 end if; return v_id;
end; $$;

create or replace function public.service_public_check_customer_access(p_checkout_hold_token text,p_ip inet,p_user_agent text,p_request_id uuid) returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare h public.checkout_holds%rowtype; a record; s public.services%rowtype; n integer; other uuid;
begin
 perform public.expire_customer_restrictions();
 select * into h from public.checkout_holds where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex') and status='ACTIVE' and expires_at>now();
 if not found or h.primary_customer_id is null then raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED'; end if;
 select * into s from public.services where id=h.service_id;
 select * into a from public.customer_effective_access where customer_id=h.primary_customer_id;
 if coalesce(a.online_blocked,false) or coalesce(a.no_online_booking,false) then
  insert into public.customer_access_events(customer_id,event_type,reason_text,automated,permission_used,ip_address,user_agent,request_id) values(h.primary_customer_id,'BLOCKED_BOOKING_ATTEMPT','Tentativa de reserva online recusada por controle de acesso ativo.',true,'SYSTEM',p_ip,left(p_user_agent,1000),p_request_id);
  raise exception using errcode='P0001',message='ONLINE_BOOKING_NOT_AVAILABLE';
 end if;
 if s.booking_product_type='FREE_VISIT' and coalesce(a.no_free_visits,false) then raise exception using errcode='P0001',message='FREE_VISIT_NOT_AVAILABLE'; end if;
 if s.booking_product_type='FREE_VISIT' then
  select count(*)::integer into n from public.appointments ap join public.services ss on ss.id=ap.service_id where ap.primary_customer_id=h.primary_customer_id and ss.booking_product_type='FREE_VISIT' and ap.status in ('AWAITING_PAYMENT','CONFIRMED') and ap.start_at>=now();
  if n>=1 then raise exception using errcode='P0001',message='FREE_VISIT_ACTIVE_LIMIT_REACHED'; end if;
 end if;
 for other in select distinct k2.customer_id from public.customer_identity_keys k1 join public.customer_identity_keys k2 on k2.key_type=k1.key_type and k2.normalized_value=k1.normalized_value and k2.customer_id<>k1.customer_id join public.customer_effective_access ea on ea.customer_id=k2.customer_id and ea.online_blocked where k1.customer_id=h.primary_customer_id loop
  insert into public.customer_access_events(customer_id,event_type,reason_text,automated,permission_used,ip_address,user_agent,request_id) values(h.primary_customer_id,'IDENTITY_REVIEW_REQUIRED','Chave de identidade coincide com outro cadastro bloqueado; revisão administrativa necessária.',true,'SYSTEM',p_ip,left(p_user_agent,1000),p_request_id);
 end loop;
 return jsonb_build_object('allowed',true,'require_full_payment',coalesce(a.require_full_payment,false),'free_visit',s.booking_product_type='FREE_VISIT');
end; $$;

create or replace function public.customer_access_appointment_before_insert() returns trigger language plpgsql security definer set search_path=public as $$
declare a record; s public.services%rowtype; cfg public.customer_access_policy_settings%rowtype;
begin
 if new.origin<>'PUBLIC' or new.primary_customer_id is null then return new; end if;
 select * into a from public.customer_effective_access where customer_id=new.primary_customer_id;
 if coalesce(a.online_blocked,false) or coalesce(a.no_online_booking,false) then raise exception using errcode='P0001',message='ONLINE_BOOKING_NOT_AVAILABLE'; end if;
 if coalesce(a.require_full_payment,false) then new.confirmation_percentage_snapshot:=100; end if;
 select * into s from public.services where id=new.service_id;
 if s.booking_product_type='FREE_VISIT' then
  if coalesce(a.no_free_visits,false) then raise exception using errcode='P0001',message='FREE_VISIT_NOT_AVAILABLE'; end if;
  select * into cfg from public.customer_access_policy_settings where id=1;
  new.free_visit_confirmation_deadline:=new.start_at-make_interval(hours=>cfg.free_visit_confirmation_hours_before);
 end if;
 return new;
end; $$;
drop trigger if exists customer_access_appointment_before_insert on public.appointments;
create trigger customer_access_appointment_before_insert before insert on public.appointments for each row execute function public.customer_access_appointment_before_insert();

create or replace function public.customer_access_no_show_after_update() returns trigger language plpgsql security definer set search_path=public as $$
declare s public.services%rowtype; cfg public.customer_access_policy_settings%rowtype; n integer;
begin
 if new.status='NO_SHOW' and old.status is distinct from 'NO_SHOW' and new.primary_customer_id is not null then
  select * into s from public.services where id=new.service_id;
  select count(*)::integer into n from public.appointments where primary_customer_id=new.primary_customer_id and status='NO_SHOW';
  if n=2 then insert into public.customer_access_events(customer_id,event_type,reason_text,related_appointment_ids,automated,permission_used) values(new.primary_customer_id,'SECOND_NO_SHOW_ALERT','Cliente atingiu o segundo não comparecimento.',array[new.id],true,'SYSTEM'); end if;
  if s.booking_product_type='FREE_VISIT' then
   select * into cfg from public.customer_access_policy_settings where id=1;
   select count(*)::integer into n from public.appointments ap join public.services ss on ss.id=ap.service_id where ap.primary_customer_id=new.primary_customer_id and ap.status='NO_SHOW' and ss.booking_product_type='FREE_VISIT';
   if cfg.auto_no_free_visits and n>=cfg.free_visit_no_show_threshold and not exists(select 1 from public.customer_effective_access ea where ea.customer_id=new.primary_customer_id and ea.no_free_visits) then
    insert into public.customer_access_events(customer_id,event_type,restriction_type,reason_text,related_appointment_ids,effective_from,automated,permission_used) values(new.primary_customer_id,'RESTRICTION_APPLIED','NO_FREE_VISITS','Restrição automática após não comparecimento em visita gratuita.',array[new.id],now(),true,'SYSTEM');
   end if;
  end if;
 end if; return new;
end; $$;
drop trigger if exists customer_access_no_show_after_update on public.appointments;
create trigger customer_access_no_show_after_update after update of status on public.appointments for each row execute function public.customer_access_no_show_after_update();

create or replace function public.expire_unconfirmed_free_visits() returns integer language plpgsql volatile security definer set search_path=public as $$
declare r record; n integer:=0;
begin
 for r in select a.id from public.appointments a join public.services s on s.id=a.service_id where s.booking_product_type='FREE_VISIT' and a.status='CONFIRMED' and a.free_visit_confirmed_at is null and a.free_visit_confirmation_deadline is not null and a.free_visit_confirmation_deadline<=now() for update of a loop
  update public.appointments set status='CANCELLED',cancelled_at=now(),cancel_reason='FREE_VISIT_CONFIRMATION_MISSING',updated_at=now() where id=r.id;
  update public.resource_allocations set status='CANCELLED',updated_at=now() where appointment_id=r.id and status='ACTIVE'; n:=n+1;
 end loop; return n;
end; $$;

revoke all on function public.capture_customer_identity_keys(uuid),public.expire_customer_restrictions(),public.service_apply_customer_restriction(uuid,text,text,uuid,timestamptz,uuid[]),public.service_remove_customer_restriction(uuid,text,uuid),public.service_set_customer_block(uuid,boolean,text,uuid,uuid[],timestamptz),public.service_public_check_customer_access(text,inet,text,uuid),public.expire_unconfirmed_free_visits() from public,anon,authenticated;
grant execute on function public.capture_customer_identity_keys(uuid),public.expire_customer_restrictions(),public.service_apply_customer_restriction(uuid,text,text,uuid,timestamptz,uuid[]),public.service_remove_customer_restriction(uuid,text,uuid),public.service_set_customer_block(uuid,boolean,text,uuid,uuid[],timestamptz),public.service_public_check_customer_access(text,inet,text,uuid),public.expire_unconfirmed_free_visits() to service_role;
-- END RC MIGRATION 20260824180000_customer_access_controls.sql

-- BEGIN RC MIGRATION 20260824180010_customer_access_rbac.sql
alter table public.admin_user_permissions drop constraint if exists admin_user_permissions_permission_check;
alter table public.admin_user_permissions add constraint admin_user_permissions_permission_check check (permission in (
  'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW',
  'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE',
  'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','AUDIT_VIEW','TEAM_MANAGE'
));

create or replace function public.service_admin_role_default_permission(p_role text,p_permission text)
returns boolean language sql immutable set search_path=public as $$
 select case upper(p_role)
  when 'OWNER' then true
  when 'ADMIN' then true
  when 'OPERATION' then p_permission in ('DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','PACKAGES_VIEW')
  when 'FINANCE' then p_permission in ('DASHBOARD_VIEW','AGENDA_VIEW','CUSTOMERS_VIEW','FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW')
  else false end;
$$;

create or replace function public.service_admin_get_access_profile(p_admin_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object(
  'admin_user_id',a.id,'display_name',a.display_name,'role',a.role,
  'permissions',(select jsonb_object_agg(p.permission,public.service_admin_has_permission(a.id,p.permission)) from (values
   ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),('CUSTOMER_ACCESS_DETAIL_VIEW'),
   ('FINANCE_VIEW'),('FINANCE_MANAGE'),('PACKAGES_VIEW'),('PACKAGES_MANAGE'),('SERVICES_VIEW'),('SERVICES_MANAGE'),
   ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),('LEADS_VIEW'),('LEADS_MANAGE'),('AUDIT_VIEW'),('TEAM_MANAGE')
  ) p(permission))
 ) from public.admin_users a where a.id=p_admin_id and a.is_active=true;
$$;

create or replace function public.service_admin_set_permission(p_target_admin_id uuid,p_permission text,p_is_granted boolean,p_actor_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb; v_after jsonb;
begin
 if not public.service_admin_has_permission(p_actor_admin_id,'TEAM_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 if not exists(select 1 from public.admin_users where id=p_target_admin_id) then raise exception using errcode='P0001',message='ADMIN_USER_NOT_FOUND'; end if;
 if p_permission not in ('DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW','FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE','INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','AUDIT_VIEW','TEAM_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_INVALID'; end if;
 select public.service_admin_get_access_profile(p_target_admin_id) into v_before;
 insert into public.admin_user_permissions(admin_user_id,permission,is_granted,updated_by_admin_id,updated_at) values(p_target_admin_id,p_permission,p_is_granted,p_actor_admin_id,now()) on conflict(admin_user_id,permission) do update set is_granted=excluded.is_granted,updated_by_admin_id=excluded.updated_by_admin_id,updated_at=now();
 select public.service_admin_get_access_profile(p_target_admin_id) into v_after;
 insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_actor_admin_id,'ADMIN_USER',p_target_admin_id,'PERMISSION_CHANGED',v_before,v_after,'ADMIN');
 return v_after;
end; $$;

revoke all on function public.service_admin_role_default_permission(text,text),public.service_admin_get_access_profile(uuid),public.service_admin_set_permission(uuid,text,boolean,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_role_default_permission(text,text),public.service_admin_get_access_profile(uuid),public.service_admin_set_permission(uuid,text,boolean,uuid) to service_role;
-- END RC MIGRATION 20260824180010_customer_access_rbac.sql

-- BEGIN RC MIGRATION 20260824180020_free_visit_confirmation.sql
-- Auditable administrative confirmation for free visits.
create or replace function public.service_admin_confirm_free_visit(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;
  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  if not found or v_service.booking_product_type<>'FREE_VISIT' then
    raise exception using errcode='P0001',message='FREE_VISIT_REQUIRED';
  end if;
  if v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='FREE_VISIT_NOT_CONFIRMABLE';
  end if;
  if v_appointment.start_at<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_ALREADY_STARTED';
  end if;
  if v_appointment.free_visit_confirmation_deadline is not null
     and v_appointment.free_visit_confirmation_deadline<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_CONFIRMATION_DEADLINE_PASSED';
  end if;

  if v_appointment.free_visit_confirmed_at is null then
    update public.appointments
    set free_visit_confirmed_at=now(),updated_at=now()
    where id=p_appointment_id;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(
      p_admin_id,'APPOINTMENT',p_appointment_id,'FREE_VISIT_CONFIRMED',
      jsonb_build_object('free_visit_confirmed_at',null,'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      jsonb_build_object('free_visit_confirmed_at',now(),'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      'ADMIN'
    );
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'confirmed',true,
    'free_visit_confirmed_at',(select free_visit_confirmed_at from public.appointments where id=p_appointment_id),
    'confirmation_deadline',v_appointment.free_visit_confirmation_deadline
  );
end;
$$;

revoke all on function public.service_admin_confirm_free_visit(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_confirm_free_visit(uuid,uuid) to service_role;
-- END RC MIGRATION 20260824180020_free_visit_confirmation.sql

-- BEGIN RC MIGRATION 20260824183000_fix_payment_preview_volatility.sql
-- payment-preview calls the token resolver, which records token usage and takes a row lock.
-- The wrapper therefore cannot be STABLE/read-only.

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  v_context := public.service_get_public_payment_context(p_access_token);

  v_minimum_contract := round(coalesce((v_context->>'minimum_due_contract_amount')::numeric, 0), 2);
  v_full_contract := round(coalesce((v_context->>'contract_balance')::numeric, 0), 2);

  select round(coalesce(os.pix_discount_percent, 0), 2)
  into v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if v_discount_percent is null then
    raise exception using errcode = 'P0001', message = 'PAYMENT_SETTINGS_LOAD_FAILED';
  end if;

  v_minimum_pix := public.service_calculate_payment_cash_amount(v_minimum_contract, 'PIX', v_discount_percent);
  v_full_pix := public.service_calculate_payment_cash_amount(v_full_contract, 'PIX', v_discount_percent);

  return jsonb_build_object(
    'pix_discount_percent', v_discount_percent,
    'confirmation_percentage', (v_context->>'confirmation_percentage')::numeric,
    'minimum_available', coalesce((v_context->>'minimum_available')::boolean, false),
    'full_available', coalesce((v_context->>'full_available')::boolean, false),
    'minimum_due_contract_amount', v_minimum_contract,
    'minimum_due_card_cash_amount', v_minimum_contract,
    'minimum_due_pix_cash_amount', (v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount', v_full_contract,
    'full_due_card_cash_amount', v_full_contract,
    'full_due_pix_cash_amount', (v_full_pix->>'cash_amount')::numeric
  );
end;
$$;

revoke all on function public.service_get_public_payment_method_preview(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_method_preview(text) to service_role;
-- END RC MIGRATION 20260824183000_fix_payment_preview_volatility.sql

-- BEGIN RC MIGRATION 20260824185024_harden_internal_trigger_rpcs.sql
begin;

-- Internal trigger functions execute only through their table triggers.
-- They are not part of the public Data API surface and must not be callable
-- directly by anon/authenticated roles through /rest/v1/rpc/*.
revoke execute on function public.customer_access_appointment_before_insert() from public, anon, authenticated;
revoke execute on function public.customer_access_no_show_after_update() from public, anon, authenticated;
revoke execute on function public.customers_capture_identity_keys_trigger() from public, anon, authenticated;
revoke execute on function public.enqueue_no_show_balance_cancellation() from public, anon, authenticated;

-- The advisor can report this helper on hosted environments even when a clean
-- migration replay does not contain the legacy function. Harden every existing
-- overload when present, but keep a fresh local rebuild deterministic.
do $$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'kommo_guard_adjust_due'
      and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public', v_signature);
  end loop;
end;
$$;

commit;
-- END RC MIGRATION 20260824185024_harden_internal_trigger_rpcs.sql

-- BEGIN RC MIGRATION 20260824220039_blacksheep_closing_buffer.sql
-- BlackSheep rental commercial hours: client-facing booking may run until 22:00.
-- The post-service buffer remains an internal resource occupation and may extend
-- 30 minutes beyond closing, so the physical studio resource stays available
-- through 22:30 for allocation purposes only.
--
-- Scope is intentionally limited to the staging BlackSheep rental service by
-- stable slug. Environments without this synthetic service are a no-op.

update public.availability_rules ar
set end_local_time = '22:00'::time,
    updated_at = now()
from public.service_employees se
join public.services s on s.id = se.service_id
where ar.service_employee_id = se.id
  and s.slug = 'staging-locacao-blacksheep-duracao'
  and ar.is_active;

update public.resource_availability_rules rar
set end_local_time = '22:30'::time,
    updated_at = now()
where rar.resource_id in (
  select sr.resource_id
  from public.service_resources sr
  join public.services s on s.id = sr.service_id
  where s.slug = 'staging-locacao-blacksheep-duracao'
    and sr.is_required
)
  and rar.is_active;
-- END RC MIGRATION 20260824220039_blacksheep_closing_buffer.sql

-- BEGIN RC MIGRATION 20260825103000_first_owner_bootstrap.sql
CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner(
  p_auth_user_id uuid,
  p_display_name text,
  p_request_id uuid DEFAULT gen_random_uuid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_profile jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('agenda:first-owner-bootstrap', 0));

  IF EXISTS (SELECT 1 FROM public.admin_users) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_CLOSED';
  END IF;

  IF p_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.users WHERE id = p_auth_user_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_AUTH_USER_NOT_FOUND';
  END IF;

  IF length(v_display_name) < 2 OR length(v_display_name) > 120 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_DISPLAY_NAME_INVALID';
  END IF;

  INSERT INTO public.admin_users (auth_user_id, display_name, role, is_active)
  VALUES (p_auth_user_id, v_display_name, 'OWNER', true)
  RETURNING id INTO v_admin_id;

  v_profile := public.service_admin_get_access_profile(v_admin_id);

  INSERT INTO public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin,
    request_id
  ) VALUES (
    v_admin_id,
    'ADMIN_USER',
    v_admin_id,
    'FIRST_OWNER_BOOTSTRAPPED',
    NULL,
    jsonb_build_object(
      'admin_user_id', v_admin_id,
      'auth_user_id', p_auth_user_id,
      'display_name', v_display_name,
      'role', 'OWNER',
      'is_active', true,
      'bootstrap', true
    ),
    'SYSTEM',
    p_request_id
  );

  RETURN v_profile;
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) IS
  'One-time, service-role-only bootstrap for the first OWNER. Permanently closes after any admin_users row exists.';
-- END RC MIGRATION 20260825103000_first_owner_bootstrap.sql

-- BEGIN RC MIGRATION 20260825114500_cover_remaining_foreign_keys.sql
CREATE INDEX IF NOT EXISTS appointment_balance_collections_created_by_admin_idx
  ON public.appointment_balance_collections (created_by_admin_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_appointment_idx
  ON public.balance_collection_divergences (appointment_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_collection_idx
  ON public.balance_collection_divergences (balance_collection_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_payment_tx_idx
  ON public.balance_collection_divergences (payment_transaction_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_resolved_by_admin_idx
  ON public.balance_collection_divergences (resolved_by_admin_id);

CREATE INDEX IF NOT EXISTS customer_access_events_actor_admin_idx
  ON public.customer_access_events (actor_admin_id);
-- END RC MIGRATION 20260825114500_cover_remaining_foreign_keys.sql

-- BEGIN RC MIGRATION 20260825135109_authenticated_first_owner_bootstrap_bridge.sql
-- Reconcile the authenticated first-OWNER bridge that was applied to the
-- sandbox before it was committed to the authoritative migration history.
--
-- Security contract:
-- - authenticated caller must have a Supabase session (`auth.uid()`);
-- - only the confirmed studio admin address may invoke the one-time bootstrap;
-- - the service-role-only primitive remains the authority for creating OWNER;
-- - no service_role credential is exposed to the browser.

CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner_authenticated(
  p_display_name text DEFAULT 'BlackSheep Agenda'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_confirmed boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_AUTH_REQUIRED';
  END IF;

  SELECT lower(email), email_confirmed_at IS NOT NULL
    INTO v_email, v_confirmed
  FROM auth.users
  WHERE id = v_uid;

  IF v_email IS DISTINCT FROM lower('agenda@blacksheepestudiocriativo.com.br') THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_DENIED';
  END IF;

  IF coalesce(v_confirmed, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_UNCONFIRMED';
  END IF;

  RETURN public.service_bootstrap_first_owner(
    v_uid,
    p_display_name,
    gen_random_uuid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) IS
  'One-time authenticated bridge for the first BlackSheep Agenda OWNER. Restricted to the confirmed studio admin email and delegates to the service-role-only bootstrap primitive.';
-- END RC MIGRATION 20260825135109_authenticated_first_owner_bootstrap_bridge.sql

-- BEGIN RC MIGRATION 20260825154800_remove_kommo_guard_drift.sql
-- Remove the isolated Kommo Guard drift from Agenda databases.
--
-- Safety contract:
-- - fresh/rebuilt databases where the drift never existed: no-op;
-- - drifted sandbox: only remove the exact audited object set;
-- - abort if inventory, row counts, or cross-subsystem foreign keys differ;
-- - no CASCADE.

DO $$
DECLARE
  v_tables text[];
  v_external_fk_count integer;
  v_function_count integer;
BEGIN
  SELECT coalesce(array_agg(table_name ORDER BY table_name), ARRAY[]::text[])
    INTO v_tables
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name LIKE 'kommo_guard_%';

  SELECT count(*)
    INTO v_function_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'kommo_guard_adjust_due';

  -- Authoritative clean rebuilds have neither the drift tables nor helper.
  IF cardinality(v_tables) = 0 AND v_function_count = 0 THEN
    RETURN;
  END IF;

  IF v_tables <> ARRAY[
    'kommo_guard_audit_log',
    'kommo_guard_discovery_cache',
    'kommo_guard_lead_state',
    'kommo_guard_outgoing_messages',
    'kommo_guard_reconciliation_runs',
    'kommo_guard_rules',
    'kommo_guard_schedules',
    'kommo_guard_settings',
    'kommo_guard_talks',
    'kommo_guard_webhook_inbox'
  ]::text[] THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INVENTORY_MISMATCH: %', v_tables;
  END IF;

  IF v_function_count <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_FUNCTION_INVENTORY_MISMATCH: %', v_function_count;
  END IF;

  -- Refuse cleanup if any FK crosses the Kommo Guard boundary.
  SELECT count(*)
    INTO v_external_fk_count
  FROM pg_constraint con
  JOIN pg_class child ON child.oid = con.conrelid
  JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
  JOIN pg_class parent ON parent.oid = con.confrelid
  JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  WHERE con.contype = 'f'
    AND child_ns.nspname = 'public'
    AND parent_ns.nspname = 'public'
    AND ((child.relname LIKE 'kommo_guard_%') <> (parent.relname LIKE 'kommo_guard_%'));

  IF v_external_fk_count <> 0 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_EXTERNAL_FK_DEPENDENCY: %', v_external_fk_count;
  END IF;

  -- The sanitized snapshot in docs/qa/kommo-guard/ is authoritative for the
  -- only persisted drift data. Abort rather than discard anything newer.
  IF (SELECT count(*) FROM public.kommo_guard_audit_log) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_lead_state) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_outgoing_messages) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_reconciliation_runs) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_schedules) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_talks) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_webhook_inbox) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_discovery_cache) <> 1
     OR (SELECT count(*) FROM public.kommo_guard_rules) <> 18
     OR (SELECT count(*) FROM public.kommo_guard_settings) <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_DATA_DRIFT_DETECTED';
  END IF;
END
$$;

-- Drop the only helper before its settings table. Exact signature, no CASCADE.
DROP FUNCTION IF EXISTS public.kommo_guard_adjust_due(timestamptz);

-- Child tables before referenced parents; every drop is explicit and non-CASCADE.
DROP TABLE IF EXISTS public.kommo_guard_audit_log;
DROP TABLE IF EXISTS public.kommo_guard_outgoing_messages;
DROP TABLE IF EXISTS public.kommo_guard_schedules;
DROP TABLE IF EXISTS public.kommo_guard_rules;
DROP TABLE IF EXISTS public.kommo_guard_discovery_cache;
DROP TABLE IF EXISTS public.kommo_guard_lead_state;
DROP TABLE IF EXISTS public.kommo_guard_reconciliation_runs;
DROP TABLE IF EXISTS public.kommo_guard_talks;
DROP TABLE IF EXISTS public.kommo_guard_webhook_inbox;
DROP TABLE IF EXISTS public.kommo_guard_settings;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name LIKE 'kommo_guard_%'
  ) OR EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'kommo_guard_%'
  ) THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INCOMPLETE';
  END IF;
END
$$;
-- END RC MIGRATION 20260825154800_remove_kommo_guard_drift.sql
