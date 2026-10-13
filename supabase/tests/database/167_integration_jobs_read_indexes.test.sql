begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(3);

select has_index('public', 'integration_jobs', 'integration_jobs_created_at_idx', array['created_at'],
  'integration_jobs has a created_at index for recent-failure and integrations reads');
select has_index('public', 'integration_jobs', 'integration_jobs_entity_id_idx', array['entity_id'],
  'integration_jobs has an entity_id index for reconciliation lookups');
select ok(
  not exists (
    select 1 from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indexrelid in ('public.integration_jobs_created_at_idx'::regclass, 'public.integration_jobs_entity_id_idx'::regclass)
      and a.attname in ('status', 'locked_at', 'attempt_count', 'processed_at', 'last_error')
  ),
  'new indexes never cover columns updated by workers (HOT updates preserved)');

select * from finish();
rollback;
