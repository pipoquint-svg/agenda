begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

select ok(not (select is_active from public.birthday_automation_settings where operation_scope='SABRINA'),'Sabrina birthday automation stays disabled');
select ok(not (select send_message from public.birthday_automation_settings where operation_scope='SABRINA'),'Sabrina birthday messaging stays disabled');
select ok(not (select generate_coupon from public.birthday_automation_settings where operation_scope='SABRINA'),'Sabrina birthday coupon stays disabled');

select ok(not (select is_active from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'BlackSheep campaign is prepared but remains disabled until delivery consumer gate');
select ok((select send_message from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'BlackSheep policy includes birthday email');
select ok((select generate_coupon from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'BlackSheep policy includes birthday coupon');
select ok(not (select send_on_birthday from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'BlackSheep does not send a second message on birthday');
select is((select days_before from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),7,'BlackSheep sends seven days before birthday');
select is((select coupon_prefix from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'NIVER50','birthday coupon uses approved NIVER50 prefix');
select is((select coupon_discount_type from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'PERCENT','birthday coupon is percentage discount');
select is((select coupon_discount_value from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),50.00::numeric,'birthday coupon gives 50 percent');
select ok((select coupon_validity_days=30 and coupon_max_uses=1 and coupon_max_uses_per_customer=1 from public.birthday_automation_settings where operation_scope='BLACKSHEEP'),'birthday coupon is valid 30 days and single-use');

select ok(exists(
  select 1 from public.notification_template_configs t
  where t.event_key='BIRTHDAY' and t.channel='EMAIL' and t.audience='CUSTOMER'
    and t.operation_scope='BLACKSHEEP' and t.is_active
    and t.title_template='🎂 Seu aniversário merece um presente da BlackSheep'
    and t.body_template like '%{{coupon.code}}%'
    and t.body_template like '%{{coupon.expires_at}}%'
    and t.body_template like '%{{operation.site_url}}%'
),'approved BlackSheep birthday email template is seeded');

select is((select count(*)::integer from public.birthday_automation_cycles),0,'campaign configuration migration creates no birthday cycle or external effect');

select * from finish();
rollback;
