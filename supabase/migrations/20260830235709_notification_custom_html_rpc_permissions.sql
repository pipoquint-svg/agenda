-- Custom notification HTML RPCs are backend-only boundaries.
-- Match the privilege model of the existing notification RPCs: Edge Functions
-- call them with service_role after authenticating/authorizing the admin request.

revoke all on function public.service_admin_list_notification_templates_v2() from public, anon, authenticated;
revoke all on function public.service_admin_upsert_notification_template_v2(uuid,text,text,text,text,uuid,text,text,text,boolean,jsonb,integer,uuid[],uuid) from public, anon, authenticated;
revoke all on function public.resolve_notification_template_v2(text,text,text,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_list_notification_templates_v2() to service_role;
grant execute on function public.service_admin_upsert_notification_template_v2(uuid,text,text,text,text,uuid,text,text,text,boolean,jsonb,integer,uuid[],uuid) to service_role;
grant execute on function public.resolve_notification_template_v2(text,text,text,uuid) to service_role;
