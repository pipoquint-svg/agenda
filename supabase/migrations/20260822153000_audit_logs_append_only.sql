-- Frente 3 pós-auditoria: imutabilidade da trilha de auditoria.
-- Política de retenção da V1: INDEFINITE por padrão, sem expurgo automático.
-- Qualquer expurgo é uma operação excepcional de manutenção, fora dos papéis da aplicação,
-- com cutoff e motivo explícitos e registro prévio em trilha separada append-only.

create table public.audit_retention_policy (
  id smallint primary key check (id = 1),
  retention_mode text not null check (retention_mode in ('INDEFINITE')),
  retention_days integer,
  automatic_purge boolean not null,
  created_at timestamptz not null default now(),
  check (retention_mode <> 'INDEFINITE' or retention_days is null),
  check (retention_mode <> 'INDEFINITE' or automatic_purge = false)
);

insert into public.audit_retention_policy(id, retention_mode, retention_days, automatic_purge)
values (1, 'INDEFINITE', null, false);

create table public.audit_purge_runs (
  id uuid primary key default gen_random_uuid(),
  cutoff_before timestamptz not null,
  reason text not null check (length(btrim(reason)) >= 10),
  requested_by text not null check (length(btrim(requested_by)) >= 3),
  rows_planned bigint not null check (rows_planned >= 0),
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  'Append-only application audit trail. Retention is INDEFINITE by default. UPDATE, DELETE and TRUNCATE are forbidden outside the dedicated maintenance purge path.';
comment on table public.audit_purge_runs is
  'Append-only evidence of exceptional audit-log purges. A record is inserted before deletion in the same transaction.';
comment on table public.audit_retention_policy is
  'V1 audit retention policy. INDEFINITE means no automatic purge; any future policy change requires an explicit migration/decision.';

-- Default privileges are not enough for an append-only guarantee. Remove destructive
-- privileges from every application-facing role, including service_role.
revoke update, delete, truncate on table public.audit_logs from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.audit_purge_runs from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.audit_retention_policy from public, anon, authenticated, service_role;

create or replace function public.reject_audit_log_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- The only destructive path allowed for audit_logs is the dedicated maintenance
  -- function below. It runs as the database owner and sets a transaction-local guard.
  if tg_table_name = 'audit_logs'
     and tg_op = 'DELETE'
     and current_user = 'postgres'
     and current_setting('app.audit_purge_context', true) = 'DEDICATED_MAINTENANCE_PURGE' then
    return old;
  end if;

  raise exception using errcode = '42501', message = 'AUDIT_TRAIL_APPEND_ONLY';
end;
$$;

create trigger audit_logs_reject_update_delete
before update or delete on public.audit_logs
for each row execute function public.reject_audit_log_mutation();

create trigger audit_logs_reject_truncate
before truncate on public.audit_logs
for each statement execute function public.reject_audit_log_mutation();

create trigger audit_purge_runs_reject_update_delete
before update or delete on public.audit_purge_runs
for each row execute function public.reject_audit_log_mutation();

create trigger audit_purge_runs_reject_truncate
before truncate on public.audit_purge_runs
for each statement execute function public.reject_audit_log_mutation();

create trigger audit_retention_policy_reject_update_delete
before update or delete on public.audit_retention_policy
for each row execute function public.reject_audit_log_mutation();

create trigger audit_retention_policy_reject_truncate
before truncate on public.audit_retention_policy
for each statement execute function public.reject_audit_log_mutation();

create or replace function public.maintenance_purge_audit_logs(
  p_before timestamptz,
  p_reason text,
  p_requested_by text
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  if p_before is null then
    raise exception using errcode = '22004', message = 'AUDIT_PURGE_CUTOFF_REQUIRED';
  end if;
  if p_before >= now() then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_CUTOFF_MUST_BE_IN_PAST';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_REASON_REQUIRED';
  end if;
  if p_requested_by is null or length(btrim(p_requested_by)) < 3 then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_REQUESTOR_REQUIRED';
  end if;

  select count(*) into v_count
  from public.audit_logs
  where created_at < p_before;

  -- Evidence is written before deletion. Both operations are in the same transaction:
  -- if deletion fails, the evidence insert rolls back too.
  insert into public.audit_purge_runs(cutoff_before, reason, requested_by, rows_planned)
  values (p_before, btrim(p_reason), btrim(p_requested_by), v_count);

  perform set_config('app.audit_purge_context', 'DEDICATED_MAINTENANCE_PURGE', true);

  delete from public.audit_logs
  where created_at < p_before;

  perform set_config('app.audit_purge_context', '', true);
  return v_count;
exception
  when others then
    perform set_config('app.audit_purge_context', '', true);
    raise;
end;
$$;

-- This is deliberately NOT an application API. Only the database owner/maintenance
-- context may execute it. Application OWNER is an application role, not database owner.
revoke all on function public.maintenance_purge_audit_logs(timestamptz,text,text) from public, anon, authenticated, service_role;
revoke all on function public.reject_audit_log_mutation() from public, anon, authenticated, service_role;
