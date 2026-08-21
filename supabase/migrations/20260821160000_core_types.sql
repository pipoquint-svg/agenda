create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create domain public.resource_type as text
  check (value in ('PHYSICAL', 'PERSON'));

create domain public.allocation_type as text
  check (value in ('APPOINTMENT', 'CHECKOUT_HOLD', 'MANUAL_BLOCK', 'EXTERNAL_BLOCK'));

create domain public.allocation_status as text
  check (value in (
    'HELD',
    'AWAITING_PAYMENT',
    'CONFIRMED',
    'BLOCKED',
    'EXTERNAL_ACTIVE',
    'IGNORED_BY_ADMIN',
    'RELEASED',
    'CANCELLED',
    'EXPIRED',
    'COMPLETED'
  ));

create domain public.appointment_status as text
  check (value in (
    'DRAFT',
    'HELD',
    'AWAITING_PAYMENT',
    'CONFIRMED',
    'COMPLETED',
    'CANCELLED',
    'EXPIRED',
    'NO_SHOW'
  ));

create domain public.financial_status as text
  check (value in (
    'NOT_STARTED',
    'PENDING',
    'PARTIALLY_PAID',
    'PAID',
    'UNPAID_AUTHORIZED',
    'REJECTED',
    'EXPIRED',
    'REFUNDED',
    'PARTIALLY_REFUNDED'
  ));

create table public.operation_settings (
  id smallint primary key default 1 check (id = 1),
  operation_name text not null default 'BlackSheep Agenda',
  timezone text not null default 'America/Sao_Paulo',
  default_currency text not null default 'BRL',
  checkout_hold_minutes integer not null default 10 check (checkout_hold_minutes > 0),
  payment_hold_minutes integer not null default 30 check (payment_hold_minutes > 0),
  agency_hold_minutes integer not null default 360 check (agency_hold_minutes > 0),
  default_confirmation_percentage numeric(5,2) not null default 50 check (default_confirmation_percentage > 0 and default_confirmation_percentage <= 100),
  pix_discount_percent numeric(5,2) not null default 5 check (pix_discount_percent >= 0 and pix_discount_percent <= 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.operation_settings (id)
values (1)
on conflict (id) do nothing;
