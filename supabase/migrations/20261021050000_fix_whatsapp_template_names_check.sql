-- Corrige a regra dos nomes das versões: o PostgreSQL só aceita repetição até 255 em
-- expressões regulares ({1,512} quebrava qualquer gravação nessas colunas). O tamanho
-- passa a ser conferido com char_length.
alter table public.whatsapp_template_submissions
  drop constraint if exists whatsapp_template_submissions_names_check;
alter table public.whatsapp_template_submissions
  add constraint whatsapp_template_submissions_names_check check (
    (provider_template_name is null
      or (provider_template_name ~ '^[a-z0-9_]+$' and char_length(provider_template_name) <= 512))
    and (previous_template_name is null
      or (previous_template_name ~ '^agenda_[a-z0-9_]+$' and char_length(previous_template_name) <= 512))
    and (previous_template_id is null or previous_template_id ~ '^[0-9]{5,40}$')
  );
