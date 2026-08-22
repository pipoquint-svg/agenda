-- Frente 4 pós-auditoria: rate limiting distribuído para superfícies públicas.
-- O contador autoritativo fica no PostgreSQL e é compartilhado entre todas as instâncias Edge.
-- Chaves brutas (IP/fingerprint) nunca são persistidas; somente SHA-256.

create table public.public_rate_limit_buckets (
  scope text not null,
  key_hash text not null,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (scope, key_hash),
  check (scope ~ '^[A-Z0-9_]{3,64}$'),
  check (key_hash ~ '^[0-9a-f]{64}$')
);

create index public_rate_limit_buckets_updated_idx
  on public.public_rate_limit_buckets(updated_at);

comment on table public.public_rate_limit_buckets is
  'Distributed fixed-window counters for public abuse protection. Stores only hashed client keys.';

create or replace function public.service_consume_public_rate_limit_at(
  p_scope text,
  p_client_key text,
  p_limit integer,
  p_window_seconds integer,
  p_now timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_scope text := upper(btrim(coalesce(p_scope,'')));
  v_key text := btrim(coalesce(p_client_key,''));
  v_key_hash text;
  v_bucket public.public_rate_limit_buckets%rowtype;
  v_reset_at timestamptz;
begin
  if v_scope !~ '^[A-Z0-9_]{3,64}$' then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_SCOPE_INVALID';
  end if;
  if length(v_key) < 3 or length(v_key) > 1000 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_KEY_INVALID';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_VALUE_INVALID';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_WINDOW_INVALID';
  end if;
  if p_now is null then
    raise exception using errcode = '22004', message = 'RATE_LIMIT_CLOCK_REQUIRED';
  end if;

  v_key_hash := encode(digest(v_key, 'sha256'), 'hex');

  insert into public.public_rate_limit_buckets(scope,key_hash,window_started_at,request_count,updated_at)
  values (v_scope,v_key_hash,p_now,0,p_now)
  on conflict (scope,key_hash) do nothing;

  select * into v_bucket
  from public.public_rate_limit_buckets
  where scope = v_scope and key_hash = v_key_hash
  for update;

  v_reset_at := v_bucket.window_started_at + make_interval(secs => p_window_seconds);

  if p_now >= v_reset_at then
    update public.public_rate_limit_buckets
    set window_started_at = p_now,
        request_count = 1,
        updated_at = p_now
    where scope = v_scope and key_hash = v_key_hash;

    return jsonb_build_object(
      'allowed', true,
      'count', 1,
      'limit', p_limit,
      'reset_at', p_now + make_interval(secs => p_window_seconds)
    );
  end if;

  if v_bucket.request_count >= p_limit then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  update public.public_rate_limit_buckets
  set request_count = request_count + 1,
      updated_at = p_now
  where scope = v_scope and key_hash = v_key_hash;

  return jsonb_build_object(
    'allowed', true,
    'count', v_bucket.request_count + 1,
    'limit', p_limit,
    'reset_at', v_reset_at
  );
end;
$$;

create or replace function public.service_consume_public_rate_limit(
  p_scope text,
  p_client_key text,
  p_limit integer,
  p_window_seconds integer
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.service_consume_public_rate_limit_at(
    p_scope, p_client_key, p_limit, p_window_seconds, clock_timestamp()
  );
$$;

-- Request metadata used only as a defense-in-depth path for successful direct hold creation.
-- Edge Functions remain the primary public gateway and consume the same distributed counter
-- in a separate transaction, which also counts malformed/invalid attempts.
create or replace function public.public_request_client_key()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_raw text := current_setting('request.headers', true);
  v_headers jsonb := '{}'::jsonb;
  v_ip text;
  v_ua text;
begin
  if v_raw is not null and btrim(v_raw) <> '' then
    begin
      v_headers := v_raw::jsonb;
    exception when others then
      v_headers := '{}'::jsonb;
    end;
  end if;

  v_ip := nullif(btrim(coalesce(
    v_headers->>'cf-connecting-ip',
    split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1),
    v_headers->>'x-real-ip',
    ''
  )), '');
  v_ua := nullif(left(btrim(coalesce(v_headers->>'user-agent','')), 200), '');

  return case
    when v_ip is not null then 'ip:' || v_ip
    when v_ua is not null then 'missing-ip:ua:' || v_ua
    else 'missing-ip:unknown'
  end;
end;
$$;

create or replace function public.public_request_jwt_role()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_raw text := current_setting('request.jwt.claims', true);
  v_claims jsonb := '{}'::jsonb;
  v_role text;
begin
  if v_raw is not null and btrim(v_raw) <> '' then
    begin
      v_claims := v_raw::jsonb;
    exception when others then
      v_claims := '{}'::jsonb;
    end;
  end if;
  v_role := nullif(v_claims->>'role','');
  return coalesce(v_role, nullif(current_setting('request.jwt.claim.role', true),''), '');
end;
$$;

create or replace function public.enforce_direct_public_hold_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.public_request_jwt_role() in ('anon','authenticated') then
    perform public.service_consume_public_rate_limit_at(
      'CHECKOUT_HOLD_CREATE',
      public.public_request_client_key(),
      30,
      600,
      clock_timestamp()
    );
  end if;
  return new;
end;
$$;

create trigger checkout_holds_public_rate_limit_trg
before insert on public.checkout_holds
for each row execute function public.enforce_direct_public_hold_rate_limit();

-- Public write/token RPCs are moved behind Edge gateways so the distributed counter
-- commits in its own transaction before the authoritative operation. This prevents
-- invalid-token errors from rolling the counter back and blocks direct bypass.
revoke execute on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from anon, authenticated;

grant execute on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) to service_role;
grant execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) to service_role;
grant execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) to service_role;
grant execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to service_role;

revoke execute on function public.public_get_checkout_context(text) from anon, authenticated;
revoke execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) from anon, authenticated;
revoke execute on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) from anon, authenticated;
revoke execute on function public.public_list_checkout_hour_packages(text) from anon, authenticated;
revoke execute on function public.public_select_checkout_hour_package(text,uuid) from anon, authenticated;
revoke execute on function public.public_clear_checkout_hour_package(text) from anon, authenticated;
revoke execute on function public.get_checkout_hold_resume_context(text) from anon, authenticated;

grant execute on function public.public_get_checkout_context(text) to service_role;
grant execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) to service_role;
grant execute on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) to service_role;
grant execute on function public.public_list_checkout_hour_packages(text) to service_role;
grant execute on function public.public_select_checkout_hour_package(text,uuid) to service_role;
grant execute on function public.public_clear_checkout_hour_package(text) to service_role;
grant execute on function public.get_checkout_hold_resume_context(text) to service_role;

-- Only backend service code can consume counters explicitly. The clock-injectable helper
-- remains database-internal for deterministic tests.
revoke all on function public.service_consume_public_rate_limit_at(text,text,integer,integer,timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.service_consume_public_rate_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.service_consume_public_rate_limit(text,text,integer,integer) to service_role;
revoke all on function public.public_request_client_key() from public, anon, authenticated, service_role;
revoke all on function public.public_request_jwt_role() from public, anon, authenticated, service_role;
revoke all on function public.enforce_direct_public_hold_rate_limit() from public, anon, authenticated, service_role;

revoke all on table public.public_rate_limit_buckets from public, anon, authenticated;
grant select, insert, update on table public.public_rate_limit_buckets to service_role;
