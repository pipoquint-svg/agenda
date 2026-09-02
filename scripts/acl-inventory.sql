\pset tuples_only on
\pset format unaligned
\pset fieldsep '\t'

with rel_objects as (
  select
    c.oid,
    case
      when c.relkind = 'S' then 'sequence'
      when c.relkind in ('v','m') then 'view'
      else 'table'
    end as object_kind,
    format('%I.%I', n.nspname, c.relname) as object_identity,
    pg_get_userbyid(c.relowner) as owner_role,
    coalesce(
      c.relacl,
      acldefault(case when c.relkind='S' then 'S'::"char" else 'r'::"char" end, c.relowner)
    ) as acl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public'
    and c.relkind in ('r','p','v','m','f','S')
),
rel_rows as (
  select
    o.object_kind,
    o.object_identity,
    o.owner_role,
    coalesce(grantee_role.rolname,'PUBLIC') as grantee,
    grantor_role.rolname as grantor,
    a.privilege_type,
    a.is_grantable
  from rel_objects o
  cross join lateral aclexplode(o.acl) a
  left join pg_roles grantee_role on grantee_role.oid=a.grantee
  join pg_roles grantor_role on grantor_role.oid=a.grantor
),
fn_objects as (
  select
    p.oid,
    'function'::text as object_kind,
    format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) as object_identity,
    pg_get_userbyid(p.proowner) as owner_role,
    coalesce(p.proacl, acldefault('f'::"char",p.proowner)) as acl
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
),
fn_rows as (
  select
    o.object_kind,
    o.object_identity,
    o.owner_role,
    coalesce(grantee_role.rolname,'PUBLIC') as grantee,
    grantor_role.rolname as grantor,
    a.privilege_type,
    a.is_grantable
  from fn_objects o
  cross join lateral aclexplode(o.acl) a
  left join pg_roles grantee_role on grantee_role.oid=a.grantee
  join pg_roles grantor_role on grantor_role.oid=a.grantor
),
all_rows as (
  select * from rel_rows
  union all
  select * from fn_rows
),
per_object as (
  select
    object_kind,
    object_identity,
    owner_role,
    count(*) as acl_row_count,
    encode(
      extensions.digest(
        owner_role || E'\n' || string_agg(
          format('%s|%s|%s|%s',grantee,grantor,privilege_type,is_grantable),
          E'\n' order by grantee,grantor,privilege_type,is_grantable
        ),
        'sha256'
      ),
      'hex'
    ) as acl_hash
  from all_rows
  group by object_kind,object_identity,owner_role
),
summary as (
  select
    object_kind,
    count(*) as object_count,
    sum(acl_row_count) as acl_row_count,
    encode(
      extensions.digest(
        string_agg(object_identity || '|' || owner_role || '|' || acl_hash,E'\n' order by object_identity),
        'sha256'
      ),
      'hex'
    ) as kind_hash
  from per_object
  group by object_kind
)
select 'SUMMARY',object_kind,'','','','',object_count::text || '|' || acl_row_count::text,kind_hash
from summary
union all
select 'OBJECT',object_kind,object_identity,owner_role,'','',acl_row_count::text,acl_hash
from per_object
union all
select 'ACL',object_kind,object_identity,owner_role,grantee,grantor,privilege_type,is_grantable::text
from all_rows
order by 1 desc,2,3,5,6,7,8;
