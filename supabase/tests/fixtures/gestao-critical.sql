begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(1);
select pass('Gestão E2E fixture moved to supabase/fixtures and is not executed as a pgTAP fixture');
select * from finish();

rollback;
