-- Libera o envio de WhatsApp para clientes (decisão do usuário em 2026-10-21).
--   * remove a trava notification_template_configs_whatsapp_locked;
--   * define quem responde pelos envios automáticos no Dracma quando ainda não há
--     ninguém: o único OWNER ativo do tenant da integração (nunca adivinha se houver
--     mais de um);
--   * ativa os modelos de WhatsApp da BlackSheep já aprovados pela Meta e sem
--     alteração desde o envio, sem mexer em updated_at (o whatsapp-send compara
--     updated_at com submitted_at para barrar modelos editados).
-- A outra trava (WHATSAPP_CUSTOMER_DISPATCH_ENABLED no ambiente) continua valendo.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_whatsapp_locked;

update public.whatsapp_tenant_integrations i
set dispatch_admin_id = owners.user_id
from (
  select tenant_id, min(user_id::text)::uuid as user_id
  from public.tenant_members
  where role = 'OWNER' and status = 'ACTIVE'
  group by tenant_id
  having count(*) = 1
) owners
where owners.tenant_id = i.tenant_id
  and i.dispatch_admin_id is null
  and i.status = 'CONNECTED';

update public.notification_template_configs c
set is_active = true
where c.channel = 'WHATSAPP'
  and c.operation_scope = 'BLACKSHEEP'
  and c.event_key in ('APPOINTMENT_APPROVED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED')
  and c.is_active = false
  and exists (
    select 1
    from public.whatsapp_template_submissions s
    where s.notification_template_id = c.id
      and s.status = 'APPROVED'
      and s.submitted_at >= c.updated_at
  )
  and not exists (
    select 1
    from public.notification_whatsapp_settings w
    join public.whatsapp_template_submissions s on s.notification_template_id = c.id and s.status = 'APPROVED'
    where w.template_id = c.id
      and w.updated_at > s.submitted_at
  );
