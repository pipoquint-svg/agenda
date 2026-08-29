create or replace function public.service_admin_anonymize_customer(
  p_customer_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
  v_placeholder text;
begin
  if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  select * into v_customer from public.customers where id=p_customer_id for update;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if v_customer.anonymized_at is not null then
    return public.service_admin_get_customer_commercial_profile(p_customer_id);
  end if;

  -- Identity history is retained only as irreversible equality fingerprints for
  -- the existing anti-evasion/access-control policy; no plaintext identifier is
  -- kept in customer_identity_keys.
  v_placeholder := 'Cliente anonimizado '||left(replace(p_customer_id::text,'-',''),8);

  update public.customers set
    name=v_placeholder,
    legal_name=null,
    cpf_cnpj=null,
    email=null,
    phone=null,
    notes=null,
    address=null,
    birth_date=null,
    anonymized_at=now(),
    updated_at=now()
  where id=p_customer_id;

  delete from public.kommo_customer_links where customer_id=p_customer_id;
  delete from public.customer_prebook_authorized_services where customer_id=p_customer_id;
  update public.customer_commercial_terms set is_active=false,updated_at=now() where customer_id=p_customer_id;

  update public.legacy_customer_sources set
    raw_snapshot=jsonb_build_object('lgpd_anonymized',true),
    match_method='UNMATCHED',
    match_confidence='NONE',
    conflict_code=null,
    updated_at=now()
  where customer_id=p_customer_id;

  update public.notification_delivery_logs set
    recipient_hash=encode(extensions.digest('notification-lgpd:'||id::text,'sha256'),'hex'),
    recipient_masked='***',
    payload_snapshot='{}'::jsonb,
    updated_at=now()
  where customer_id=p_customer_id;

  -- Customer audit metadata (who/when/action) is retained, but any old snapshot
  -- that may have copied name, email, phone, address or birth date is scrubbed.
  update public.audit_logs set
    before_json=jsonb_build_object('lgpd_anonymized',true),
    after_json=jsonb_build_object('lgpd_anonymized',true)
  where entity_type='CUSTOMER' and entity_id=p_customer_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CUSTOMER',p_customer_id,'CUSTOMER_ANONYMIZED',null,
    jsonb_build_object(
      'pii_removed',true,
      'financial_history_preserved',true,
      'identity_fingerprints_retained',true
    ),'ADMIN_UI');

  return public.service_admin_get_customer_commercial_profile(p_customer_id);
end;
$$;

revoke all on function public.service_admin_anonymize_customer(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_anonymize_customer(uuid,uuid) to service_role;
