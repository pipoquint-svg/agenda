begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public, extensions;
select plan(41);

create function pg_temp.s1_throws(p_statement text, p_expected text)
returns boolean language plpgsql as $$
begin
  execute p_statement;
  return false;
exception when others then
  return sqlstate = p_expected;
end
$$;

-- The fixture is rolled back; no production entities are touched.
insert into public.tenants(id,name,slug,status)
values ('17000000-0000-4000-8000-000000000001','S1 tenant one','s1-campaign-one','ACTIVE'),
       ('17000000-0000-4000-8000-000000000002','S1 tenant two','s1-campaign-two','ACTIVE');

insert into public.marketing_campaigns(id,tenant_id,campaign_key,internal_name)
values ('17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000001','volte-sempre','Volte sempre');

insert into public.marketing_campaign_versions
(id,tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,
 discount_scope,validity_basis,validity_days,recurring_after_discounted_rental)
values ('17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010',1,
 'RENTAL_COMPLETED_FINANCIALLY_CLEARED','PERCENT',20,'SERVICE_ONLY',
 'BOOKING_CONFIRMATION',30,true);

insert into public.customers(id,name,email,phone)
values ('17000000-0000-4000-8000-000000000030','S1 test customer','s1-campaign@example.test','+5548999990001'),
       ('17000000-0000-4000-8000-000000000031','S1 wrong customer','s1-other@example.test','+5548999990002');

insert into public.coupons
(id,code,discount_type,discount_value,is_active,source,customer_id,max_uses,discount_scope)
values ('17000000-0000-4000-8000-000000000040','S1DRAFTCOUPON','PERCENT',20,false,'PROMOTION','17000000-0000-4000-8000-000000000030',1,'SERVICE_ONLY'),
       ('17000000-0000-4000-8000-000000000041','S1DRAFTCOUPON2','PERCENT',20,false,'PROMOTION','17000000-0000-4000-8000-000000000030',1,'SERVICE_ONLY');

insert into public.marketing_campaign_issuances
(tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,idempotency_key)
values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000040','17000000-0000-4000-8000-000000000030',
 'rent-2026-10-14-001');

select ok(to_regclass('public.marketing_campaigns') is not null, 'marketing_campaigns exists');

select ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid='public.marketing_campaigns'::regclass), 'marketing_campaigns has default-deny RLS');

select ok(not has_table_privilege('anon','public.marketing_campaigns','SELECT') and not has_table_privilege('authenticated','public.marketing_campaigns','INSERT'), 'marketing_campaigns not directly exposed to browser roles');

select ok(has_table_privilege('service_role','public.marketing_campaigns','SELECT') and not has_table_privilege('service_role','public.marketing_campaigns','INSERT'), 'marketing_campaigns is read-only for service_role until audited write APIs exist');

select ok(to_regclass('public.marketing_campaign_versions') is not null, 'marketing_campaign_versions exists');

select ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid='public.marketing_campaign_versions'::regclass), 'marketing_campaign_versions has default-deny RLS');

select ok(not has_table_privilege('anon','public.marketing_campaign_versions','SELECT') and not has_table_privilege('authenticated','public.marketing_campaign_versions','INSERT'), 'marketing_campaign_versions not directly exposed to browser roles');

select ok(has_table_privilege('service_role','public.marketing_campaign_versions','SELECT') and not has_table_privilege('service_role','public.marketing_campaign_versions','INSERT'), 'marketing_campaign_versions is read-only for service_role until audited write APIs exist');

select ok(to_regclass('public.marketing_campaign_issuances') is not null, 'marketing_campaign_issuances exists');

select ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid='public.marketing_campaign_issuances'::regclass), 'marketing_campaign_issuances has default-deny RLS');

select ok(not has_table_privilege('anon','public.marketing_campaign_issuances','SELECT') and not has_table_privilege('authenticated','public.marketing_campaign_issuances','INSERT'), 'marketing_campaign_issuances not directly exposed to browser roles');

select ok(has_table_privilege('service_role','public.marketing_campaign_issuances','SELECT') and not has_table_privilege('service_role','public.marketing_campaign_issuances','INSERT'), 'marketing_campaign_issuances is read-only for service_role until audited write APIs exist');

select ok(to_regclass('public.marketing_campaign_audit_events') is not null, 'marketing_campaign_audit_events exists');

select ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid='public.marketing_campaign_audit_events'::regclass), 'marketing_campaign_audit_events has default-deny RLS');

select ok(not has_table_privilege('anon','public.marketing_campaign_audit_events','SELECT') and not has_table_privilege('authenticated','public.marketing_campaign_audit_events','INSERT'), 'marketing_campaign_audit_events not directly exposed to browser roles');

select ok(has_table_privilege('service_role','public.marketing_campaign_audit_events','SELECT') and not has_table_privilege('service_role','public.marketing_campaign_audit_events','INSERT'), 'marketing_campaign_audit_events is read-only for service_role until audited write APIs exist');

select ok(not has_table_privilege('service_role','public.marketing_campaigns','UPDATE'), 'campaign state cannot be changed directly without an audited S2 RPC');

select ok(not has_table_privilege('service_role','public.marketing_campaign_versions','UPDATE') and not has_table_privilege('service_role','public.marketing_campaign_versions','DELETE'), 'marketing_campaign_versions is append-only for service_role');

select ok(not has_table_privilege('service_role','public.marketing_campaign_issuances','UPDATE') and not has_table_privilege('service_role','public.marketing_campaign_issuances','DELETE'), 'marketing_campaign_issuances is append-only for service_role');

select ok(not has_table_privilege('service_role','public.marketing_campaign_audit_events','UPDATE') and not has_table_privilege('service_role','public.marketing_campaign_audit_events','DELETE'), 'marketing_campaign_audit_events is append-only for service_role');

select ok((select count(*)=1 from public.marketing_campaigns),'S1 fixture created only one campaign');

select is((select state from public.marketing_campaigns where id='17000000-0000-4000-8000-000000000010'),'DRAFT'::text,'campaigns are inert by default');

select is((select validity_basis from public.marketing_campaign_versions where id='17000000-0000-4000-8000-000000000020'),'BOOKING_CONFIRMATION'::text,'validity is based on new reservation confirmation');

select is((select validity_days from public.marketing_campaign_versions where id='17000000-0000-4000-8000-000000000020'),30,'thirty-day booking window is representable');

select ok((select recurring_after_discounted_rental from public.marketing_campaign_versions where id='17000000-0000-4000-8000-000000000020'),'repeat issuance after discounted rental is representable');

select is((select discount_scope from public.marketing_campaign_versions where id='17000000-0000-4000-8000-000000000020'),'SERVICE_ONLY'::text,'offer can exclude extras');

select is((select count(*)::integer from public.marketing_campaign_issuances where campaign_id='17000000-0000-4000-8000-000000000010'),1,'issue ledger links a coupon without issuing one');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaigns (tenant_id,campaign_key,internal_name) values ('17000000-0000-4000-8000-000000000001','volte-sempre','Duplicate')$$,'23505'),'campaign key cannot duplicate in same tenant');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_versions(tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,discount_scope,validity_basis,validity_days) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010',1,'MANUAL','PERCENT',10,'SERVICE_ONLY','BOOKING_CONFIRMATION',30)$$,'23505'),'version number unique within campaign');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_versions(tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,discount_scope,validity_basis,validity_days) values ('17000000-0000-4000-8000-000000000002','17000000-0000-4000-8000-000000000010',2,'MANUAL','PERCENT',10,'SERVICE_ONLY','BOOKING_CONFIRMATION',30)$$,'23503'),'version cannot cross tenant boundary');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_versions(tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,discount_scope,validity_basis,validity_days) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010',2,'MANUAL','PERCENT',150,'SERVICE_ONLY','BOOKING_CONFIRMATION',30)$$,'23514'),'percentage cannot exceed 100');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_versions(tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,discount_scope,validity_basis,validity_days) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010',2,'MANUAL','PERCENT',10,'SERVICE_ONLY','BOOKING_CONFIRMATION',0)$$,'23514'),'validity days must be positive');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_versions(tenant_id,campaign_id,version_number,trigger_kind,discount_type,discount_value,discount_scope,validity_basis,validity_days,applies_to_extras) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010',2,'MANUAL','PERCENT',10,'SERVICE_ONLY','BOOKING_CONFIRMATION',30,true)$$,'23514'),'SERVICE_ONLY cannot include extras');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_issuances (tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,idempotency_key) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000040','17000000-0000-4000-8000-000000000030','rent-2026-10-14-001')$$,'23505'),'same event cannot issue twice');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_issuances (tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,idempotency_key) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000040','17000000-0000-4000-8000-000000000030','rent-2026-10-14-002')$$,'23505'),'same coupon cannot belong to multiple emissions');

select ok(exists (select 1 from pg_indexes where schemaname='public' and indexname='marketing_campaign_issuances_campaign_source_unique'), 'campaign source uniqueness prevents a rental from issuing a second reward');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_issuances (tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,idempotency_key) values ('17000000-0000-4000-8000-000000000002','17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000041','17000000-0000-4000-8000-000000000030','rent-2026-10-14-003')$$,'23503'),'emission tenant must match campaign version');

select ok(pg_temp.s1_throws($$insert into public.marketing_campaign_issuances (tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,idempotency_key) values ('17000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000010','17000000-0000-4000-8000-000000000020','17000000-0000-4000-8000-000000000041','17000000-0000-4000-8000-000000000031','rent-2026-10-14-004')$$,'23503'),'coupon cannot be attributed to another customer');

select ok(exists (select 1 from pg_constraint where conrelid='public.marketing_campaign_issuances'::regclass and conname='marketing_campaign_issuance_coupon_customer_fk' and contype='f'), 'coupon owner enforced by composite FK');

select ok((select count(*)=1 from public.marketing_campaign_issuances), 'failed duplicate attempts do not change ledger');

select ok((select count(*)=0 from public.marketing_campaign_audit_events), 'no unexpected audit event is emitted');

select * from finish();
rollback;
