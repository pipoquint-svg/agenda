-- Issue #217 / V1.5 #257 — deterministic birthday cycle runtime.
-- This migration creates internal data effects only. It does not create a scheduler and does not call an external provider.

-- Birthday coupons must be distinguishable from manual/promotional coupons.
alter table public.coupons drop constraint if exists coupons_source_check;
alter table public.coupons add constraint coupons_source_check
  check (source in ('PROMOTION', 'BIRTHDAY'));

create or replace function public.run_birthday_automation(
  p_run_date date default ((now() at time zone 'America/Sao_Paulo')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_setting public.birthday_automation_settings%rowtype;
  v_customer record;
  v_trigger_kind text;
  v_birthday_date date;
  v_trigger_date date;
  v_cycle_id uuid;
  v_coupon_id uuid;
  v_coupon_code text;
  v_template_id uuid;
  v_recipient_hash text;
  v_created_cycles integer := 0;
  v_created_coupons integer := 0;
  v_queued_messages integer := 0;
  v_skipped_existing integer := 0;
  v_service_count integer;
  v_year integer;
  v_is_leap boolean;
  v_feb28 date;
  v_mar01 date;
begin
  if p_run_date is null then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_RUN_DATE_REQUIRED';
  end if;

  v_year := extract(year from p_run_date)::integer;
  v_is_leap := (v_year % 400 = 0) or (v_year % 4 = 0 and v_year % 100 <> 0);

  for v_setting in
    select *
    from public.birthday_automation_settings
    where is_active
    order by operation_scope
  loop
    for v_customer in
      select distinct c.id, c.name, c.email, c.birth_date
      from public.customers c
      where c.birth_date is not null
        and exists (
          select 1
          from public.appointments a
          join public.services s on s.id = a.service_id
          where a.primary_customer_id = c.id
            and s.operation_scope = v_setting.operation_scope
        )
      order by c.id
    loop
      -- Feb 29 in a non-leap year has two plausible business interpretations (Feb 28 or Mar 1).
      -- Do not choose one. Only fail on dates where either interpretation could trigger; unrelated days keep running.
      if extract(month from v_customer.birth_date)::integer = 2
         and extract(day from v_customer.birth_date)::integer = 29
         and not v_is_leap then
        v_feb28 := make_date(v_year, 2, 28);
        v_mar01 := make_date(v_year, 3, 1);
        if (v_setting.send_on_birthday and p_run_date in (v_feb28, v_mar01))
           or (v_setting.days_before is not null and v_setting.days_before > 0
               and p_run_date in (v_feb28 - v_setting.days_before, v_mar01 - v_setting.days_before)) then
          raise exception using errcode = 'P0001', message = 'BIRTHDAY_LEAP_DAY_POLICY_REQUIRED';
        end if;
        continue;
      end if;

      v_birthday_date := make_date(
        v_year,
        extract(month from v_customer.birth_date)::integer,
        extract(day from v_customer.birth_date)::integer
      );

      for v_trigger_kind in
        select trigger_kind
        from (
          values
            ('BIRTHDAY'::text, v_setting.send_on_birthday),
            ('BEFORE'::text, v_setting.days_before is not null and v_setting.days_before > 0)
        ) q(trigger_kind, enabled)
        where enabled
      loop
        v_trigger_date := case
          when v_trigger_kind = 'BEFORE' then v_birthday_date - v_setting.days_before
          else v_birthday_date
        end;

        -- No retroactive catch-up: a cycle is eligible only on its exact configured date.
        if v_trigger_date <> p_run_date then
          continue;
        end if;

        v_cycle_id := null;
        insert into public.birthday_automation_cycles(
          operation_scope, customer_id, birthday_year, trigger_kind, target_date, message_status
        ) values (
          v_setting.operation_scope,
          v_customer.id,
          extract(year from v_birthday_date)::integer,
          v_trigger_kind,
          v_trigger_date,
          case when v_setting.send_message then 'PENDING' else null end
        )
        on conflict (operation_scope, customer_id, birthday_year, trigger_kind) do nothing
        returning id into v_cycle_id;

        if v_cycle_id is null then
          v_skipped_existing := v_skipped_existing + 1;
          continue;
        end if;

        v_created_cycles := v_created_cycles + 1;

        if v_setting.generate_coupon then
          select count(*) into v_service_count
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope;

          if v_service_count = 0 then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_COUPON_OPERATION_HAS_NO_ACTIVE_SERVICES';
          end if;

          v_coupon_code := upper(left(v_setting.coupon_prefix, 16))
            || '-' || extract(year from v_birthday_date)::integer::text
            || '-' || case when v_trigger_kind = 'BEFORE' then 'P' else 'D' end
            || '-' || upper(left(replace(v_customer.id::text, '-', ''), 8));

          insert into public.coupons(
            code, discount_type, discount_value, valid_from, valid_until, is_active,
            source, customer_id, max_uses, max_uses_per_customer, used_count
          ) values (
            v_coupon_code,
            v_setting.coupon_discount_type,
            v_setting.coupon_discount_value,
            (p_run_date::timestamp at time zone 'America/Sao_Paulo'),
            ((p_run_date + v_setting.coupon_validity_days)::timestamp at time zone 'America/Sao_Paulo'),
            true,
            'BIRTHDAY',
            v_customer.id,
            v_setting.coupon_max_uses,
            v_setting.coupon_max_uses_per_customer,
            0
          )
          returning id into v_coupon_id;

          insert into public.coupon_services(coupon_id, service_id)
          select v_coupon_id, s.id
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope
          on conflict do nothing;

          update public.birthday_automation_cycles
          set coupon_id = v_coupon_id, updated_at = now()
          where id = v_cycle_id;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_COUPON_CREATED', null,
            jsonb_build_object(
              'coupon_id', v_coupon_id,
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'birthday_year', extract(year from v_birthday_date)::integer,
              'trigger_kind', v_trigger_kind
            ),
            'SYSTEM'
          );

          v_created_coupons := v_created_coupons + 1;
        else
          v_coupon_id := null;
        end if;

        if v_setting.send_message then
          select t.id into v_template_id
          from public.notification_template_configs t
          where t.is_active
            and t.event_key = 'BIRTHDAY'
            and t.channel = 'EMAIL'
            and t.audience = 'CUSTOMER'
            and t.category_id is null
            and not exists (
              select 1 from public.notification_template_services nts where nts.template_id = t.id
            )
            and (t.operation_scope = v_setting.operation_scope or t.operation_scope is null)
          order by case when t.operation_scope = v_setting.operation_scope then 2 else 1 end desc,
                   t.updated_at desc,
                   t.id
          limit 1;

          if v_template_id is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_EMAIL_TEMPLATE_REQUIRED';
          end if;

          v_recipient_hash := case
            when nullif(lower(btrim(v_customer.email)), '') is null then null
            else encode(extensions.digest(lower(btrim(v_customer.email)), 'sha256'), 'hex')
          end;

          if v_recipient_hash is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_CUSTOMER_EMAIL_REQUIRED';
          end if;

          insert into public.notification_delivery_logs(
            template_id, event_key, channel, audience, customer_id, recipient_hash,
            status, idempotency_key, payload_snapshot
          ) values (
            v_template_id,
            'BIRTHDAY',
            'EMAIL',
            'CUSTOMER',
            v_customer.id,
            v_recipient_hash,
            'PENDING',
            'birthday:' || v_setting.operation_scope || ':' || v_customer.id::text || ':'
              || extract(year from v_birthday_date)::integer::text || ':' || v_trigger_kind,
            jsonb_build_object(
              'birthday_cycle_id', v_cycle_id,
              'operation_scope', v_setting.operation_scope,
              'trigger_kind', v_trigger_kind,
              'coupon_id', v_coupon_id
            )
          )
          on conflict (idempotency_key) do nothing;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_MESSAGE_QUEUED', null,
            jsonb_build_object(
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'template_id', v_template_id,
              'trigger_kind', v_trigger_kind
            ),
            'SYSTEM'
          );

          v_queued_messages := v_queued_messages + 1;
        end if;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object(
    'run_date', p_run_date,
    'created_cycles', v_created_cycles,
    'created_coupons', v_created_coupons,
    'queued_messages', v_queued_messages,
    'skipped_existing', v_skipped_existing
  );
end;
$$;

revoke all on function public.run_birthday_automation(date) from public, anon, authenticated;
grant execute on function public.run_birthday_automation(date) to service_role;

comment on function public.run_birthday_automation(date) is
  'Internal idempotent birthday-cycle runtime. Exact-date only; creates BIRTHDAY coupons and pending notification evidence. Does not call providers or schedule itself.';
