revoke execute on function public.service_client_cancel_appointment_evidenced_v2(uuid,text,text,timestamptz,inet,text,text,text) from public;
revoke execute on function public.service_client_cancel_appointment_evidenced_v2(uuid,text,text,timestamptz,inet,text,text,text) from anon;
revoke execute on function public.service_client_cancel_appointment_evidenced_v2(uuid,text,text,timestamptz,inet,text,text,text) from authenticated;
grant execute on function public.service_client_cancel_appointment_evidenced_v2(uuid,text,text,timestamptz,inet,text,text,text) to service_role;
