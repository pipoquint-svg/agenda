-- WhatsApp-only fields of a notification draft: Meta category, message
-- validity, header, footer and variable samples. Kept beside notification_template_configs so
-- the e-mail editor and its versioned upsert RPC stay unchanged. Closed to
-- browser roles; admin-notifications writes it with the service role.

create table public.notification_whatsapp_settings (
  template_id uuid primary key references public.notification_template_configs(id) on delete cascade,
  category text not null default 'UTILITY',
  header_text text null,
  footer_text text null,
  ttl_seconds integer null,
  -- Sample value per variable, shown to Meta's reviewers.
  variable_examples jsonb not null default '{}'::jsonb,
  updated_by_admin_id uuid null,
  updated_at timestamptz not null default now(),
  constraint notification_whatsapp_settings_category_check check (category in ('UTILITY', 'MARKETING')),
  constraint notification_whatsapp_settings_examples_check check (
    jsonb_typeof(variable_examples) = 'object' and octet_length(variable_examples::text) <= 16384
  ),
  constraint notification_whatsapp_settings_header_check check (header_text is null or char_length(header_text) between 1 and 60),
  constraint notification_whatsapp_settings_footer_check check (
    footer_text is null or (char_length(footer_text) between 1 and 60 and footer_text !~ '\{\{')
  ),
  -- Meta accepts a custom validity only for utility templates, from 30 s to 12 h.
  constraint notification_whatsapp_settings_ttl_check check (
    ttl_seconds is null or (category = 'UTILITY' and ttl_seconds between 30 and 43200)
  )
);

alter table public.notification_whatsapp_settings enable row level security;

revoke all on table public.notification_whatsapp_settings from public, anon, authenticated;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.notification_whatsapp_settings to service_role;

comment on table public.notification_whatsapp_settings is
  'WhatsApp category, validity, header and footer of a notification draft. Contains no credentials and sends nothing.';
