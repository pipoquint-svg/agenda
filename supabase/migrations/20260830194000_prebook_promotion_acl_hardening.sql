revoke all on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) from public, anon, authenticated;
grant execute on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) to service_role;

revoke all on function public.normalize_customer_prebook_terms_global() from public, anon, authenticated;
revoke all on function public.enforce_pre_reservation_payment_confirmation() from public, anon, authenticated;
revoke all on function public.sync_pre_reservation_from_appointment_status() from public, anon, authenticated;
