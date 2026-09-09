\set ON_ERROR_STOP on

-- Item 2C proves the current production ACL contract plus explicitly authorized
-- server-only payment-provider RPCs introduced by the isolated InfinitePay Gate 2.
-- The aggregate counts also include later versioned admin/automation functions
-- whose individual grants are enforced by their migrations and the RLS baseline.
-- Private waitlist plus private rounds add 16 public-schema functions; 12 service
-- RPCs are executable by service_role (the four trigger functions remain trigger-only).
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
    if v_oid is null then raise exception 'ITEM02C_PRIMITIVE_MISSING:%', v_identity; end if;
    if has_function_privilege('service_role', v_oid, 'EXECUTE') then raise exception 'ITEM02C_PRIMITIVE_STILL_EXECUTABLE:%', v_identity; end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') or has_function_privilege('authenticated', v_oid, 'EXECUTE') then raise exception 'ITEM02C_PRIMITIVE_APP_ROLE_EXPOSURE:%', v_identity; end if;
    if not exists (select 1 from pg_proc p where p.oid=v_oid and p.prosecdef and pg_get_userbyid(p.proowner)='postgres') then raise exception 'ITEM02C_PRIMITIVE_IDENTITY_DRIFT:%', v_identity; end if;
  end loop;

  foreach v_identity in array array[
    'public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid)',
    'public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid)',
    'public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid)'
  ] loop
    v_oid := to_regprocedure(v_identity);
    if v_oid is null then raise exception 'ITEM02C_AUDITED_WRAPPER_MISSING:%', v_identity; end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then raise exception 'ITEM02C_AUDITED_WRAPPER_NOT_EXECUTABLE:%', v_identity; end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') or has_function_privilege('authenticated', v_oid, 'EXECUTE') then raise exception 'ITEM02C_AUDITED_WRAPPER_APP_ROLE_EXPOSURE:%', v_identity; end if;
    if not exists (select 1 from pg_proc p where p.oid=v_oid and p.prosecdef and pg_get_userbyid(p.proowner)='postgres') then raise exception 'ITEM02C_AUDITED_WRAPPER_IDENTITY_DRIFT:%', v_identity; end if;
  end loop;

  v_identity := 'public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text)';
  v_oid := to_regprocedure(v_identity);
  if v_oid is null then raise exception 'ITEM02C_NO_SHOW_RPC_MISSING:%', v_identity; end if;
  if not has_function_privilege('service_role', v_oid, 'EXECUTE') then raise exception 'ITEM02C_NO_SHOW_RPC_NOT_EXECUTABLE:%', v_identity; end if;
  if has_function_privilege('anon', v_oid, 'EXECUTE') or has_function_privilege('authenticated', v_oid, 'EXECUTE') then raise exception 'ITEM02C_NO_SHOW_RPC_APP_ROLE_EXPOSURE:%', v_identity; end if;

  foreach v_identity in array array[
    'public.service_create_infinitepay_payment_intent_by_token(text,text,text)',
    'public.service_claim_infinitepay_checkout_by_token(text,text,text)',
    'public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)',
    'public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb)',
    'public.service_get_infinitepay_runtime_config()'
  ] loop
    v_oid := to_regprocedure(v_identity);
    if v_oid is null then raise exception 'ITEM02C_INFINITEPAY_RPC_MISSING:%', v_identity; end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then raise exception 'ITEM02C_INFINITEPAY_RPC_NOT_EXECUTABLE:%', v_identity; end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') or has_function_privilege('authenticated', v_oid, 'EXECUTE') then raise exception 'ITEM02C_INFINITEPAY_RPC_APP_ROLE_EXPOSURE:%', v_identity; end if;
    if not exists (select 1 from pg_proc p where p.oid=v_oid and p.prosecdef and pg_get_userbyid(p.proowner)='postgres') then raise exception 'ITEM02C_INFINITEPAY_RPC_IDENTITY_DRIFT:%', v_identity; end if;
  end loop;

  foreach v_identity in array array[
    'public.service_admin_waitlist_private_round_action(text,jsonb,uuid)',
    'public.public_waitlist_private_round_action(text,text,jsonb)'
  ] loop
    v_oid := to_regprocedure(v_identity);
    if v_oid is null then raise exception 'ITEM02C_PRIVATE_ROUND_RPC_MISSING:%', v_identity; end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then raise exception 'ITEM02C_PRIVATE_ROUND_RPC_NOT_EXECUTABLE:%', v_identity; end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') or has_function_privilege('authenticated', v_oid, 'EXECUTE') then raise exception 'ITEM02C_PRIVATE_ROUND_RPC_APP_ROLE_EXPOSURE:%', v_identity; end if;
    if not exists (select 1 from pg_proc p where p.oid=v_oid and p.prosecdef and pg_get_userbyid(p.proowner)='postgres') then raise exception 'ITEM02C_PRIVATE_ROUND_RPC_IDENTITY_DRIFT:%', v_identity; end if;
  end loop;

  v_identity := 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)';
  v_oid := to_regprocedure(v_identity);
  if v_oid is null then raise exception 'ITEM02C_MONTHLY_AVAILABILITY_RPC_MISSING:%', v_identity; end if;
  if not has_function_privilege('anon', v_oid, 'EXECUTE')
     or not has_function_privilege('authenticated', v_oid, 'EXECUTE')
     or not has_function_privilege('service_role', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_MONTHLY_AVAILABILITY_RPC_GRANT_DRIFT:%', v_identity;
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid=v_oid
      and not p.prosecdef
      and p.provolatile='s'
      and pg_get_userbyid(p.proowner)='postgres'
  ) then
    raise exception 'ITEM02C_MONTHLY_AVAILABILITY_RPC_IDENTITY_DRIFT:%', v_identity;
  end if;

  v_identity := 'agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)';
  v_oid := to_regprocedure(v_identity);
  if v_oid is null then raise exception 'ITEM02C_MONTHLY_AVAILABILITY_IMPL_MISSING:%', v_identity; end if;
  if not has_schema_privilege('anon', 'agenda_internal', 'USAGE')
     or not has_schema_privilege('authenticated', 'agenda_internal', 'USAGE')
     or not has_schema_privilege('service_role', 'agenda_internal', 'USAGE')
     or not has_function_privilege('anon', v_oid, 'EXECUTE')
     or not has_function_privilege('authenticated', v_oid, 'EXECUTE')
     or not has_function_privilege('service_role', v_oid, 'EXECUTE') then
    raise exception 'ITEM02C_MONTHLY_AVAILABILITY_IMPL_GRANT_DRIFT:%', v_identity;
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid=v_oid
      and p.prosecdef
      and p.provolatile='s'
      and pg_get_userbyid(p.proowner)='postgres'
      and exists (
        select 1
        from unnest(coalesce(p.proconfig, '{}'::text[])) config(value)
        where config.value = 'search_path=""'
      )
  ) then
    raise exception 'ITEM02C_MONTHLY_AVAILABILITY_IMPL_IDENTITY_DRIFT:%', v_identity;
  end if;

  select count(*)::integer,
         count(*) filter (where has_function_privilege('service_role', p.oid, 'EXECUTE'))::integer
    into v_public_function_count, v_service_role_execute_count
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public';

  if v_public_function_count <> 443 then raise exception 'ITEM02C_PUBLIC_FUNCTION_COUNT_DRIFT:expected=443 actual=%', v_public_function_count; end if;
  if v_service_role_execute_count <> 385 then raise exception 'ITEM02C_EXECUTE_COUNT_DRIFT:expected=385 actual=%', v_service_role_execute_count; end if;
end
$$;

\echo ITEM02C_ACL_OVERLAY_OK
