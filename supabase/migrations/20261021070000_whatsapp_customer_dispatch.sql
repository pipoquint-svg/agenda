-- Envio de WhatsApp para clientes nas reservas (ainda travado):
--   * o registro de entregas passa a aceitar o canal WHATSAPP;
--   * a integração guarda o administrador que responde pelos envios automáticos no
--     Dracma (preenchido por quem envia modelos para a Meta).
-- A trava notification_template_configs_whatsapp_locked continua: nenhum modelo de
-- WhatsApp fica ativo, então nada é enviado até ela ser removida de propósito.
alter table public.notification_delivery_logs
  drop constraint if exists notification_delivery_logs_channel_check;
alter table public.notification_delivery_logs
  add constraint notification_delivery_logs_channel_check
  check (channel = any (array['EMAIL'::text, 'GOOGLE_CALENDAR'::text, 'WHATSAPP'::text]));

alter table public.whatsapp_tenant_integrations
  add column if not exists dispatch_admin_id uuid null;
