create or replace function public.emit_missing_notification_template_ops_alert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.job_type = 'APPOINTMENT_CONFIRMED_MESSAGE'
     and coalesce(new.last_error, '') like '%NOTIFICATION_TEMPLATE_NOT_FOUND%'
     and coalesce(old.last_error, '') not like '%NOTIFICATION_TEMPLATE_NOT_FOUND%'
  then
    insert into public.ops_edge_failure_events(function_name, error_code, http_status)
    values ('email-send', 'NOTIFICATION_TEMPLATE_NOT_FOUND', 500);
  end if;
  return new;
end;
$$;

revoke all on function public.emit_missing_notification_template_ops_alert() from public;

create or replace trigger integration_jobs_missing_template_ops_alert
  after update of last_error on public.integration_jobs
  for each row
  execute function public.emit_missing_notification_template_ops_alert();
