create or replace function public.record_notification_template_fallback_alert()
returns trigger
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_scope text;
  v_should_record boolean := false;
begin
  if new.event_key <> 'APPOINTMENT_APPROVED'
     or new.channel <> 'EMAIL'
     or new.status <> 'PENDING'
     or new.template_id is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_should_record := true;
  elsif tg_op = 'UPDATE' then
    v_should_record := old.status is distinct from new.status
      or old.template_id is distinct from new.template_id;
  end if;

  if not v_should_record then
    return new;
  end if;

  select operation_scope
    into v_scope
  from public.notification_template_configs
  where id = new.template_id;

  if found and v_scope is null then
    insert into public.ops_edge_failure_events(function_name, error_code, http_status)
    values ('email-send', 'NOTIFICATION_TEMPLATE_FALLBACK_USED', 500);
  end if;

  return new;
end;
$$;

revoke all on function public.record_notification_template_fallback_alert() from public, anon, authenticated;

drop trigger if exists trg_notification_template_fallback_alert on public.notification_delivery_logs;
create trigger trg_notification_template_fallback_alert
after insert or update of status, template_id on public.notification_delivery_logs
for each row
execute function public.record_notification_template_fallback_alert();
