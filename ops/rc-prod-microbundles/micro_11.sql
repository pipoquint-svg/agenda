
-- BEGIN RC MIGRATION 20260825213200_catalog_runtime_compatibility.sql
-- Restore runtime compatibility after the catalog administration expansion.
-- New admin writes still require classified categories, but historical/direct fixtures may
-- legitimately reference an unclassified category while the service itself is classified.

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;

  -- Unclassified categories are legacy-compatible. The audited admin catalog RPCs reject
  -- them for new writes, so this exception does not weaken the managed admin surface.
  if v_category_scope is null then
    return new;
  end if;

  if new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;

  return new;
end;
$$;

-- 20260825213000 intentionally extended the base pricing calculation with simple
-- per-extra-person pricing. It replaced calculate_booking_quote(), which at this point in
-- the migration chain is already the schedule-aware wrapper introduced in
-- 20260821191000. Keep that enhanced calculation as the catalog base and restore the
-- schedule-aware public contract on top of it.
alter function public.calculate_booking_quote(uuid, uuid, jsonb, integer, timestamptz, text)
  rename to calculate_booking_quote_catalog_base;

create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_quote jsonb;
  v_profile jsonb;
  v_core_duration integer;
  v_pre integer;
  v_post integer;
  v_schedule_version text;
  v_pricing_version text;
begin
  v_quote := public.calculate_booking_quote_catalog_base(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at,
    p_coupon_code
  );

  select base_duration_minutes into v_core_duration
  from public.services
  where id = p_service_id;

  v_profile := public.resolve_extra_schedule_profile(
    p_service_id,
    p_extra_selections,
    p_requested_start_at
  );

  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);
  v_schedule_version := coalesce(v_profile->>'schedule_version', '');
  v_pricing_version := md5(coalesce(v_quote->>'pricing_version', '') || '|' || v_schedule_version);

  return v_quote || jsonb_build_object(
    'core_duration_minutes', v_core_duration,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_core_duration + v_pre + v_post,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

-- Creating a new function after renaming the protected core quote restores PostgreSQL's
-- default PUBLIC EXECUTE grant. Re-apply the public-booking boundary explicitly: browser
-- roles may quote only through the page-scoped wrappers, while service_role retains the
-- internal core capability.
revoke all on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  to service_role;

-- The renamed implementation is an internal helper too; do not expose it accidentally.
revoke all on function public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)
  to service_role;
-- END RC MIGRATION 20260825213200_catalog_runtime_compatibility.sql

-- BEGIN RC MIGRATION 20260825220000_coupon_admin_limits.sql
-- Administrative coupon management and transactional per-customer usage limit.

alter table public.coupons
  add column if not exists max_uses_per_customer integer;

alter table public.coupons drop constraint if exists coupons_max_uses_per_customer_check;
alter table public.coupons add constraint coupons_max_uses_per_customer_check
  check (max_uses_per_customer is null or max_uses_per_customer > 0);

create index if not exists appointment_discounts_coupon_idx
  on public.appointment_discounts(coupon_id)
  where coupon_id is not null;

create or replace function public.enforce_coupon_customer_usage_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_limit integer;
  v_customer_id uuid;
  v_used integer;
begin
  if new.coupon_id is null then return new; end if;
  select c.max_uses_per_customer into v_limit from public.coupons c where c.id = new.coupon_id for update;
  if v_limit is null then return new; end if;
  select a.primary_customer_id into v_customer_id from public.appointments a where a.id = new.appointment_id;
  if v_customer_id is null then raise exception using errcode='P0001', message='COUPON_CUSTOMER_REQUIRED'; end if;
  select count(*)::integer into v_used from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=new.coupon_id and a.primary_customer_id=v_customer_id;
  if v_used >= v_limit then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  return new;
end;
$$;

drop trigger if exists appointment_discounts_coupon_customer_limit on public.appointment_discounts;
create trigger appointment_discounts_coupon_customer_limit before insert on public.appointment_discounts for each row execute function public.enforce_coupon_customer_usage_limit();

create or replace function public.admin_list_coupons()
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object(
'id',c.id,'code',c.code,'discount_type',c.discount_type,'discount_value',c.discount_value,'valid_from',c.valid_from,'valid_until',c.valid_until,'is_active',c.is_active,'source',c.source,'customer_id',c.customer_id,'customer_name',customer.name,'source_appointment_id',c.source_appointment_id,'max_uses',c.max_uses,'max_uses_per_customer',c.max_uses_per_customer,'used_count',c.used_count,
'actual_used_count',(select count(*) from public.appointment_discounts ad where ad.coupon_id=c.id),
'status',case when not c.is_active then 'INACTIVE' when c.valid_from is not null and now()<c.valid_from then 'SCHEDULED' when c.valid_until is not null and now()>c.valid_until then 'EXPIRED' when c.max_uses is not null and c.used_count>=c.max_uses then 'EXHAUSTED' else 'ACTIVE' end,
'service_ids',coalesce((select jsonb_agg(cs.service_id order by cs.service_id) from public.coupon_services cs where cs.coupon_id=c.id),'[]'::jsonb)
) order by c.created_at desc,c.code),'[]'::jsonb)
from public.coupons c left join public.customers customer on customer.id=c.customer_id;
$$;

create or replace function public.admin_coupon_metrics()
returns jsonb language sql stable security definer set search_path=public as $$
with usage as (
  select c.id,c.code,count(ad.appointment_id)::integer as uses,coalesce(sum(ad.calculated_discount_amount),0)::numeric(12,2) as discount_total
  from public.coupons c left join public.appointment_discounts ad on ad.coupon_id=c.id group by c.id,c.code
), ranked as (select * from usage order by uses desc,code asc)
select jsonb_build_object(
  'total_uses',(select coalesce(sum(uses),0) from usage),
  'coupons_used',(select count(*) from usage where uses>0),
  'active_coupons',(select count(*) from public.coupons where is_active and (valid_from is null or valid_from<=now()) and (valid_until is null or valid_until>=now()) and (max_uses is null or used_count<max_uses)),
  'most_used',(select to_jsonb(r) from ranked r where uses>0 limit 1),
  'ranking',coalesce((select jsonb_agg(to_jsonb(r)) from (select * from ranked where uses>0 limit 20) r),'[]'::jsonb)
);
$$;

create or replace function public.admin_coupon_usage(p_coupon_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object('appointment_id',a.id,'public_code',a.public_code,'start_at',a.start_at,'customer_id',a.primary_customer_id,'customer_name',c.name,'customer_email',c.email,'discount_amount',ad.calculated_discount_amount,'final_value',a.commercial_value) order by a.created_at desc),'[]'::jsonb)
from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id left join public.customers c on c.id=a.primary_customer_id where ad.coupon_id=p_coupon_id;
$$;

create or replace function public.admin_create_coupon_audited(p_code text,p_discount_type text,p_discount_value numeric,p_valid_from timestamptz,p_valid_until timestamptz,p_max_uses integer,p_max_uses_per_customer integer,p_customer_id uuid,p_service_ids uuid[],p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid; v_code text:=upper(btrim(coalesce(p_code,''))); v_type text:=upper(btrim(coalesce(p_discount_type,'')));
begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,39}$' then raise exception using errcode='P0001',message='COUPON_CODE_INVALID'; end if;
 if v_type not in ('FIXED','PERCENT') then raise exception using errcode='P0001',message='COUPON_DISCOUNT_TYPE_INVALID'; end if;
 if coalesce(p_discount_value,0)<=0 or (v_type='PERCENT' and p_discount_value>100) then raise exception using errcode='P0001',message='COUPON_DISCOUNT_VALUE_INVALID'; end if;
 if p_valid_from is not null and p_valid_until is not null and p_valid_until<p_valid_from then raise exception using errcode='P0001',message='COUPON_VALIDITY_INVALID'; end if;
 if p_max_uses is not null and p_max_uses<=0 then raise exception using errcode='P0001',message='COUPON_MAX_USES_INVALID'; end if;
 if p_max_uses_per_customer is not null and p_max_uses_per_customer<=0 then raise exception using errcode='P0001',message='COUPON_CUSTOMER_LIMIT_INVALID'; end if;
 if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id) then raise exception using errcode='P0001',message='COUPON_CUSTOMER_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id) where not exists(select 1 from public.services s where s.id=x.id)) then raise exception using errcode='P0001',message='COUPON_SERVICE_NOT_FOUND'; end if;
 insert into public.coupons(code,discount_type,discount_value,valid_from,valid_until,is_active,source,customer_id,max_uses,max_uses_per_customer,used_count) values(v_code,v_type,p_discount_value,p_valid_from,p_valid_until,true,'PROMOTION',p_customer_id,p_max_uses,p_max_uses_per_customer,0) returning id into v_id;
 insert into public.coupon_services(coupon_id,service_id) select v_id,x.id from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id);
 insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',v_id,'COUPON_CREATED',null,(select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=v_id::text limit 1),'ADMIN');
 return (select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=v_id::text limit 1);
end;$$;

create or replace function public.admin_update_coupon_audited(p_coupon_id uuid,p_code text,p_discount_type text,p_discount_value numeric,p_valid_from timestamptz,p_valid_until timestamptz,p_max_uses integer,p_max_uses_per_customer integer,p_customer_id uuid,p_service_ids uuid[],p_is_active boolean,p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb;v_after jsonb;v_used integer;v_code text:=upper(btrim(coalesce(p_code,'')));v_type text:=upper(btrim(coalesce(p_discount_type,'')));
begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 select item into v_before from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1; if v_before is null then raise exception using errcode='P0001',message='COUPON_NOT_FOUND'; end if;
 select used_count into v_used from public.coupons where id=p_coupon_id for update;
 if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,39}$' then raise exception using errcode='P0001',message='COUPON_CODE_INVALID'; end if;
 if v_type not in ('FIXED','PERCENT') or coalesce(p_discount_value,0)<=0 or (v_type='PERCENT' and p_discount_value>100) then raise exception using errcode='P0001',message='COUPON_DISCOUNT_VALUE_INVALID'; end if;
 if p_valid_from is not null and p_valid_until is not null and p_valid_until<p_valid_from then raise exception using errcode='P0001',message='COUPON_VALIDITY_INVALID'; end if;
 if p_max_uses is not null and p_max_uses<greatest(v_used,1) then raise exception using errcode='P0001',message='COUPON_MAX_USES_BELOW_USAGE'; end if;
 if p_max_uses_per_customer is not null and p_max_uses_per_customer<=0 then raise exception using errcode='P0001',message='COUPON_CUSTOMER_LIMIT_INVALID'; end if;
 update public.coupons set code=v_code,discount_type=v_type,discount_value=p_discount_value,valid_from=p_valid_from,valid_until=p_valid_until,max_uses=p_max_uses,max_uses_per_customer=p_max_uses_per_customer,customer_id=p_customer_id,is_active=coalesce(p_is_active,true),updated_at=now() where id=p_coupon_id;
 delete from public.coupon_services where coupon_id=p_coupon_id; insert into public.coupon_services(coupon_id,service_id) select p_coupon_id,x.id from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id);
 select item into v_after from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1;
 if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_UPDATED',v_before,v_after,'ADMIN'); end if; return v_after;
end;$$;

create or replace function public.admin_remove_coupon_audited(p_coupon_id uuid,p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb;v_used boolean;begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 select item into v_before from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1;if v_before is null then raise exception using errcode='P0001',message='COUPON_NOT_FOUND';end if;
 perform 1 from public.coupons where id=p_coupon_id for update;select exists(select 1 from public.appointment_discounts where coupon_id=p_coupon_id) into v_used;
 if v_used then update public.coupons set is_active=false,updated_at=now() where id=p_coupon_id;insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_ARCHIVED',v_before,(select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1),'ADMIN');return jsonb_build_object('coupon_id',p_coupon_id,'removed',false,'archived',true);end if;
 delete from public.coupons where id=p_coupon_id;insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_DELETED',v_before,null,'ADMIN');return jsonb_build_object('coupon_id',p_coupon_id,'removed',true,'archived',false);
end;$$;

revoke all on function public.admin_list_coupons() from public,anon,authenticated;
revoke all on function public.admin_coupon_metrics() from public,anon,authenticated;
revoke all on function public.admin_coupon_usage(uuid) from public,anon,authenticated;
revoke all on function public.admin_create_coupon_audited(text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],uuid) from public,anon,authenticated;
revoke all on function public.admin_update_coupon_audited(uuid,text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],boolean,uuid) from public,anon,authenticated;
revoke all on function public.admin_remove_coupon_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_list_coupons(),public.admin_coupon_metrics(),public.admin_coupon_usage(uuid),public.admin_create_coupon_audited(text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],uuid),public.admin_update_coupon_audited(uuid,text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],boolean,uuid),public.admin_remove_coupon_audited(uuid,uuid) to service_role;
-- END RC MIGRATION 20260825220000_coupon_admin_limits.sql

-- BEGIN RC MIGRATION 20260825221000_checkout_coupon_confirmation.sql
-- Coupon selection belongs to the reservation confirmation step, before customer identity and payment.
-- The browser never writes money: these RPCs recalculate the authoritative quote and persist a coupon snapshot on the hold.

alter table public.checkout_holds add column if not exists applied_coupon_id uuid references public.coupons(id) on delete restrict;
alter table public.checkout_holds add column if not exists coupon_code_snapshot text;
alter table public.checkout_holds add column if not exists coupon_discount numeric(12,2) not null default 0 check (coupon_discount >= 0);
alter table public.checkout_holds add column if not exists pre_discount_value numeric(12,2) check (pre_discount_value is null or pre_discount_value >= 0);
create index if not exists checkout_holds_applied_coupon_idx on public.checkout_holds(applied_coupon_id) where applied_coupon_id is not null;

create or replace function public.checkout_hold_quote_with_coupon(p_hold public.checkout_holds,p_coupon_code text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if p_hold.duration_blocks is not null then
    return public.calculate_booking_quote_for_duration(p_hold.service_id,p_hold.service_employee_id,p_hold.duration_blocks,p_hold.extra_selections,p_hold.people_count,p_hold.core_start_at,p_coupon_code);
  end if;
  return public.calculate_booking_quote(p_hold.service_id,p_hold.service_employee_id,p_hold.extra_selections,p_hold.people_count,p_hold.core_start_at,p_coupon_code);
end;$$;

create or replace function public.apply_checkout_coupon(p_checkout_hold_token text,p_coupon_code text)
returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;v_coupon public.coupons%rowtype;v_quote jsonb;v_code text:=upper(btrim(coalesce(p_coupon_code,'')));v_subtotal numeric;v_discount numeric;v_total numeric;
begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 if v_code='' then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');
 select * into v_hold from public.checkout_holds where public_token_hash=v_hash for update;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;
 if v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='HOLD_EXPIRED';end if;
 if exists(select 1 from public.checkout_hour_package_reservations ph where ph.checkout_hold_id=v_hold.id and ph.status='HELD') then raise exception using errcode='P0001',message='COUPON_PACKAGE_POLICY_REQUIRES_DECISION';end if;
 select * into v_coupon from public.coupons c where upper(c.code)=v_code for update;
 if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now()<v_coupon.valid_from) or (v_coupon.valid_until is not null and now()>v_coupon.valid_until) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 if v_coupon.max_uses is not null and v_coupon.used_count>=v_coupon.max_uses then raise exception using errcode='P0001',message='COUPON_USAGE_LIMIT_REACHED';end if;
 if exists(select 1 from public.coupon_services cs where cs.coupon_id=v_coupon.id) and not exists(select 1 from public.coupon_services cs where cs.coupon_id=v_coupon.id and cs.service_id=v_hold.service_id) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 v_quote:=public.checkout_hold_quote_with_coupon(v_hold,v_code);
 v_discount:=coalesce((v_quote->>'coupon_discount')::numeric,0);v_total:=(v_quote->>'commercial_value')::numeric;v_subtotal:=v_total+v_discount;
 update public.checkout_holds set applied_coupon_id=v_coupon.id,coupon_code_snapshot=v_coupon.code,coupon_discount=v_discount,pre_discount_value=v_subtotal,commercial_value=v_total,pricing_version=v_quote->>'pricing_version',quote_snapshot=v_quote,updated_at=now() where id=v_hold.id;
 return jsonb_build_object('coupon_code',v_coupon.code,'subtotal',v_subtotal,'coupon_discount',v_discount,'commercial_value',v_total,'customer_validation_pending',v_coupon.customer_id is not null or v_coupon.max_uses_per_customer is not null);
end;$$;

create or replace function public.clear_checkout_coupon(p_checkout_hold_token text)
returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;v_quote jsonb;v_total numeric;
begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select * into v_hold from public.checkout_holds where public_token_hash=v_hash for update;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;if v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='HOLD_EXPIRED';end if;
 v_quote:=public.checkout_hold_quote_with_coupon(v_hold,null);v_total:=(v_quote->>'commercial_value')::numeric;
 update public.checkout_holds set applied_coupon_id=null,coupon_code_snapshot=null,coupon_discount=0,pre_discount_value=null,commercial_value=v_total,pricing_version=v_quote->>'pricing_version',quote_snapshot=v_quote,updated_at=now() where id=v_hold.id;
 return jsonb_build_object('coupon_code',null,'subtotal',v_total,'coupon_discount',0,'commercial_value',v_total,'customer_validation_pending',false);
end;$$;

create or replace function public.get_checkout_coupon_state(p_checkout_hold_token text)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select * into v_hold from public.checkout_holds where public_token_hash=v_hash;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;
 return jsonb_build_object('coupon_code',v_hold.coupon_code_snapshot,'subtotal',coalesce(v_hold.pre_discount_value,v_hold.commercial_value+v_hold.coupon_discount),'coupon_discount',v_hold.coupon_discount,'commercial_value',v_hold.commercial_value);
end;$$;

create or replace function public.enforce_checkout_coupon_customer()
returns trigger language plpgsql set search_path=public as $$
declare v_coupon public.coupons%rowtype;v_used integer;
begin
 if new.applied_coupon_id is null or new.primary_customer_id is null then return new;end if;
 select * into v_coupon from public.coupons where id=new.applied_coupon_id for update;
 if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now()<v_coupon.valid_from) or (v_coupon.valid_until is not null and now()>v_coupon.valid_until) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 if v_coupon.customer_id is not null and v_coupon.customer_id<>new.primary_customer_id then raise exception using errcode='P0001',message='COUPON_CUSTOMER_MISMATCH';end if;
 if v_coupon.max_uses is not null and v_coupon.used_count>=v_coupon.max_uses then raise exception using errcode='P0001',message='COUPON_USAGE_LIMIT_REACHED';end if;
 if v_coupon.max_uses_per_customer is not null then select count(*)::integer into v_used from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=v_coupon.id and a.primary_customer_id=new.primary_customer_id;if v_used>=v_coupon.max_uses_per_customer then raise exception using errcode='P0001',message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED';end if;end if;
 return new;
end;$$;
drop trigger if exists checkout_holds_coupon_customer_guard on public.checkout_holds;
create trigger checkout_holds_coupon_customer_guard before update of primary_customer_id,applied_coupon_id on public.checkout_holds for each row when (new.applied_coupon_id is not null and new.primary_customer_id is not null) execute function public.enforce_checkout_coupon_customer();

create or replace function public.get_checkout_applied_coupon_code(p_checkout_hold_token text)
returns text language plpgsql stable security definer set search_path=public,extensions as $$ declare v_hash text;v_code text;begin v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select coupon_code_snapshot into v_code from public.checkout_holds where public_token_hash=v_hash and status='ACTIVE' and expires_at>now();return v_code;end;$$;

revoke all on function public.checkout_hold_quote_with_coupon(public.checkout_holds,text),public.apply_checkout_coupon(text,text),public.clear_checkout_coupon(text),public.get_checkout_coupon_state(text),public.get_checkout_applied_coupon_code(text) from public,anon,authenticated;
grant execute on function public.checkout_hold_quote_with_coupon(public.checkout_holds,text),public.apply_checkout_coupon(text,text),public.clear_checkout_coupon(text),public.get_checkout_coupon_state(text),public.get_checkout_applied_coupon_code(text) to service_role;
-- END RC MIGRATION 20260825221000_checkout_coupon_confirmation.sql

-- BEGIN RC MIGRATION 20260825221100_admin_appointment_coupon_detail.sql
-- Preserve the existing appointment detail contract and add the coupon snapshot used by this reservation.
-- Coupon information lives inside the existing `financial` envelope so admin-agenda's FINANCE_VIEW
-- redaction removes the entire object for operators without financial access.

alter function public.service_admin_get_appointment(uuid)
  rename to service_admin_get_appointment_base;

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
with base as (
  select public.service_admin_get_appointment_base(p_appointment_id) as payload
), coupon_snapshot as (
  select jsonb_build_object(
    'coupon_id', ad.coupon_id,
    'code', ad.code_snapshot,
    'discount_type', ad.discount_type_snapshot,
    'discount_value', ad.discount_value_snapshot,
    'discount_amount', ad.calculated_discount_amount,
    'final_value', a.commercial_value
  ) as coupon
  from public.appointment_discounts ad
  join public.appointments a on a.id=ad.appointment_id
  where ad.appointment_id=p_appointment_id
  order by ad.created_at
  limit 1
)
select base.payload || jsonb_build_object(
  'financial', coalesce(base.payload->'financial','{}'::jsonb)
    || jsonb_build_object('coupon',(select coupon from coupon_snapshot))
)
from base;
$$;

revoke all on function public.service_admin_get_appointment_base(uuid) from public,anon,authenticated;
revoke all on function public.service_admin_get_appointment(uuid) from public,anon,authenticated;
grant execute on function public.service_admin_get_appointment_base(uuid) to service_role;
grant execute on function public.service_admin_get_appointment(uuid) to service_role;
-- END RC MIGRATION 20260825221100_admin_appointment_coupon_detail.sql

-- BEGIN RC MIGRATION 20260825223000_employee_admin.sql
-- Unified employee administration for service assignments, recurring work hours and exceptions.

alter table public.employees add column if not exists notes text;

create or replace function public.admin_list_employees()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', e.id,
  'name', e.name,
  'email', e.email,
  'phone', e.phone,
  'notes', e.notes,
  'is_active', e.is_active,
  'resource_id', e.resource_id,
  'service_assignments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'service_employee_id', se.id,
      'service_id', se.service_id,
      'service_name', s.name,
      'operation_scope', s.operation_scope,
      'category_id', s.category_id,
      'is_active', se.is_active,
      'work_hours', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ar.id, 'weekday', ar.weekday, 'start_local_time', ar.start_local_time,
          'end_local_time', ar.end_local_time, 'slot_interval_minutes', ar.slot_interval_minutes,
          'is_active', ar.is_active
        ) order by ar.weekday, ar.start_local_time, ar.id)
        from public.availability_rules ar where ar.service_employee_id=se.id
      ), '[]'::jsonb),
      'exceptions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ax.id, 'exception_type', ax.exception_type, 'start_at', ax.start_at,
          'end_at', ax.end_at, 'reason', ax.reason, 'created_at', ax.created_at
        ) order by ax.start_at, ax.id)
        from public.availability_exceptions ax where ax.service_employee_id=se.id and ax.end_at >= now() - interval '30 days'
      ), '[]'::jsonb),
      'write_calendar', (
        select jsonb_build_object(
          'google_calendar_id', secw.google_calendar_id,
          'calendar_name', gc.name,
          'time_scope', secw.time_scope
        )
        from public.service_employee_calendar_write secw
        join public.google_calendars gc on gc.id=secw.google_calendar_id
        where secw.service_employee_id=se.id
      )
    ) order by s.operation_scope, s.name, se.id)
    from public.service_employees se join public.services s on s.id=se.service_id
    where se.employee_id=e.id
  ), '[]'::jsonb)
) order by e.name,e.id),'[]'::jsonb)
from public.employees e;
$$;

create or replace function public.admin_create_employee_audited(
  p_name text,p_email text,p_phone text,p_notes text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  insert into public.employees(name,email,phone,notes,is_active)
  values(btrim(p_name),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_notes),''),true)
  returning id into v_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=v_id::text limit 1;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EMPLOYEE',v_id,'EMPLOYEE_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_update_employee_audited(
  p_employee_id uuid,p_name text,p_email text,p_phone text,p_notes text,p_is_active boolean,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is null then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  update public.employees set name=btrim(p_name),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),notes=nullif(btrim(p_notes),''),is_active=coalesce(p_is_active,true),updated_at=now() where id=p_employee_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_employee_services_audited(
  p_employee_id uuid,p_service_ids uuid[],p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_service_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.employees where id=p_employee_id) then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if exists(select 1 from unnest(coalesce(p_service_ids,'{}'::uuid[])) sid where not exists(select 1 from public.services s where s.id=sid and s.is_active)) then raise exception using errcode='P0001',message='EMPLOYEE_SERVICE_NOT_AVAILABLE'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  update public.service_employees set is_active=false where employee_id=p_employee_id and not (service_id=any(coalesce(p_service_ids,'{}'::uuid[])));
  foreach v_service_id in array coalesce(p_service_ids,'{}'::uuid[]) loop
    insert into public.service_employees(service_id,employee_id,is_active)
    values(v_service_id,p_employee_id,true)
    on conflict(service_id,employee_id) do update set is_active=true;
  end loop;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_SERVICES_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_work_hours_audited(
  p_service_employee_id uuid,p_rules jsonb,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_rule jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_rules,'[]'::jsonb))<>'array' then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_before from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  delete from public.availability_rules where service_employee_id=p_service_employee_id;
  for v_rule in select value from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) loop
    if (v_rule->>'weekday')::integer not between 0 and 6 or (v_rule->>'end_local_time')::time <= (v_rule->>'start_local_time')::time then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
    insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
    values(p_service_employee_id,(v_rule->>'weekday')::smallint,(v_rule->>'start_local_time')::time,(v_rule->>'end_local_time')::time,coalesce((v_rule->>'slot_interval_minutes')::integer,30),coalesce((v_rule->>'is_active')::boolean,true));
  end loop;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_after from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'WORK_HOURS_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_add_employee_exception_audited(
  p_service_employee_id uuid,p_exception_type text,p_start_at timestamptz,p_end_at timestamptz,p_reason text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_type text:=upper(btrim(coalesce(p_exception_type,''))); v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_type not in ('BLOCK','OPEN') then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_TYPE_INVALID'; end if;
  if p_end_at<=p_start_at then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_RANGE_INVALID'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  insert into public.availability_exceptions(service_employee_id,exception_type,start_at,end_at,reason,created_by)
  values(p_service_employee_id,v_type,p_start_at,p_end_at,nullif(btrim(p_reason),''),p_admin_id) returning id into v_id;
  select to_jsonb(ax) into v_after from public.availability_exceptions ax where ax.id=v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',v_id,'AVAILABILITY_EXCEPTION_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_remove_employee_exception_audited(p_exception_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select to_jsonb(ax) into v_before from public.availability_exceptions ax where ax.id=p_exception_id for update;
  if v_before is null then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_NOT_FOUND'; end if;
  delete from public.availability_exceptions where id=p_exception_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',p_exception_id,'AVAILABILITY_EXCEPTION_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('exception_id',p_exception_id,'removed',true);
end;
$$;

revoke all on function public.admin_list_employees() from public,anon,authenticated;
revoke all on function public.admin_create_employee_audited(text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_remove_employee_exception_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_list_employees() to service_role;
grant execute on function public.admin_create_employee_audited(text,text,text,text,uuid) to service_role;
grant execute on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) to service_role;
grant execute on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) to service_role;
grant execute on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) to service_role;
grant execute on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) to service_role;
grant execute on function public.admin_remove_employee_exception_audited(uuid,uuid) to service_role;
-- END RC MIGRATION 20260825223000_employee_admin.sql
