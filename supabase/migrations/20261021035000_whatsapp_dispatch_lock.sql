-- Trava: nenhum modelo de WhatsApp pode ficar ativo (nenhuma reserva dispara WhatsApp)
-- enquanto o envio para clientes não for liberado de propósito. Liberar = remover esta
-- constraint numa migração própria, depois do envio pronto e testado.
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'notification_template_configs_whatsapp_locked') then
    alter table public.notification_template_configs
      add constraint notification_template_configs_whatsapp_locked
      check (channel <> 'WHATSAPP' or is_active = false);
  end if;
end $mig$;
