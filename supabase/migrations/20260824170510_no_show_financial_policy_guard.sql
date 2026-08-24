-- NO_SHOW is considered a performed BlackSheep rental. It may owe and pay the remaining balance.
-- Keep CANCELLED_NO_SHOW only as a historical state for rows created before this policy decision.

create or replace function public.service_mark_balance_collection_cancelled(
  p_collection_id uuid,p_reason text,p_admin_id uuid default null,p_ip text default null,p_user_agent text default null,p_request_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_target text;
  v_action text;
begin
  if p_reason='SETTLED' then
    v_target:='CANCELLED_SETTLED';
    v_action:='BALANCE_COLLECTION_CANCELLED_SETTLED';
  elsif p_reason='PARTIAL' then
    v_target:='CANCELLED_PARTIAL_PAYMENT';
    v_action:='BALANCE_COLLECTION_CANCELLED_PARTIAL_PAYMENT';
  else
    raise exception using errcode='22023',message='BALANCE_COLLECTION_CANCEL_REASON_INVALID';
  end if;

  select * into v_collection
  from public.appointment_balance_collections
  where id=p_collection_id
  for update;
  if not found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_FOUND'; end if;
  if v_collection.status<>'PENDING' then
    return jsonb_build_object('collection_id',v_collection.id,'status',v_collection.status,'idempotent',true);
  end if;

  update public.appointment_balance_collections
  set status=v_target,updated_at=v_now
  where id=v_collection.id;

  update public.appointment_access_tokens
  set revoked_at=coalesce(revoked_at,v_now)
  where balance_collection_id=v_collection.id and revoked_at is null;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values(
    'APPOINTMENT',v_collection.appointment_id,v_action,
    jsonb_build_object('collection_id',v_collection.id,'ip_address',p_ip,'user_agent',p_user_agent),
    case when p_admin_id is null then 'SYSTEM' else 'OPERATION' end,
    p_admin_id,p_request_id
  );

  return jsonb_build_object('collection_id',v_collection.id,'appointment_id',v_collection.appointment_id,'status',v_target);
end;
$$;

revoke all on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) to service_role;
