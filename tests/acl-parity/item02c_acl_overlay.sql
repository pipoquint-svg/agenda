\set ON_ERROR_STOP on

-- Item 2C proves the current production ACL contract on top of the canonical rebuild.
-- PR #393 legitimately adds service_admin_mark_appointment_no_show_evidenced; the
-- contract therefore advances with that production change instead of freezing a snapshot.
-- PR #399 adds one service-role-only operational RPC used by the Item C monitor;
-- its exact ACL and SECURITY DEFINER identity are asserted below before advancing counts.
do $$
declare
  v_identity text;
  v_oid oid;
  v_public_function_count integer;
  v_service_role_execute_count integer;
begin
  foreach v_identity in array array[
    'public.service_admin_upsert_change_policy(uuid,jsonb)',
    'public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer)',
    'public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb)',
    'public.maintenance_purge_audit_logs(timestamp with time zone,text,text)',
    'public.maintenance_purge_appointment_token_network_evidence(timestamp with time zone,text,text)'
  ] loop
    v_oid := to_regprocedure(v_identity);
    if v_oid is null then
      raise exception 'ITEM02C_PRIMITIVE_MISSING:%', v_identity;
    end if;
    if has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'ITEM02C_PRIMITIVE_STILL_EXECUTABLE:%', v_identity;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'ITEM02C_PRIMITIVE_APP_ROLE_EXPOSURE:%', v_identity;
    end if;
    if not exists (
      select 1
      from pg_proc p
      where p.oid = v_oid
        and p.prosecdef
        and pg_get_userbyid(p.proowner) = 'postgres'
    ) then
      raise exception 'ITEM02C_PRIMITIVE_IDENTITY_DRIFT:%', v_identity;
    end if;
  end loop;

  foreach v_identity in array array[
    'public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid)',
    'public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid)',
    'public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid)'
  ] loop
    v_oid := to_regprocedure(v_identity);
    if v_oid is null then
      raise exception 'ITEM02C_AUDITED_WRAPPER_MISSING:%', v_identity;
    end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'ITEM02C_AUDITED_WRAPPER_NOT_EXECUTABLE:%', v_identity;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'ITEM02C_AUDITED_WRAPPER_APP_ROLE_EXPOSURE:%', v_identity;
    end if;
    if not exists (
      select 1
      from pg_proc p
      where p.oid = v_oid
        and p.prosecdef
        and pg_get_userbyid(p.proowner) = 'postgres'
    ) then
      raise exception 'ITEM02C_AUDITED_WRAPPER_IDENTITY_DRIFT:%', v_identity;
    end if;
  end loop;

  -- PR #393: admin-change-actions uses adminClient(), whose database role is
  -- service_role. EXECUTE is therefore technically required for this RPC only;
  -- browser roles remain explicitly denied.
  v_identity := 'public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text)';
  v_oid := to_regprocedure(v_identity);
  if v_oid is null then
    raise exception 'ITEM02C_NO_SHOW_RPC_MISSING:%', v_identity;
  end if;
  if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_NO_SHOW_RPC_NOT_EXECUTABLE:%', v_identity;
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_NO_SHOW_RPC_APP_ROLE_EXPOSURE:%', v_identity;
  end if;

  -- PR #399: the ops alert monitor needs a narrow service-role-only reader for
  -- actionable schedule divergences. It must never become browser-executable.
  v_identity := 'public.service_list_ops_actionable_schedule_divergences(timestamp with time zone)';
  v_oid := to_regprocedure(v_identity);
  if v_oid is null then
    raise exception 'ITEM02C_OPS_DIVERGENCE_RPC_MISSING:%', v_identity;
  end if;
  if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_OPS_DIVERGENCE_RPC_NOT_EXECUTABLE:%', v_identity;
  end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE')
     or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_OPS_DIVERGENCE_RPC_APP_ROLE_EXPOSURE:%', v_identity;
  end if;
  if not exists (
    select 1
    from pg_proc p
    where p.oid = v_oid
      and p.prosecdef
      and pg_get_userbyid(p.proowner) = 'postgres'
  ) then
    raise exception 'ITEM02C_OPS_DIVERGENCE_RPC_IDENTITY_DRIFT:%', v_identity;
  end if;

  select count(*)::integer,
         count(*) filter (where has_function_privilege('service_role', p.oid, 'EXECUTE'))::integer
    into v_public_function_count, v_service_role_execute_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public';

  if v_public_function_count <> 417 then
    raise exception 'ITEM02C_PUBLIC_FUNCTION_COUNT_DRIFT:expected=417 actual=%', v_public_function_count;
  end if;
  if v_service_role_execute_count <> 363 then
    raise exception 'ITEM02C_EXECUTE_COUNT_DRIFT:expected=363 actual=%', v_service_role_execute_count;
  end if;
end
$$;

\echo ITEM02C_ACL_OVERLAY_OK
