-- Restore bounded automatic balance issuance.
-- Production automatically issues balance collections only for recently-started
-- BlackSheep services. Older unresolved balances require explicit operator review.
-- INVOICE reservations remain excluded from automatic collection.

create or replace function public.enqueue_due_rental_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_row record;
  v_count integer:=0;
begin
  perform public.expire_due_balance_collections();

  for v_row in
    select a.id
    from public.appointments a
    join public.services s on s.id=a.service_id
    cross join lateral (
      select public.get_appointment_financial_summary(a.id) as summary
    ) fin
    where s.operation_scope='BLACKSHEEP'
      and a.status in ('CONFIRMED','COMPLETED','NO_SHOW')
      and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
      and a.start_at<=v_now
      and a.start_at>v_now-interval '24 hours'
      and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005
      and not exists (
        select 1
        from public.appointment_balance_collections c
        where c.appointment_id=a.id
      )
    order by a.start_at,a.id
    for update of a skip locked
  loop
    begin
      perform public.create_balance_collection(v_row.id,'AUTO_START',null);
      v_count:=v_count+1;
    exception when others then
      if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE') then
        raise;
      end if;
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.enqueue_due_rental_balance_collections() from public,anon,authenticated;
grant execute on function public.enqueue_due_rental_balance_collections() to service_role;
