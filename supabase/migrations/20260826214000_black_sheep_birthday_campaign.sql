-- Issue #217 / V1.5 #257 — approved BlackSheep birthday campaign.
-- Configuration is prepared but remains disabled until the controlled delivery consumer is merged and smoke-tested.
-- No customer, coupon, delivery log, scheduler invocation, or external provider call is produced by this migration.

-- Sabrina stays explicitly disabled.
update public.birthday_automation_settings
set is_active = false,
    send_message = false,
    generate_coupon = false,
    updated_at = now()
where operation_scope = 'SABRINA';

-- BlackSheep approved commercial policy:
-- 7 days before birthday, email + 50% single-use coupon for the operation catalog,
-- valid 30 days from issue. No second send on the birthday itself.
update public.birthday_automation_settings
set is_active = false,
    send_message = true,
    generate_coupon = true,
    send_on_birthday = false,
    days_before = 7,
    coupon_prefix = 'NIVER50',
    coupon_discount_type = 'PERCENT',
    coupon_discount_value = 50,
    coupon_validity_days = 30,
    coupon_max_uses = 1,
    coupon_max_uses_per_customer = 1,
    updated_at = now()
where operation_scope = 'BLACKSHEEP';

-- Seed the approved BlackSheep customer email if no operation-level birthday template exists.
-- The template is active as configuration, but it cannot enqueue anything while the birthday
-- automation setting above remains disabled.
insert into public.notification_template_configs (
  event_key,
  channel,
  audience,
  operation_scope,
  category_id,
  title_template,
  body_template,
  is_active,
  variable_schema,
  reminder_offset_minutes,
  created_by_admin_id,
  updated_by_admin_id
)
select
  'BIRTHDAY',
  'EMAIL',
  'CUSTOMER',
  'BLACKSHEEP',
  null,
  '🎂 Seu aniversário merece um presente da BlackSheep',
  E'Olá, {{customer.name}}!\n\nSeu aniversário está chegando e a BlackSheep resolveu começar a comemoração um pouquinho antes.\n\nPreparamos um presente para você: 50% de desconto em uma locação na BlackSheep.\n\nUse seu cupom exclusivo na hora de fazer a reserva. Ele é de uso único e fica disponível por 30 dias.\n\nSeu cupom: {{coupon.code}}\nVálido até {{coupon.expires_at}}\n\nUsar meu presente: {{operation.site_url}}\n\nEscolha seu horário, prepare suas ideias e venha criar com a gente. 🖤\n\nFeliz aniversário adiantado!\nEquipe BlackSheep',
  true,
  '["customer.name","coupon.code","coupon.expires_at","operation.site_url"]'::jsonb,
  null,
  null,
  null
where not exists (
  select 1
  from public.notification_template_configs t
  where t.event_key = 'BIRTHDAY'
    and t.channel = 'EMAIL'
    and t.audience = 'CUSTOMER'
    and t.operation_scope = 'BLACKSHEEP'
    and t.category_id is null
    and not exists (
      select 1 from public.notification_template_services nts where nts.template_id = t.id
    )
);

-- Snapshot the seeded configuration in the same version ledger used by admin edits.
insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
select
  t.id,
  1,
  to_jsonb(t) || jsonb_build_object('service_ids', '[]'::jsonb),
  null
from public.notification_template_configs t
where t.event_key = 'BIRTHDAY'
  and t.channel = 'EMAIL'
  and t.audience = 'CUSTOMER'
  and t.operation_scope = 'BLACKSHEEP'
  and t.category_id is null
  and t.title_template = '🎂 Seu aniversário merece um presente da BlackSheep'
  and not exists (
    select 1 from public.notification_template_versions v where v.template_id = t.id
  );
