-- Rewards: the "Cupom Rewards liberado" WhatsApp message goes out on the same scheduled
-- path as the rental balance message (decisions of 2026-10-21):
--   * the trigger is "N minutes after the reservation ends" (AFTER_END), set per message;
--   * at that time whatsapp-send issues the campaign coupon for the reservation (S4, one
--     coupon per reservation) and sends it in the same step: no message, no coupon;
--   * a reservation that is still unpaid waits: when it becomes PAID within 7 days of its
--     end, the message is queued again right away;
--   * a reservation change does not matter: issuance and delivery are keyed on the
--     reservation, not on its version.
-- Sending still needs the message to be active, approved by Meta and unchanged since, the
-- campaign to be ACTIVE and WHATSAPP_CUSTOMER_DISPATCH_ENABLED=true.

alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_whatsapp_dispatchable_events;
alter table public.notification_template_configs
  add constraint notification_template_configs_whatsapp_dispatchable_events
  check (
    channel <> 'WHATSAPP'
    or is_active = false
    or event_key in ('APPOINTMENT_APPROVED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED', 'APPOINTMENT_REMINDER', 'RENTAL_BALANCE_DUE', 'REWARDS_COUPON_ISSUED')
  );

-- Only "Cupom Rewards liberado" has a trigger, and only after the reservation ends.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_rewards_schedule;
alter table public.notification_template_configs
  add constraint notification_template_configs_rewards_schedule
  check (
    event_key not like 'REWARDS\_%'
    or schedule_mode = 'IMMEDIATE'
    or (event_key = 'REWARDS_COUPON_ISSUED' and schedule_mode = 'AFTER_END')
  );

create or replace function public.enqueue_rewards_coupon_after_payment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.financial_status is distinct from 'PAID'
    or old.financial_status is not distinct from 'PAID'
    or new.status not in ('CONFIRMED','COMPLETED')
    or new.core_end_at > now()
    or new.core_end_at <= now() - interval '7 days' then
    return new;
  end if;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
  select 'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',new.id,new.version,
    jsonb_build_object('event_key',t.event_key,'channel','WHATSAPP','template_id',t.id::text,
      'schedule_key',t.id::text || ':' || new.version::text || ':' || t.schedule_mode || ':' || t.schedule_offset_minutes::text,
      'reason','PAID'),
    greatest(now(), new.core_end_at + make_interval(mins => t.schedule_offset_minutes)),
    'rewards-paid:' || t.id::text || ':' || new.id::text
  from public.notification_template_configs t
  join public.services s on s.id = new.service_id and s.operation_scope = 'BLACKSHEEP'
  where t.event_key = 'REWARDS_COUPON_ISSUED'
    and t.channel = 'WHATSAPP'
    and t.schedule_mode = 'AFTER_END'
  on conflict (idempotency_key) do nothing;
  return new;
end;
$function$;

revoke all on function public.enqueue_rewards_coupon_after_payment() from public, anon, authenticated, service_role;

drop trigger if exists appointments_enqueue_rewards_coupon_after_payment on public.appointments;
create trigger appointments_enqueue_rewards_coupon_after_payment
after update of financial_status on public.appointments
for each row execute function public.enqueue_rewards_coupon_after_payment();

comment on function public.enqueue_rewards_coupon_after_payment() is
  'Queues the Rewards coupon message when a reservation that already ended becomes PAID within 7 days. whatsapp-send decides; the queue key keeps one job per message and reservation.';
