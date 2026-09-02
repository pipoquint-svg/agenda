\pset tuples_only on
\pset format unaligned

with tables as (
  select
    c.relname as table_name,
    c.relrowsecurity as rls_enabled,
    c.relforcerowsecurity as rls_forced
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r','p')
), policies as (
  select
    p.tablename as table_name,
    p.policyname,
    p.permissive,
    p.roles::text as roles,
    p.cmd,
    regexp_replace(btrim(coalesce(p.qual,'<NULL>')), E'\\s+', ' ', 'g') as qual,
    regexp_replace(btrim(coalesce(p.with_check,'<NULL>')), E'\\s+', ' ', 'g') as with_check
  from pg_policies p
  where p.schemaname = 'public'
), canonical as (
  select format('TABLE|%s|%s|%s', table_name, rls_enabled::text, rls_forced::text) as line
  from tables
  union all
  select format(
    'POLICY|%s|%s|%s|%s|%s|%s|%s',
    table_name, policyname, permissive, roles, cmd, qual, with_check
  )
  from policies
)
select line
from canonical
order by line;
