-- Preserve historical/unclassified catalog rows while enforcing operation integrity
-- whenever either side is explicitly classified. Admin RPCs still require a classified
-- category and operation for all new catalog writes.

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;

  -- Legacy rows created before operation scoping may remain unclassified together.
  -- Once either side is classified, both must agree.
  if v_category_scope is null and new.operation_scope is null then
    return new;
  end if;

  if v_category_scope is null or new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;

  return new;
end;
$$;
