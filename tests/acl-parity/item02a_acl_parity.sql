\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset fieldsep '\t'

create temporary table acl_actual as
with rel_objects as (
  select
    case when c.relkind='S' then 'sequence' when c.relkind in ('v','m') then 'view' else 'table' end as object_kind,
    format('%I.%I',n.nspname,c.relname) as object_identity,
    pg_get_userbyid(c.relowner) as owner_role,
    coalesce(c.relacl,acldefault(case when c.relkind='S' then 'S'::"char" else 'r'::"char" end,c.relowner)) as acl
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','p','v','m','f','S')
),
fn_objects as (
  select
    'function'::text as object_kind,
    format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) as object_identity,
    pg_get_userbyid(p.proowner) as owner_role,
    coalesce(p.proacl,acldefault('f'::"char",p.proowner)) as acl
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
),
objects as (
  select * from rel_objects
  union all
  select * from fn_objects
)
select
  o.object_kind,
  o.object_identity,
  o.owner_role,
  coalesce(grantee_role.rolname,'PUBLIC') as grantee,
  grantor_role.rolname as grantor,
  a.privilege_type,
  a.is_grantable
from objects o
cross join lateral aclexplode(o.acl) a
left join pg_roles grantee_role on grantee_role.oid=a.grantee
join pg_roles grantor_role on grantor_role.oid=a.grantor;

create temporary table acl_expected (
  object_kind text not null,
  object_identity text not null,
  owner_role text not null,
  grantee text not null,
  grantor text not null,
  privilege_type text not null,
  is_grantable boolean not null
);

create temporary table expected_rel_privileges(privilege_type text primary key);
insert into expected_rel_privileges values
  ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN');

-- Every production table/view owner is postgres and starts with the same relation ACL.
insert into acl_expected
select
  case when c.relkind in ('v','m') then 'view' else 'table' end,
  format('%I.%I',n.nspname,c.relname),
  'postgres','postgres','postgres',p.privilege_type,false
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
cross join expected_rel_privileges p
where n.nspname='public' and c.relkind in ('r','p','v','m','f');

insert into acl_expected
select
  case when c.relkind in ('v','m') then 'view' else 'table' end,
  format('%I.%I',n.nspname,c.relname),
  'postgres','service_role','postgres',p.privilege_type,false
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
cross join expected_rel_privileges p
where n.nspname='public' and c.relkind in ('r','p','v','m','f');

-- Production relation exceptions.
delete from acl_expected
where grantee='service_role'
  and object_identity = any(ARRAY[
    'public.appointment_authorship_events',
    'public.public_rate_limit_buckets'
  ]::text[])
  and object_kind='table';

delete from acl_expected
where grantee='service_role'
  and object_identity = any(ARRAY[
    'public.appointment_change_policy_snapshot_terms',
    'public.appointment_change_policy_snapshots',
    'public.appointment_change_settlements',
    'public.audit_logs',
    'public.customer_balance_movements'
  ]::text[])
  and privilege_type in ('UPDATE','DELETE','TRUNCATE')
  and object_kind='table';

delete from acl_expected
where grantee='service_role'
  and object_identity = any(ARRAY[
    'public.appointment_token_events',
    'public.appointment_token_network_evidence'
  ]::text[])
  and privilege_type in ('UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  and object_kind='table';

delete from acl_expected
where grantee='service_role'
  and object_identity = any(ARRAY[
    'public.audit_purge_runs',
    'public.audit_retention_policy',
    'public.pre_reservation_access_tokens',
    'public.pre_reservations'
  ]::text[])
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')
  and object_kind='table';

delete from acl_expected
where grantee='service_role'
  and object_identity = any(ARRAY[
    'public.appointment_token_network_purge_runs'
  ]::text[])
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  and object_kind='table';

-- Item C alert state is internal and least-privileged. Edge evidence is append-only
-- through a SECURITY DEFINER RPC; the monitor may only read it. Deduplication state
-- permits the monitor to read, insert and update, but never delete or truncate.
delete from acl_expected
where grantee='service_role'
  and object_identity='public.ops_edge_failure_events'
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  and object_kind='table';

delete from acl_expected
where grantee='service_role'
  and object_identity='public.ops_alert_states'
  and privilege_type in ('DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  and object_kind='table';

-- Sequences.
insert into acl_expected
select 'sequence',format('%I.%I',n.nspname,c.relname),'postgres',role_name,'postgres',privilege_type,false
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
cross join (values ('postgres'),('service_role')) roles(role_name)
cross join (values ('SELECT'),('UPDATE'),('USAGE')) privs(privilege_type)
where n.nspname='public' and c.relkind='S';

delete from acl_expected
where object_kind='sequence'
  and object_identity='public.ops_edge_failure_events_id_seq'
  and grantee='service_role';

-- Functions: current production postgres + service_role EXECUTE, with explicit exceptions.
insert into acl_expected
select 'function',
       format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),
       'postgres',role_name,'postgres','EXECUTE',false
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
cross join (values ('postgres'),('service_role')) roles(role_name)
where n.nspname='public';

delete from acl_expected
where object_kind='function'
  and grantee='service_role'
  and object_identity = any(ARRAY[
    'public.assert_birthday_coupon_has_locacao_service()',
    'public.assert_booking_page_activation_has_policies()',
    'public.assert_booking_page_service_has_change_policy()',
    'public.capture_appointment_commercial_configuration()',
    'public.capture_appointment_service_type_snapshot()',
    'public.capture_current_appointment_change_policy_snapshot()',
    'public.copy_checkout_attribution_to_appointment()',
    'public.customer_access_appointment_before_insert()',
    'public.customer_access_no_show_after_update()',
    'public.customers_capture_identity_keys_trigger()',
    'public.enforce_active_service_has_change_policy()',
    'public.enforce_cancellation_financial_settlement_permission()',
    'public.enforce_category_operation_change()',
    'public.enforce_checkout_coupon_customer()',
    'public.enforce_coupon_customer_usage_limit()',
    'public.enforce_direct_public_hold_rate_limit()',
    'public.enforce_google_sync_ready_for_new_hold_allocation()',
    'public.enforce_invoice_due_basis_integrity()',
    'public.enforce_service_category_operation()',
    'public.enqueue_no_show_balance_cancellation()',
    'public.ensure_appointment_schedule_defaults()',
    'public.ensure_checkout_hold_schedule_defaults()',
    'public.guard_birthday_coupon_service_scope()',
    'public.guard_customer_access_append_only()',
    'public.guard_duplicate_balance_payment()',
    'public.maintenance_purge_appointment_token_network_evidence(p_before timestamp with time zone, p_reason text, p_requested_by text)',
    'public.maintenance_purge_audit_logs(p_before timestamp with time zone, p_reason text, p_requested_by text)',
    'public.mark_balance_collection_paid_after_payment()',
    'public.mark_confirmed_appointment_policy_snapshot()',
    'public.populate_checkout_hold_quote_snapshot()',
    'public.prevent_active_service_policy_removal()',
    'public.prevent_appointment_confirmation_snapshot_change()',
    'public.prevent_duration_pricing_overlap()',
    'public.prevent_hour_package_movement_mutation()',
    'public.prevent_public_service_policy_delete()',
    'public.reject_appointment_authorship_mutation()',
    'public.reject_appointment_change_policy_snapshot_mutation()',
    'public.reject_appointment_token_event_mutation()',
    'public.reject_appointment_token_network_mutation()',
    'public.reject_appointment_token_purge_run_mutation()',
    'public.reject_audit_log_mutation()',
    'public.reject_financial_ledger_mutation()',
    'public.revoke_action_tokens_after_appointment_change()',
    'public.seed_hour_package_initial_credit()',
    'public.service_admin_replace_duration_configuration(p_service_id uuid, p_pricing_tiers jsonb, p_duration_presets jsonb)',
    'public.service_admin_update_timing(p_service_id uuid, p_duration_mode text, p_base_duration_minutes integer, p_booking_block_minutes integer, p_minimum_booking_blocks integer, p_maximum_booking_blocks integer, p_base_price numeric, p_price_per_block numeric, p_buffer_before_minutes integer, p_buffer_after_minutes integer)',
    'public.service_admin_upsert_change_policy(p_service_id uuid, p_policy jsonb)',
    'public.sync_promoted_appointment_schedule()',
    'public.touch_duration_preset_updated_at()',
    'public.touch_extra_schedule_rule_updated_at()',
    'public.touch_service_extra_schedule_version()',
    'public.trg_enqueue_kommo_appointment_sync()',
    'public.trg_enqueue_kommo_extra_sync()',
    'public.trg_enqueue_kommo_payment_sync()'
  ]::text[]);

insert into acl_expected
select 'function',x,'postgres','PUBLIC','postgres','EXECUTE',false
from unnest(ARRAY[
    'public.apply_external_physical_post_buffer()',
    'public.apply_typed_change_penalty_metadata()',
    'public.blacksheep_rental_special_date(p_date date)',
    'public.blacksheep_special_date_treatment(p_date date)',
    'public.calculate_booking_quotes_for_duration_batch(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_ats timestamp with time zone[], p_coupon_code text)',
    'public.calculate_booking_quotes_for_duration_listing_batch(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_ats timestamp with time zone[], p_coupon_code text)',
    'public.create_checkout_hold_for_reschedule(p_appointment_id uuid, p_requested_start_at timestamp with time zone)',
    'public.list_available_slots_for_duration_reschedule_base(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text, p_ignore_appointment_id uuid)',
    'public.populate_appointment_block_pricing_snapshots()'
  ]::text[]) x;

insert into acl_expected
select 'function',x,'postgres',role_name,'postgres','EXECUTE',false
from unnest(ARRAY[
    'public.public_get_booking_page(p_slug text)',
    'public.public_list_available_slots(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
    'public.public_list_available_slots_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
    'public.public_list_available_slots_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
    'public.public_quote_booking(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer)',
    'public.public_quote_booking_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer)',
    'public.public_quote_booking_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer)'
  ]::text[]) x
cross join (values ('anon'),('authenticated')) roles(role_name);

insert into acl_expected
select 'function',x,'postgres','authenticated','postgres','EXECUTE',false
from unnest(ARRAY[
    'public.service_admin_search_appointments_global(p_search text, p_limit integer)'
  ]::text[]) x;

create temporary table object_identity_actual as
select object_kind,object_identity
from (
  select case when c.relkind='S' then 'sequence' when c.relkind in ('v','m') then 'view' else 'table' end object_kind,
         format('%I.%I',n.nspname,c.relname) object_identity
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','p','v','m','f','S')
  union all
  select 'function',format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid))
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
) s;

create temporary table production_identity_summary(
  object_kind text primary key,
  object_count integer not null,
  identity_hash text not null
);
insert into production_identity_summary values
('function',415,'7aad93f397b2615e870ca05657cbb8da0277dc86236f46338377f8a371d720a7'),
('sequence',2,'99e36457a1d727e777762be43d4945bf0bf92f9e08b804087742d279b9618a41'),
('table',105,'bd560cab9a4c71c757335fadaf9d23f9b168b07c39f4451a8f822701e2cbf1f5'),
('view',8,'bcb8b6692e6b40eaf95ef20d1c9e115ad622c27c4fc0f78d0e3b4907c5b1b6c2');

create temporary table actual_identity_summary as
select object_kind,count(*)::integer object_count,
       encode(extensions.digest(string_agg(object_identity,E'\n' order by object_identity),'sha256'),'hex') identity_hash
from object_identity_actual group by object_kind;

create temporary table acl_diff as
select 'ACTUAL_ONLY'::text side,a.* from acl_actual a
except
select 'ACTUAL_ONLY',e.* from acl_expected e
union all
select 'EXPECTED_ONLY',e.* from acl_expected e
except
select 'EXPECTED_ONLY',a.* from acl_actual a;

create temporary table identity_diff as
select 'ACTUAL'::text side,a.object_kind,a.object_count,a.identity_hash
from actual_identity_summary a
join production_identity_summary p using(object_kind)
where (a.object_count,a.identity_hash) is distinct from (p.object_count,p.identity_hash)
union all
select 'PRODUCTION',p.object_kind,p.object_count,p.identity_hash
from production_identity_summary p
join actual_identity_summary a using(object_kind)
where (a.object_count,a.identity_hash) is distinct from (p.object_count,p.identity_hash);

create temporary table production_acl_summary(
  object_kind text primary key,
  object_count integer not null,
  acl_row_count integer not null,
  acl_hash text not null
);
insert into production_acl_summary values
('function',415,800,'e117d0693ec6bee7118a61d950f73e3aace623f01372d57e1189a70249b7702a'),
('sequence',2,12,'a22f76984f935d27010a77efbbe5e0a13a21a2b818cd959edaafc37067a172ea'),
('table',105,1614,'fba3298eb16529b3f223c6def1fe895194534a5883595608923a5ecd0a3c4df4'),
('view',8,128,'f09dedfa6c33eb98d6840f295c537ce4be013f4f6949c094d7b28ebc14e164be');

create temporary table actual_acl_summary as
with per_object as (
  select object_kind,object_identity,owner_role,count(*) acl_row_count,
         encode(
           extensions.digest(
             owner_role || E'\n' ||
             string_agg(format('%s|%s|%s|%s',grantee,grantor,privilege_type,is_grantable),
                        E'\n' order by grantee,grantor,privilege_type,is_grantable),
             'sha256'
           ),
           'hex'
         ) acl_hash
  from acl_actual
  group by object_kind,object_identity,owner_role
)
select object_kind,count(*)::integer object_count,sum(acl_row_count)::integer acl_row_count,
       encode(
         extensions.digest(
           string_agg(object_identity||'|'||owner_role||'|'||acl_hash,E'\n' order by object_identity),
           'sha256'
         ),
         'hex'
       ) acl_hash
from per_object group by object_kind;

create temporary table acl_summary_diff as
select 'ACTUAL'::text side,a.object_kind,a.object_count,a.acl_row_count,a.acl_hash
from actual_acl_summary a join production_acl_summary p using(object_kind)
where (a.object_count,a.acl_row_count,a.acl_hash) is distinct from (p.object_count,p.acl_row_count,p.acl_hash)
union all
select 'PRODUCTION',p.object_kind,p.object_count,p.acl_row_count,p.acl_hash
from production_acl_summary p join actual_acl_summary a using(object_kind)
where (a.object_count,a.acl_row_count,a.acl_hash) is distinct from (p.object_count,p.acl_row_count,p.acl_hash);

select 'IDENTITY_SUMMARY',object_kind,object_count,identity_hash from actual_identity_summary order by object_kind;
select 'ACL_SUMMARY',object_kind,object_count,acl_row_count,acl_hash from actual_acl_summary order by object_kind;
select 'DIRECT_RELATION_GRANT',object_kind,object_identity,grantee,privilege_type
from acl_actual
where object_kind in ('table','view','sequence') and grantee in ('anon','authenticated')
order by object_kind,object_identity,grantee,privilege_type;
select 'IDENTITY_DIFF',* from identity_diff order by object_kind,side;
select 'ACL_SUMMARY_DIFF',* from acl_summary_diff order by object_kind,side;
select 'ACL_ROW_DIFF',* from acl_diff order by object_kind,object_identity,grantee,privilege_type,side;

do $$
begin
  if exists (select 1 from identity_diff) then
    raise exception 'ACL_PARITY_IDENTITY_DIFF_PRESENT';
  end if;
  if exists (select 1 from acl_diff) then
    raise exception 'ACL_PARITY_ROW_DIFF_PRESENT';
  end if;
  if exists (select 1 from acl_summary_diff) then
    raise exception 'ACL_PARITY_SUMMARY_DIFF_PRESENT';
  end if;
  if exists (
    select 1 from acl_actual
    where object_kind in ('table','view','sequence') and grantee in ('anon','authenticated')
  ) then
    raise exception 'ACL_PARITY_BROWSER_RELATION_GRANT_PRESENT';
  end if;
end
$$;
