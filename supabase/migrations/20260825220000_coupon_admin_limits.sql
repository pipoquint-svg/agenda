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
