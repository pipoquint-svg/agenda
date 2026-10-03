-- Magic payment links for RENTAL_BALANCE_DUE.
-- The public secret is returned only to the email worker. Persistence keeps
-- exclusively its SHA-256 digest in appointment_access_tokens.

create or replace function public.service_issue_balance_collection_payment_token(
  p_collection_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_raw_token text;
  v_token_hash text;
  v_token_id uuid;
  v_balance numeric(12,2);
begin
  perform public.expire_due_balance_collections();

  select * into v_collection
  from public.appointment_balance_collections
  where id = p_collection_id
  for update;

  if not found or v_collection.status <> 'PENDING' or v_collection.expires_at <= v_now then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  v_balance := round(greatest(coalesce(
    (public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,
    0
  ), 0), 2);
  if v_balance <= 0.005 then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_ALREADY_PAID';
  end if;

  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');

  insert into public.appointment_access_tokens(
    appointment_id,
    token_hash,
    scope,
    expires_at,
    delivery_channel,
    destination_masked,
    balance_collection_id
  ) values (
    v_collection.appointment_id,
    v_token_hash,
    'PAY',
    v_collection.expires_at,
    'EMAIL',
    'balance-payment-link',
    v_collection.id
  )
  returning id into v_token_id;

  return jsonb_build_object(
    'access_token', v_raw_token,
    'token_id', v_token_id,
    'appointment_id', v_collection.appointment_id,
    'collection_id', v_collection.id,
    'expires_at', v_collection.expires_at,
    'amount', v_balance
  );
end;
$$;

create or replace function public.service_verify_balance_collection_payment_token(
  p_access_token text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_hash text;
  v_token public.appointment_access_tokens%rowtype;
  v_collection public.appointment_balance_collections%rowtype;
  v_balance numeric(12,2);
begin
  if p_access_token is null or btrim(p_access_token) !~ '^[0-9a-fA-F]{64}$' then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  perform public.expire_due_balance_collections();
  v_hash := encode(digest(btrim(p_access_token), 'sha256'), 'hex');

  select * into v_token
  from public.appointment_access_tokens
  where token_hash = v_hash
    and scope = 'PAY'
    and balance_collection_id is not null
  for update;

  if not found
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= v_now then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  select * into v_collection
  from public.appointment_balance_collections
  where id = v_token.balance_collection_id
  for update;

  if not found
     or v_collection.appointment_id <> v_token.appointment_id
     or v_collection.status <> 'PENDING'
     or v_collection.expires_at <= v_now then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  v_balance := round(greatest(coalesce(
    (public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,
    0
  ), 0), 2);
  if v_balance <= 0.005 then
    raise exception using errcode = 'P0001', message = 'BALANCE_COLLECTION_ALREADY_PAID';
  end if;

  update public.appointment_access_tokens
  set last_used_at = v_now
  where id = v_token.id;

  return jsonb_build_object(
    'access_token', btrim(p_access_token),
    'token_id', v_token.id,
    'appointment_id', v_collection.appointment_id,
    'collection_id', v_collection.id,
    'expires_at', v_collection.expires_at,
    'amount', v_balance
  );
end;
$$;

-- Defense in depth: creating a successor collection revokes every token tied
-- to an earlier collection for the same appointment, even if a legacy/manual
-- status transition failed to perform its normal revocation.
create or replace function public.revoke_superseded_balance_collection_tokens()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  update public.appointment_access_tokens t
  set revoked_at = coalesce(t.revoked_at, public.balance_collection_clock())
  from public.appointment_balance_collections c
  where c.id = t.balance_collection_id
    and c.appointment_id = new.appointment_id
    and c.id <> new.id
    and t.revoked_at is null;
  return new;
end;
$$;

drop trigger if exists trg_revoke_superseded_balance_collection_tokens
  on public.appointment_balance_collections;
create trigger trg_revoke_superseded_balance_collection_tokens
after insert on public.appointment_balance_collections
for each row execute function public.revoke_superseded_balance_collection_tokens();

revoke all on function public.service_issue_balance_collection_payment_token(uuid) from public, anon, authenticated;
revoke all on function public.service_verify_balance_collection_payment_token(text) from public, anon, authenticated;
revoke all on function public.revoke_superseded_balance_collection_tokens() from public, anon, authenticated, service_role;
grant execute on function public.service_issue_balance_collection_payment_token(uuid) to service_role;
grant execute on function public.service_verify_balance_collection_payment_token(text) to service_role;

-- The September 30 appointment-change trigger was created with PostgreSQL's
-- default PUBLIC execute grant. Restore the intended trigger-only boundary
-- while retaining the production-baseline service_role ACL.
revoke all on function public.enqueue_confirmation_email_on_confirmed_appointment_change()
  from public, anon, authenticated;
grant execute on function public.enqueue_confirmation_email_on_confirmed_appointment_change()
  to service_role;

comment on function public.service_issue_balance_collection_payment_token(uuid)
is 'Issues a 256-bit PAY-only balance token and persists only its SHA-256 hash.';
comment on function public.service_verify_balance_collection_payment_token(text)
is 'Validates a balance magic-link token against its collection and returns the authoritative current balance.';
