-- Manual hour-package recharges are independent commercial events.
-- They add immutable ledger credit and preserve the amount paid for each recharge.

create table if not exists public.hour_package_recharges (
  id uuid primary key default gen_random_uuid(),
  hour_package_id uuid not null references public.hour_packages(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  added_minutes integer not null check (added_minutes > 0),
  paid_amount numeric(12,2) not null check (paid_amount > 0),
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists hour_package_recharges_customer_idx
  on public.hour_package_recharges(customer_id, created_at desc);
create index if not exists hour_package_recharges_package_idx
  on public.hour_package_recharges(hour_package_id, created_at desc);

alter table public.hour_package_recharges enable row level security;
revoke all on public.hour_package_recharges from anon, authenticated;
grant all on public.hour_package_recharges to service_role;

create or replace function public.service_admin_recharge_hour_package(
  p_customer_id uuid,
  p_added_minutes integer,
  p_paid_amount numeric,
  p_admin_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_package public.hour_packages%rowtype;
  v_service_id uuid;
  v_recharge_id uuid;
  v_balance record;
begin
  if p_customer_id is null or not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception using errcode='P0001', message='PACKAGE_CUSTOMER_NOT_FOUND';
  end if;
  if p_added_minutes is null or p_added_minutes <= 0 then
    raise exception using errcode='P0001', message='PACKAGE_RECHARGE_MINUTES_INVALID';
  end if;
  if p_paid_amount is null or p_paid_amount <= 0 then
    raise exception using errcode='P0001', message='PACKAGE_RECHARGE_AMOUNT_INVALID';
  end if;
  if p_admin_id is null or not exists (select 1 from public.admin_users where id=p_admin_id and is_active) then
    raise exception using errcode='P0001', message='ADMIN_USER_NOT_FOUND';
  end if;

  -- Serialize recharges per customer to avoid two concurrent wallet creations.
  perform pg_advisory_xact_lock(hashtextextended(p_customer_id::text, 0));

  select * into v_package
  from public.hour_packages
  where customer_id = p_customer_id
    and name = 'Saldo de horas BlackSheep'
    and status in ('ACTIVE','EXHAUSTED')
    and valid_until = 'infinity'::timestamptz
  order by created_at desc
  limit 1
  for update;

  if not found then
    insert into public.hour_packages(
      customer_id,
      name,
      total_minutes,
      purchased_value,
      valid_from,
      valid_until,
      status,
      special_surcharge_percent,
      standard_start_local_time,
      standard_end_local_time,
      notes,
      created_by_admin_id
    ) values (
      p_customer_id,
      'Saldo de horas BlackSheep',
      p_added_minutes,
      p_paid_amount,
      now(),
      'infinity'::timestamptz,
      'ACTIVE',
      0,
      time '00:00:00',
      time '23:59:59.999999',
      'Saldo administrativo de horas para locação do estúdio. Sem vencimento; disponibilidade continua limitada pelo local e funcionário.',
      p_admin_id
    ) returning * into v_package;

    select id into v_service_id
    from public.services
    where slug='locacao-estudio' and operation_scope='BLACKSHEEP' and is_active
    order by created_at
    limit 1;

    if v_service_id is null then
      raise exception using errcode='P0001', message='PACKAGE_RENTAL_SERVICE_NOT_FOUND';
    end if;

    insert into public.hour_package_services(hour_package_id, service_id)
    values (v_package.id, v_service_id)
    on conflict do nothing;
  else
    update public.hour_packages
    set total_minutes = total_minutes + p_added_minutes,
        purchased_value = purchased_value + p_paid_amount,
        status = 'ACTIVE',
        updated_at = now()
    where id = v_package.id
    returning * into v_package;

    insert into public.hour_package_movements(
      hour_package_id,
      appointment_id,
      movement_type,
      minutes_delta,
      seconds_delta,
      reason,
      created_by_admin_id
    ) values (
      v_package.id,
      null,
      'ADMIN_ADJUSTMENT',
      p_added_minutes,
      p_added_minutes::bigint * 60,
      'MANUAL_RECHARGE',
      p_admin_id
    );
  end if;

  insert into public.hour_package_recharges(
    hour_package_id, customer_id, added_minutes, paid_amount, created_by_admin_id, notes
  ) values (
    v_package.id, p_customer_id, p_added_minutes, p_paid_amount, p_admin_id, nullif(btrim(p_notes),'')
  ) returning id into v_recharge_id;

  select * into v_balance
  from public.hour_package_balances
  where hour_package_id = v_package.id;

  return jsonb_build_object(
    'recharge_id', v_recharge_id,
    'hour_package_id', v_package.id,
    'customer_id', p_customer_id,
    'added_minutes', p_added_minutes,
    'paid_amount', round(p_paid_amount,2),
    'available_seconds', coalesce(v_balance.available_seconds,0),
    'total_seconds', coalesce(v_balance.total_seconds,0),
    'purchased_value', v_package.purchased_value,
    'reference_minute_value', v_package.reference_minute_value,
    'status', v_package.status
  );
end;
$$;

revoke all on function public.service_admin_recharge_hour_package(uuid,integer,numeric,uuid,text) from public, anon, authenticated;
grant execute on function public.service_admin_recharge_hour_package(uuid,integer,numeric,uuid,text) to service_role;

comment on table public.hour_package_recharges is
  'Auditable manual purchase/recharge events for BlackSheep hour balances. Not appointment payment_transactions.';
