-- A private invitation may only be (re)issued while the shared slot is truly
-- open. Once another family has claimed the slot, rotating a different invite
-- would produce a valid-looking WhatsApp link that cannot reserve anything.

create or replace function public.service_admin_rotate_waitlist_private_invite(
  p_invite_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_invite public.waitlist_private_invites%rowtype;
  v_slot public.waitlist_private_slots%rowtype;
  v_entry public.service_waitlist_entries%rowtype;
  v_raw_token text;
begin
  if not public.service_admin_has_permission(p_admin_id,'WAITLIST_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_waitlist_private_slots();

  select * into v_invite
  from public.waitlist_private_invites
  where id=p_invite_id
  for update;
  if not found then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_NOT_FOUND';
  end if;

  select * into v_slot
  from public.waitlist_private_slots
  where id=v_invite.slot_id
  for update;

  if v_slot.status <> 'OPEN' or v_slot.expires_at<=now() or v_slot.start_at<=now() then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_SLOT_NOT_AVAILABLE';
  end if;

  if v_invite.checkout_hold_id is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_IN_PROGRESS';
  end if;

  if v_invite.appointment_id is not null then
    raise exception using errcode='P0001',message='WAITLIST_PRIVATE_INVITE_ALREADY_USED';
  end if;

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  update public.waitlist_private_invites
  set token_hash=encode(digest(v_raw_token,'sha256'),'hex'),
      expires_at=v_slot.expires_at,
      revoked_at=null,
      updated_at=now()
  where id=v_invite.id;

  select * into v_entry
  from public.service_waitlist_entries
  where id=v_invite.waitlist_entry_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(
    p_admin_id,
    'WAITLIST_PRIVATE_INVITE',
    v_invite.id,
    'WAITLIST_PRIVATE_INVITE_TOKEN_ROTATED',
    jsonb_build_object('slot_id',v_slot.id),
    'ADMIN_UI'
  );

  return jsonb_build_object(
    'invite_id',v_invite.id,
    'name',v_entry.name,
    'whatsapp',v_entry.whatsapp,
    'email',v_entry.email,
    'access_token',v_raw_token,
    'expires_at',v_slot.expires_at
  );
end;
$function$;

revoke all on function public.service_admin_rotate_waitlist_private_invite(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_rotate_waitlist_private_invite(uuid,uuid) to service_role;
