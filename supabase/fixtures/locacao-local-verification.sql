-- Item 1: disposable rental verification fixture.
-- Loaded only after `supabase db reset` into the local stack.
-- Never run this file against a hosted project.

begin;

insert into public.resources (id, name, resource_type, is_active)
values ('99100000-0000-0000-0000-000000000001', 'LOCAL VERIFY — ESTÚDIO', 'PHYSICAL', true);

insert into public.employees (id, name, is_active, resource_id)
values ('99100000-0000-0000-0000-000000000002', 'LOCAL VERIFY — Atendimento', true, null);

insert into public.categories (id, name, slug)
values ('99100000-0000-0000-0000-000000000003', 'LOCAL VERIFY — Locação', 'local-verify-locacao');

-- Follow the production invariant: policy first, activation second.
insert into public.services (
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  minimum_people, maximum_people,
  maximum_booking_horizon_days,
  confirmation_percentage,
  checkout_hold_minutes, payment_hold_minutes,
  allow_reschedule, allow_cancel, requires_terms,
  is_active, operation_scope,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks,
  price_per_block,
  booking_product_type,
  checkout_minimum_payment_type,
  checkout_minimum_payment_value,
  pix_discount_percent,
  payment_mode,
  card_max_installments
) values (
  '99100000-0000-0000-0000-000000000010',
  '99100000-0000-0000-0000-000000000003',
  'LOCAL VERIFY — Locação do estúdio',
  'local-verify-locacao-estudio',
  60, 180,
  1, 15,
  5000,
  50,
  20, 30,
  true, true, false,
  false, 'BLACKSHEEP',
  'BLOCKS', 30,
  2, 16,
  90,
  'STANDARD',
  'PERCENT',
  50,
  0,
  'MINIMUM_OR_FULL',
  6
);

-- Zero-penalty local policy keeps cancellation verification focused on state
-- transitions. It is test data only and does not copy or mutate production policy.
insert into public.service_change_policies (
  service_id,
  notice_hours,
  reschedule_first_early_percent,
  reschedule_first_late_percent,
  reschedule_repeat_percent,
  cancellation_late_percent,
  reschedule_first_early_penalty_type,
  reschedule_first_early_penalty_value,
  reschedule_first_late_penalty_type,
  reschedule_first_late_penalty_value,
  reschedule_repeat_penalty_type,
  reschedule_repeat_penalty_value,
  cancellation_late_penalty_type,
  cancellation_late_penalty_value
) values (
  '99100000-0000-0000-0000-000000000010',
  0, 0, 0, 0, 0,
  'PERCENT', 0,
  'PERCENT', 0,
  'PERCENT', 0,
  'PERCENT', 0
);

update public.services
set is_active = true,
    updated_at = now()
where id = '99100000-0000-0000-0000-000000000010';

insert into public.service_employees (id, service_id, employee_id, is_active)
values (
  '99100000-0000-0000-0000-000000000020',
  '99100000-0000-0000-0000-000000000010',
  '99100000-0000-0000-0000-000000000002',
  true
);

insert into public.service_resources (service_id, resource_id, is_required)
values (
  '99100000-0000-0000-0000-000000000010',
  '99100000-0000-0000-0000-000000000001',
  true
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes, is_active
)
select
  '99100000-0000-0000-0000-000000000020'::uuid,
  weekday,
  '08:00'::time,
  '20:00'::time,
  30,
  true
from generate_series(0, 6) weekday;

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time, is_active
)
select
  '99100000-0000-0000-0000-000000000001'::uuid,
  weekday,
  '08:00'::time,
  '20:00'::time,
  true
from generate_series(0, 6) weekday;

insert into public.booking_pages (
  id, slug, display_name, title, subtitle, brand_key, is_active, sort_order, require_tax_id
) values (
  '99100000-0000-0000-0000-000000000030',
  'local-verify-locacao',
  'LOCAL VERIFY — Locação',
  'Verificação local de locação',
  'Dados fictícios; nunca usar com clientes.',
  'BLACKSHEEP',
  true,
  999,
  false
);

insert into public.booking_page_services (booking_page_id, service_id, sort_order, is_active)
values (
  '99100000-0000-0000-0000-000000000030',
  '99100000-0000-0000-0000-000000000010',
  1,
  true
);

-- Test-only bridge: Auth users are created through the real local GoTrue admin API,
-- then this fixture registers that already-created UUID as an OWNER. No table grants
-- are widened and this function never exists outside the disposable local database.
create or replace function public.qa_register_local_verification_admin(p_auth_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid;
begin
  if p_auth_user_id is null then
    raise exception 'QA_LOCAL_AUTH_USER_REQUIRED';
  end if;

  insert into public.admin_users(auth_user_id, display_name, role, is_active)
  values(p_auth_user_id, 'LOCAL VERIFY — Owner', 'OWNER', true)
  returning id into v_admin_id;

  return v_admin_id;
end;
$$;

revoke all on function public.qa_register_local_verification_admin(uuid) from public, anon, authenticated;
grant execute on function public.qa_register_local_verification_admin(uuid) to service_role;

-- Test-only diagnostic. It repeats only the DB apply step inside a subtransaction
-- that is deliberately rolled back, so a failing E2E can expose the exact SQL error
-- without mutating the payment or appointment. Remove once the fixture is green.
create or replace function public.qa_diagnose_local_payment_apply(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_appointment_id uuid;
  v_tx public.payment_transactions%rowtype;
  v_sqlstate text;
  v_message text;
begin
  select appointment_id
  into v_appointment_id
  from public.appointment_access_tokens
  where token_hash = encode(digest(p_access_token, 'sha256'), 'hex')
  order by created_at desc
  limit 1;

  if v_appointment_id is null then
    return jsonb_build_object('diagnostic', 'ACCESS_TOKEN_NOT_FOUND');
  end if;

  select *
  into v_tx
  from public.payment_transactions
  where appointment_id = v_appointment_id
    and transaction_type = 'CHARGE'
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('diagnostic', 'PAYMENT_TRANSACTION_NOT_FOUND', 'appointment_id', v_appointment_id);
  end if;

  begin
    perform public.apply_provider_payment_status(
      v_tx.id,
      'LOCAL_DIAGNOSTIC_' || replace(gen_random_uuid()::text, '-', ''),
      'APPROVED',
      'local-diagnostic:' || replace(gen_random_uuid()::text, '-', ''),
      jsonb_build_object('source', 'ITEM_1_LOCAL_DIAGNOSTIC'),
      now()
    );
    raise exception 'QA_DIAGNOSTIC_APPLY_SUCCEEDED';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_message = message_text;
    return jsonb_build_object(
      'appointment_id', v_appointment_id,
      'transaction_id', v_tx.id,
      'transaction_status', v_tx.status,
      'sqlstate', v_sqlstate,
      'message', v_message
    );
  end;
end;
$$;

revoke all on function public.qa_diagnose_local_payment_apply(text) from public, anon, authenticated;
grant execute on function public.qa_diagnose_local_payment_apply(text) to service_role;



-- Item A test-only evidence reader. This exists only in the disposable local stack
-- and does not widen production access to appointment_authorship_events.
create or replace function public.qa_get_no_show_evidence(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_build_object(
      'action', e.action,
      'origin', e.origin,
      'admin_user_id', e.admin_user_id,
      'reason', e.reason,
      'has_ip', e.ip_address is not null,
      'has_user_agent', nullif(btrim(e.user_agent), '') is not null,
      'has_request_id', nullif(btrim(e.request_id), '') is not null
    )
    from public.appointment_authorship_events e
    where e.appointment_id = p_appointment_id
      and e.action = 'APPOINTMENT_NO_SHOW'
    order by e.occurred_at desc
    limit 1
  ), '{}'::jsonb);
$$;

revoke all on function public.qa_get_no_show_evidence(uuid) from public, anon, authenticated;
grant execute on function public.qa_get_no_show_evidence(uuid) to service_role;

commit;
