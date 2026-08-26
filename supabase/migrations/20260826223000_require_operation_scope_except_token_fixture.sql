-- Make operation_scope mandatory for the live domain while preserving the two
-- synthetic Token Evidence records as explicit, immutable staging exceptions.
-- No commercial row is classified automatically.

alter table public.services
  drop constraint if exists services_operation_scope_required_ck;
alter table public.services
  add constraint services_operation_scope_required_ck
  check (
    operation_scope is not null
    or id = '97000000-0000-0000-0000-000000000010'::uuid
  );

alter table public.categories
  drop constraint if exists categories_operation_scope_required_ck;
alter table public.categories
  add constraint categories_operation_scope_required_ck
  check (
    operation_scope is not null
    or id = '97000000-0000-0000-0000-000000000001'::uuid
  );

create or replace function public.service_admin_update_operation_scope(
  p_service_id uuid,
  p_operation_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before text;
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope, ''))), '');
begin
  if v_scope is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_OPERATION_SCOPE_REQUIRED';
  end if;
  if v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode = 'P0001', message = 'SERVICE_OPERATION_SCOPE_INVALID';
  end if;

  select operation_scope into v_before
  from public.services
  where id = p_service_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_service_id = '97000000-0000-0000-0000-000000000010'::uuid then
    raise exception using errcode = 'P0001', message = 'TOKEN_EVIDENCE_OPERATION_SCOPE_IMMUTABLE';
  end if;

  if v_before is not distinct from v_scope then
    return jsonb_build_object(
      'service_id', p_service_id,
      'operation_scope', v_scope,
      'changed', false
    );
  end if;

  update public.services
  set operation_scope = v_scope,
      updated_at = now()
  where id = p_service_id;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_admin_id,
    'SERVICE',
    p_service_id,
    'OPERATION_SCOPE_CHANGED',
    jsonb_build_object('operation_scope', v_before),
    jsonb_build_object('operation_scope', v_scope),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', p_service_id,
    'operation_scope', v_scope,
    'changed', true
  );
end;
$$;

revoke all on function public.service_admin_update_operation_scope(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_operation_scope(uuid,text,uuid) to service_role;

comment on function public.service_admin_update_operation_scope(uuid,text,uuid) is
  'Sets mandatory BlackSheep/Sabrina service scope. NULL is rejected; the Token Evidence fixture is immutable and remains the sole explicit staging exception.';
