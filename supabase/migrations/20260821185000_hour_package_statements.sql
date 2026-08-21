create or replace function public.format_duration_seconds(p_seconds bigint)
returns text
language sql
immutable
parallel safe
as $$
  select case
    when p_seconds is null then null
    else
      case when p_seconds < 0 then '-' else '' end
      || lpad((abs(p_seconds) / 3600)::text, 2, '0')
      || ':'
      || lpad(((abs(p_seconds) % 3600) / 60)::text, 2, '0')
      || ':'
      || lpad((abs(p_seconds) % 60)::text, 2, '0')
  end;
$$;

comment on function public.format_duration_seconds(bigint) is
  'Formats an exact second count as signed HH:MM:SS, allowing hours above 24.';

create or replace view public.hour_package_statement_entries as
with movement_rows as (
  select
    m.id as movement_id,
    m.hour_package_id,
    p.customer_id,
    m.appointment_id,
    m.movement_type,
    m.seconds_delta,
    m.minutes_delta,
    m.reason,
    m.created_by_admin_id,
    m.created_at as registered_at,
    a.public_code as appointment_code,
    a.start_at as service_start_at,
    a.end_at as service_end_at,
    coalesce(a.service_name_snapshot, s.name) as service_name,
    apu.required_seconds as nominal_seconds,
    apu.surcharge_seconds,
    apu.charged_seconds as usage_charged_seconds,
    apu.is_special_period,
    apu.special_surcharge_percent,
    sum(m.seconds_delta) over (
      partition by m.hour_package_id
      order by m.created_at, m.id
      rows between unbounded preceding and current row
    )::bigint as balance_after_seconds
  from public.hour_package_movements m
  join public.hour_packages p on p.id = m.hour_package_id
  left join public.appointments a on a.id = m.appointment_id
  left join public.services s on s.id = a.service_id
  left join public.appointment_package_usage apu
    on apu.debit_movement_id = m.id
    or apu.reversal_movement_id = m.id
)
select
  movement_id,
  hour_package_id,
  customer_id,
  registered_at,
  movement_type,
  case movement_type
    when 'INITIAL_CREDIT' then 'Crédito inicial'
    when 'RESERVATION_DEBIT' then 'Uso em reserva'
    when 'CANCELLATION_REVERSAL' then 'Estorno por cancelamento'
    when 'DURATION_ADJUSTMENT' then 'Ajuste de duração'
    when 'ADMIN_ADJUSTMENT' then 'Ajuste administrativo'
    else movement_type
  end as movement_label,
  case when seconds_delta < 0 then 'DEBIT' else 'CREDIT' end as direction,
  appointment_id,
  appointment_code,
  service_name,
  service_start_at,
  service_end_at,
  nominal_seconds,
  public.format_duration_seconds(nominal_seconds) as nominal_time,
  coalesce(surcharge_seconds, 0)::bigint as surcharge_seconds,
  public.format_duration_seconds(coalesce(surcharge_seconds, 0)::bigint) as surcharge_time,
  coalesce(is_special_period, false) as is_special_period,
  coalesce(special_surcharge_percent, 0)::numeric as special_surcharge_percent,
  case when seconds_delta < 0 then abs(seconds_delta) else 0 end::bigint as debited_seconds,
  public.format_duration_seconds(case when seconds_delta < 0 then abs(seconds_delta) else 0 end::bigint) as debited_time,
  case when seconds_delta > 0 then seconds_delta else 0 end::bigint as credited_seconds,
  public.format_duration_seconds(case when seconds_delta > 0 then seconds_delta else 0 end::bigint) as credited_time,
  seconds_delta,
  public.format_duration_seconds(seconds_delta) as signed_movement_time,
  balance_after_seconds,
  public.format_duration_seconds(balance_after_seconds) as balance_after_time,
  reason,
  created_by_admin_id
from movement_rows;

comment on view public.hour_package_statement_entries is
  'Immutable package ledger projected as a printable/exportable statement with appointment context, exact seconds and running balance.';

create or replace function public.get_hour_package_statement(p_hour_package_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_package public.hour_packages%rowtype;
  v_customer public.customers%rowtype;
  v_balance public.hour_package_balances%rowtype;
  v_held_seconds bigint;
  v_entries jsonb;
begin
  select * into v_package
  from public.hour_packages
  where id = p_hour_package_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_FOUND';
  end if;

  select * into v_customer
  from public.customers
  where id = v_package.customer_id;

  select * into v_balance
  from public.hour_package_balances
  where hour_package_id = p_hour_package_id;

  select coalesce(sum(charged_seconds), 0)::bigint
  into v_held_seconds
  from public.checkout_hour_package_reservations
  where hour_package_id = p_hour_package_id
    and status = 'HELD';

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'movement_id', e.movement_id,
      'registered_at', e.registered_at,
      'movement_type', e.movement_type,
      'movement_label', e.movement_label,
      'direction', e.direction,
      'appointment_id', e.appointment_id,
      'appointment_code', e.appointment_code,
      'service_name', e.service_name,
      'service_start_at', e.service_start_at,
      'service_end_at', e.service_end_at,
      'nominal_seconds', e.nominal_seconds,
      'nominal_time', e.nominal_time,
      'surcharge_seconds', e.surcharge_seconds,
      'surcharge_time', e.surcharge_time,
      'is_special_period', e.is_special_period,
      'special_surcharge_percent', e.special_surcharge_percent,
      'debited_seconds', e.debited_seconds,
      'debited_time', e.debited_time,
      'credited_seconds', e.credited_seconds,
      'credited_time', e.credited_time,
      'seconds_delta', e.seconds_delta,
      'signed_movement_time', e.signed_movement_time,
      'balance_after_seconds', e.balance_after_seconds,
      'balance_after_time', e.balance_after_time,
      'reason', e.reason
    ) order by e.registered_at, e.movement_id
  ), '[]'::jsonb)
  into v_entries
  from public.hour_package_statement_entries e
  where e.hour_package_id = p_hour_package_id;

  return jsonb_build_object(
    'package', jsonb_build_object(
      'id', v_package.id,
      'name', v_package.name,
      'status', v_package.status,
      'valid_from', v_package.valid_from,
      'valid_until', v_package.valid_until,
      'purchased_value', v_package.purchased_value,
      'total_seconds', v_package.total_seconds,
      'total_time', public.format_duration_seconds(v_package.total_seconds)
    ),
    'customer', jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone,
      'cpf_cnpj', v_customer.cpf_cnpj
    ),
    'summary', jsonb_build_object(
      'ledger_balance_seconds', v_balance.ledger_seconds,
      'ledger_balance_time', public.format_duration_seconds(v_balance.ledger_seconds),
      'held_seconds', v_held_seconds,
      'held_time', public.format_duration_seconds(v_held_seconds),
      'available_seconds', v_balance.available_seconds,
      'available_time', public.format_duration_seconds(v_balance.available_seconds),
      'generated_at', now()
    ),
    'entries', v_entries
  );
end;
$$;

comment on function public.get_hour_package_statement(uuid) is
  'Returns the canonical package statement payload for admin/client display, CSV/XLSX export and print/PDF rendering.';