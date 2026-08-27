-- Atomic administrative owner transfer.
-- The target must already exist in public.admin_users; Auth user creation stays server-side
-- in the admin-team-members Edge Function. Exactly one active OWNER remains afterwards.

create or replace function public.service_admin_transfer_owner(
  p_target_admin_id uuid,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_actor public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
  v_before_actor jsonb;
  v_before_target jsonb;
  v_after_actor jsonb;
  v_after_target jsonb;
begin
  select * into v_actor
  from public.admin_users
  where id = p_actor_admin_id
    and is_active
  for update;

  if not found then
    raise exception using errcode='P0001', message='ADMIN_USER_NOT_FOUND';
  end if;

  if v_actor.role <> 'OWNER' then
    raise exception using errcode='P0001', message='ADMIN_OWNER_REQUIRED';
  end if;

  select * into v_target
  from public.admin_users
  where id = p_target_admin_id
    and is_active
  for update;

  if not found then
    raise exception using errcode='P0001', message='ADMIN_TARGET_NOT_FOUND';
  end if;

  if p_target_admin_id = p_actor_admin_id then
    raise exception using errcode='P0001', message='ADMIN_OWNER_TRANSFER_TARGET_SAME';
  end if;

  select public.service_admin_get_access_profile(v_actor.id) into v_before_actor;
  select public.service_admin_get_access_profile(v_target.id) into v_before_target;

  -- The operational agenda account becomes an OPERATION user after handoff.
  -- Any accidental additional active OWNER is also demoted, preserving the single-owner invariant.
  update public.admin_users
  set role = 'OPERATION', updated_at = now()
  where is_active
    and role = 'OWNER'
    and id <> p_target_admin_id;

  update public.admin_users
  set role = 'OWNER', updated_at = now()
  where id = p_target_admin_id;

  select public.service_admin_get_access_profile(v_actor.id) into v_after_actor;
  select public.service_admin_get_access_profile(v_target.id) into v_after_target;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_actor_admin_id,
    'ADMIN_USER',
    p_target_admin_id,
    'ADMIN_OWNER_TRANSFERRED',
    jsonb_build_object('actor', v_before_actor, 'target', v_before_target),
    jsonb_build_object('actor', v_after_actor, 'target', v_after_target),
    'ADMIN'
  );

  return jsonb_build_object(
    'previous_owner', v_after_actor,
    'new_owner', v_after_target
  );
end;
$$;

revoke all on function public.service_admin_transfer_owner(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_transfer_owner(uuid,uuid) to service_role;

comment on function public.service_admin_transfer_owner(uuid,uuid) is
  'Atomically promotes one active admin to OWNER and demotes every other active OWNER to OPERATION. Caller must currently be OWNER.';
