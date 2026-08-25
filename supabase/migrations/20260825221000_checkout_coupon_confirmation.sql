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
