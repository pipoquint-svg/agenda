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
