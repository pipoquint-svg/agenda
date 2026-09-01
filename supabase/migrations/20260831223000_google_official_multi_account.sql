-- Google Calendar official multi-account ownership.
-- One active general account plus one active account per employee.
-- Existing connections remain GENERAL for backwards compatibility.

alter table public.google_connections
  add column if not exists owner_type text not null default 'GENERAL',
  add column if not exists employee_id uuid null;

alter table public.google_connections
  add constraint google_connections_owner_type_check
    check (owner_type in ('GENERAL', 'EMPLOYEE')),
  add constraint google_connections_owner_shape_check
    check (
      (owner_type = 'GENERAL' and employee_id is null)
      or (owner_type = 'EMPLOYEE' and employee_id is not null)
    ),
  add constraint google_connections_employee_fk
    foreign key (employee_id) references public.employees(id) on delete restrict;

create unique index google_connections_one_active_general_idx
  on public.google_connections (owner_type)
  where owner_type = 'GENERAL' and status = 'ACTIVE';

create unique index google_connections_one_active_employee_idx
  on public.google_connections (employee_id)
  where owner_type = 'EMPLOYEE' and status = 'ACTIVE';

alter table public.google_oauth_states
  add column if not exists owner_type text not null default 'GENERAL',
  add column if not exists employee_id uuid null;

alter table public.google_oauth_states
  add constraint google_oauth_states_owner_type_check
    check (owner_type in ('GENERAL', 'EMPLOYEE')),
  add constraint google_oauth_states_owner_shape_check
    check (
      (owner_type = 'GENERAL' and employee_id is null)
      or (owner_type = 'EMPLOYEE' and employee_id is not null)
    ),
  add constraint google_oauth_states_employee_fk
    foreign key (employee_id) references public.employees(id) on delete cascade;

create or replace function public.consume_google_oauth_state(p_state_hash text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state public.google_oauth_states%rowtype;
begin
  select * into v_state
  from public.google_oauth_states
  where state_hash = p_state_hash
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_INVALID';
  end if;

  if v_state.consumed_at is not null then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_ALREADY_USED';
  end if;

  if v_state.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_EXPIRED';
  end if;

  update public.google_oauth_states
  set consumed_at = now()
  where state_hash = p_state_hash;

  return jsonb_build_object(
    'admin_user_id', v_state.requested_by_admin_user_id,
    'success_url', v_state.success_url,
    'owner_type', v_state.owner_type,
    'employee_id', v_state.employee_id
  );
end;
$function$;

comment on column public.google_connections.owner_type is
  'Owner slot for the Google account: GENERAL or EMPLOYEE.';
comment on column public.google_connections.employee_id is
  'Employee owning this Google connection when owner_type=EMPLOYEE.';
