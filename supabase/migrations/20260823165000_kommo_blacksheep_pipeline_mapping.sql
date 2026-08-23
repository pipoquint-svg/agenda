alter table public.kommo_integration_settings
  add column if not exists stage_initial_contact_id bigint;

alter table public.kommo_integration_settings
  drop constraint if exists kommo_integration_settings_stage_initial_contact_id_check;

alter table public.kommo_integration_settings
  add constraint kommo_integration_settings_stage_initial_contact_id_check
  check (stage_initial_contact_id is null or stage_initial_contact_id > 0);

update public.kommo_integration_settings
set account_subdomain = 'pierriquintproducoes',
    pipeline_id = 11507124,
    stage_initial_contact_id = 88360028,
    stage_awaiting_payment_id = 88360032,
    stage_confirmed_id = 88360036,
    stage_rescheduled_id = 95038752,
    stage_completed_id = 95038756,
    stage_cancelled_id = 96091804,
    stage_no_show_id = 96091808,
    stage_expired_id = 110702983,
    updated_at = now()
where id = 1;

comment on column public.kommo_integration_settings.stage_initial_contact_id is
  'BlackSheep pre-booking CRM stage. Existing WhatsApp leads in this stage may be reused by Agenda only after exact phone identity match.';
