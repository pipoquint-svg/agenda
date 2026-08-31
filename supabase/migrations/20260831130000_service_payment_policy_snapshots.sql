-- ETAPA 1 — condições de pagamento configuráveis por serviço.
-- Apenas schema, captura/backfill e imutabilidade de snapshots.
-- Nenhuma regra de cobrança, cancelamento, estorno, crédito ou relatório é alterada aqui.

alter table public.services
  add column if not exists pix_discount_percent numeric(5,2),
  add column if not exists payment_mode text not null default 'MINIMUM_OR_FULL',
  add column if not exists card_max_installments integer not null default 6;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.services'::regclass
      and conname = 'services_pix_discount_percent_check'
  ) then
    alter table public.services
      add constraint services_pix_discount_percent_check
      check (pix_discount_percent is null or (pix_discount_percent >= 0 and pix_discount_percent <= 100));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.services'::regclass
      and conname = 'services_payment_mode_check'
  ) then
    alter table public.services
      add constraint services_payment_mode_check
      check (payment_mode in ('MINIMUM_OR_FULL','MINIMUM_ONLY','FULL_ONLY'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.services'::regclass
      and conname = 'services_card_max_installments_check'
  ) then
    alter table public.services
      add constraint services_card_max_installments_check
      check (card_max_installments between 1 and 12);
  end if;
end
$$;

comment on column public.services.pix_discount_percent is
  'Nullable override do desconto PIX. NULL herda o padrao global no momento da criacao da reserva.';
comment on column public.services.payment_mode is
  'Politica de pagamento online: MINIMUM_OR_FULL, MINIMUM_ONLY ou FULL_ONLY.';
comment on column public.services.card_max_installments is
  'Teto de parcelas de cartao para novas reservas; o provedor pode oferecer menos.';

alter table public.appointments
  add column if not exists payment_mode_snapshot text,
  add column if not exists pix_discount_percent_snapshot numeric(5,2),
  add column if not exists card_max_installments_snapshot integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_payment_mode_snapshot_check'
  ) then
    alter table public.appointments
      add constraint appointments_payment_mode_snapshot_check
      check (payment_mode_snapshot is null or payment_mode_snapshot in ('MINIMUM_OR_FULL','MINIMUM_ONLY','FULL_ONLY'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_pix_discount_percent_snapshot_check'
  ) then
    alter table public.appointments
      add constraint appointments_pix_discount_percent_snapshot_check
      check (pix_discount_percent_snapshot is null or (pix_discount_percent_snapshot >= 0 and pix_discount_percent_snapshot <= 100));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_card_max_installments_snapshot_check'
  ) then
    alter table public.appointments
      add constraint appointments_card_max_installments_snapshot_check
      check (card_max_installments_snapshot is null or card_max_installments_snapshot between 1 and 12);
  end if;
end
$$;

comment on column public.appointments.payment_mode_snapshot is
  'Politica de pagamento congelada no momento da criacao da reserva.';
comment on column public.appointments.pix_discount_percent_snapshot is
  'Percentual PIX efetivo congelado na reserva, ja resolvido de servico ou padrao global.';
comment on column public.appointments.card_max_installments_snapshot is
  'Teto de parcelas de cartao congelado no momento da criacao da reserva.';

create or replace function public.capture_appointment_commercial_configuration()
returns trigger
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
  v_type text;
  v_value numeric(12,2);
  v_legacy_percent numeric(5,2);
  v_target numeric(12,2);
  v_payment_mode text;
  v_effective_pix_discount numeric(5,2);
  v_card_max_installments integer;
begin
  -- Regra de sinal existente: preservada sem mudanca de significado.
  if new.checkout_minimum_payment_type_snapshot is null
     or new.checkout_minimum_payment_value_snapshot is null then
    select
      coalesce(s.checkout_minimum_payment_type,'PERCENT'),
      coalesce(s.checkout_minimum_payment_value,s.confirmation_percentage,os.default_confirmation_percentage,50)
    into v_type,v_value
    from public.services s
    cross join public.operation_settings os
    where s.id=new.service_id and os.id=1;

    if v_type is null or v_value is null then
      raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_CONFIGURATION_MISSING';
    end if;
    new.checkout_minimum_payment_type_snapshot:=v_type;
    new.checkout_minimum_payment_value_snapshot:=v_value;
  end if;

  -- Novas condicoes de pagamento. O desconto PIX e congelado como valor efetivo:
  -- override do servico -> padrao global -> 0 como fallback defensivo.
  if new.payment_mode_snapshot is null
     or new.pix_discount_percent_snapshot is null
     or new.card_max_installments_snapshot is null then
    select
      coalesce(s.payment_mode,'MINIMUM_OR_FULL'),
      coalesce(s.pix_discount_percent,os.pix_discount_percent,0),
      coalesce(s.card_max_installments,6)
    into
      v_payment_mode,
      v_effective_pix_discount,
      v_card_max_installments
    from public.services s
    cross join public.operation_settings os
    where s.id=new.service_id and os.id=1;

    if v_payment_mode is null
       or v_effective_pix_discount is null
       or v_card_max_installments is null then
      raise exception using errcode='P0001',message='APPOINTMENT_PAYMENT_CONFIGURATION_MISSING';
    end if;

    if new.payment_mode_snapshot is null then
      new.payment_mode_snapshot:=v_payment_mode;
    end if;
    if new.pix_discount_percent_snapshot is null then
      new.pix_discount_percent_snapshot:=v_effective_pix_discount;
    end if;
    if new.card_max_installments_snapshot is null then
      new.card_max_installments_snapshot:=v_card_max_installments;
    end if;
  end if;

  -- Snapshot percentual legado: preservado para compatibilidade das regras atuais.
  if new.confirmation_percentage_snapshot is null then
    if new.checkout_minimum_payment_type_snapshot='PERCENT' then
      v_legacy_percent:=new.checkout_minimum_payment_value_snapshot;
    elsif coalesce(new.commercial_value,0)>0 then
      v_target:=public.service_checkout_minimum_target(
        new.commercial_value,
        new.checkout_minimum_payment_type_snapshot,
        new.checkout_minimum_payment_value_snapshot
      );
      v_legacy_percent:=round(v_target*100/new.commercial_value,2);
    else
      v_legacy_percent:=100;
    end if;
    new.confirmation_percentage_snapshot:=least(greatest(v_legacy_percent,0),100);
  end if;
  return new;
end;
$function$;

create or replace function public.prevent_appointment_confirmation_snapshot_change()
returns trigger
language plpgsql
set search_path to 'public','pg_temp'
as $function$
begin
  if old.confirmation_percentage_snapshot is not null
     and new.confirmation_percentage_snapshot is distinct from old.confirmation_percentage_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE';
  end if;
  if old.checkout_minimum_payment_type_snapshot is not null
     and new.checkout_minimum_payment_type_snapshot is distinct from old.checkout_minimum_payment_type_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CHECKOUT_MINIMUM_SNAPSHOT_IMMUTABLE';
  end if;
  if old.checkout_minimum_payment_value_snapshot is not null
     and new.checkout_minimum_payment_value_snapshot is distinct from old.checkout_minimum_payment_value_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CHECKOUT_MINIMUM_SNAPSHOT_IMMUTABLE';
  end if;
  -- OLD NULL -> valor e permitido uma unica vez para migracao/normalizacao inicial.
  if old.payment_mode_snapshot is not null
     and new.payment_mode_snapshot is distinct from old.payment_mode_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_PAYMENT_MODE_SNAPSHOT_IMMUTABLE';
  end if;
  if old.pix_discount_percent_snapshot is not null
     and new.pix_discount_percent_snapshot is distinct from old.pix_discount_percent_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_PIX_DISCOUNT_SNAPSHOT_IMMUTABLE';
  end if;
  if old.card_max_installments_snapshot is not null
     and new.card_max_installments_snapshot is distinct from old.card_max_installments_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CARD_INSTALLMENTS_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$function$;

-- O trigger precisa listar explicitamente as novas colunas; apenas trocar a funcao
-- nao faria um UPDATE desses campos disparar a protecao existente.
drop trigger if exists appointments_protect_confirmation_snapshot on public.appointments;
create trigger appointments_protect_confirmation_snapshot
before update of
  confirmation_percentage_snapshot,
  checkout_minimum_payment_type_snapshot,
  checkout_minimum_payment_value_snapshot,
  payment_mode_snapshot,
  pix_discount_percent_snapshot,
  card_max_installments_snapshot
on public.appointments
for each row
execute function public.prevent_appointment_confirmation_snapshot_change();

-- Backfill dos servicos existentes exatamente conforme definido.
update public.services
set pix_discount_percent = null,
    payment_mode = 'MINIMUM_OR_FULL',
    card_max_installments = 6;

-- Congela nas reservas existentes as condicoes efetivas atuais.
-- O trigger de imutabilidade ja esta ativo aqui. Como OLD e NULL nos tres novos
-- snapshots, este preenchimento inicial e permitido; alteracoes posteriores nao sao.
update public.appointments a
set
  payment_mode_snapshot = coalesce(a.payment_mode_snapshot,s.payment_mode,'MINIMUM_OR_FULL'),
  pix_discount_percent_snapshot = coalesce(a.pix_discount_percent_snapshot,s.pix_discount_percent,os.pix_discount_percent,0),
  card_max_installments_snapshot = coalesce(a.card_max_installments_snapshot,s.card_max_installments,6)
from public.services s
cross join public.operation_settings os
where a.service_id=s.id
  and os.id=1
  and (
    a.payment_mode_snapshot is null
    or a.pix_discount_percent_snapshot is null
    or a.card_max_installments_snapshot is null
  );