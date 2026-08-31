revoke all on function public.blacksheep_sync_special_calendar_on_service_resource() from public;
revoke all on function public.blacksheep_sync_special_calendar_on_service_resource() from anon;
revoke all on function public.blacksheep_sync_special_calendar_on_service_resource() from authenticated;
grant execute on function public.blacksheep_sync_special_calendar_on_service_resource() to service_role;
