begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(15);

select col_type_is('public','checkout_holds','applied_coupon_id','uuid','hold stores applied coupon id');
select col_type_is('public','checkout_holds','coupon_code_snapshot','text','hold stores coupon code snapshot');
select col_type_is('public','checkout_holds','coupon_discount','numeric','hold stores effective coupon discount');
select col_type_is('public','checkout_holds','pre_discount_value','numeric','hold stores subtotal before coupon');
select has_function('public','apply_checkout_coupon',array['text','text'],'coupon application RPC exists');
select has_function('public','clear_checkout_coupon',array['text'],'coupon clear RPC exists');
select has_function('public','get_checkout_coupon_state',array['text'],'coupon confirmation state RPC exists');
select has_function('public','get_checkout_applied_coupon_code',array['text'],'submit reads coupon from hold');
select ok(not has_function_privilege('anon','public.apply_checkout_coupon(text,text)','EXECUTE'),'anon cannot bypass checkout edge gateway');
select ok(not has_function_privilege('authenticated','public.apply_checkout_coupon(text,text)','EXECUTE'),'authenticated cannot bypass checkout edge gateway');
select ok(not has_function_privilege('anon','public.get_checkout_coupon_state(text)','EXECUTE'),'anon cannot read hold coupon state directly');
select ok(has_function_privilege('service_role','public.apply_checkout_coupon(text,text)','EXECUTE'),'service role can apply after gateway validation');
select ok(has_function_privilege('service_role','public.get_checkout_applied_coupon_code(text)','EXECUTE'),'service submit can read persisted coupon');
select has_function('public','service_admin_get_appointment',array['uuid'],'appointment detail wrapper remains available');
select ok(not has_function_privilege('authenticated','public.service_admin_get_appointment(uuid)','EXECUTE'),'appointment coupon detail remains behind admin edge');

select * from finish();
rollback;
