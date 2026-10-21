-- Nome do modelo atual na Meta e da versão anterior, para limpar versões antigas:
-- a anterior ainda não aprovada sai da Meta assim que a nova é enviada; a anterior já
-- aprovada continua valendo até a nova ser aprovada e só então é excluída.
alter table public.whatsapp_template_submissions
  add column if not exists provider_template_name text null,
  add column if not exists previous_template_name text null,
  add column if not exists previous_template_id text null;

do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'whatsapp_template_submissions_names_check') then
    alter table public.whatsapp_template_submissions
      add constraint whatsapp_template_submissions_names_check check (
        (provider_template_name is null or provider_template_name ~ '^[a-z0-9_]{1,512}$')
        and (previous_template_name is null or previous_template_name ~ '^agenda_[a-z0-9_]{1,500}$')
        and (previous_template_id is null or previous_template_id ~ '^[0-9]{5,40}$')
      );
  end if;
end $mig$;
