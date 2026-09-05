-- Pessoas por serviço: separa mínimo permitido, pessoas incluídas e máximo permitido.
-- O adicional é cobrado somente sobre pessoas acima de included_people.
-- maximum_people permanece como teto real da reserva.

alter table public.services
  add column included_people integer;

update public.services
   set included_people = maximum_people
 where included_people is null;

alter table public.services
  alter column included_people set default 1,
  alter column included_people set not null;

alter table public.services
  add constraint services_included_people_range_check
  check (included_people >= minimum_people and included_people <= maximum_people);

do $migration$
declare
  v_def text;
  v_new_def text;
begin
  -- 1) Quote FIXED: adicional apenas acima de included_people.
  select pg_get_functiondef('public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$v_price[[:space:]]*:=[[:space:]]*v_after_day_time[[:space:]]*\+[[:space:]]*greatest\(p_people_count[[:space:]]*-[[:space:]]*v_service\.minimum_people[[:space:]]*,[[:space:]]*0\)[[:space:]]*\*[[:space:]]*v_service\.price_per_extra_person[[:space:]]*;$rx$,
    $repl$v_price:=v_after_day_time + greatest(p_people_count-v_service.included_people,0)*v_service.price_per_extra_person;$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base pricing';
  end if;
  v_def := v_new_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$'people_adjustment'[[:space:]]*,[[:space:]]*round\(v_people_adjustment[[:space:]]*,[[:space:]]*2\)[[:space:]]*,[[:space:]]*'extras_total'$rx$,
    $repl$'people_adjustment',round(v_people_adjustment,2),'extra_people_count',greatest(p_people_count-v_service.included_people,0),'extra_people_amount',round(greatest(p_people_count-v_service.included_people,0)*v_service.price_per_extra_person,2),'included_people',v_service.included_people,'maximum_people',v_service.maximum_people,'price_per_extra_person',v_service.price_per_extra_person,'extras_total'$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base metadata';
  end if;
  execute v_new_def;

  -- 2) Quote BLOCKS: mesma semântica. O teto máximo continua sendo validado
  -- pela função original; apenas o cálculo do excedente é acrescentado.
  select pg_get_functiondef('public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$v_price[[:space:]]*:=[[:space:]]*v_after_day_time[[:space:]]*;[[:space:]]*for v_rule in select value from jsonb_array_elements\(v_people_rules\)$rx$,
    $repl$v_price := v_after_day_time
      + greatest(p_people_count - v_service.included_people, 0) * v_service.price_per_extra_person;

    for v_rule in select value from jsonb_array_elements(v_people_rules)$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch pricing';
  end if;
  v_def := v_new_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$'people_adjustment'[[:space:]]*,[[:space:]]*round\(v_people_adjustment[[:space:]]*,[[:space:]]*2\)[[:space:]]*,[[:space:]]*'extras_total'$rx$,
    $repl$'people_adjustment', round(v_people_adjustment,2),
      'extra_people_count', greatest(p_people_count - v_service.included_people, 0),
      'extra_people_amount', round(greatest(p_people_count - v_service.included_people, 0) * v_service.price_per_extra_person, 2),
      'included_people', v_service.included_people,
      'maximum_people', v_service.maximum_people,
      'price_per_extra_person', v_service.price_per_extra_person,
      'extras_total'$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch metadata';
  end if;
  execute v_new_def;

  -- 3) Catálogo público: configuração + opções autoritativas de pessoas.
  select pg_get_functiondef('public.public_get_booking_page(text)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$'minimum_people'[[:space:]]*,[[:space:]]*s\.minimum_people[[:space:]]*,[[:space:]]*'maximum_people'[[:space:]]*,[[:space:]]*s\.maximum_people[[:space:]]*,[[:space:]]*'requires_terms'$rx$,
    $repl$'minimum_people',s.minimum_people,'included_people',s.included_people,'maximum_people',s.maximum_people,'price_per_extra_person',s.price_per_extra_person,'people_options',coalesce((select jsonb_agg(jsonb_build_object('count',g,'included',(g<=s.included_people),'extra_people_count',greatest(g-s.included_people,0),'extra_people_amount',round(greatest(g-s.included_people,0)*s.price_per_extra_person,2)) order by g) from generate_series(s.minimum_people,s.maximum_people) g),'[]'::jsonb),'requires_terms'$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: public_get_booking_page';
  end if;
  execute v_new_def;

  -- 4) Read model administrativo passa a expor included_people.
  select pg_get_functiondef('public.service_admin_list_service_settings()'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$'minimum_people'[[:space:]]*,[[:space:]]*s\.minimum_people[[:space:]]*,[[:space:]]*'maximum_people'[[:space:]]*,[[:space:]]*s\.maximum_people[[:space:]]*,[[:space:]]*'price_per_extra_person'$rx$,
    $repl$'minimum_people',s.minimum_people,'included_people',s.included_people,'maximum_people',s.maximum_people,'price_per_extra_person'$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: service_admin_list_service_settings';
  end if;
  execute v_new_def;

  -- 5) Duplicação de serviço preserva included_people.
  select pg_get_functiondef('public.service_admin_duplicate_service_audited(uuid,text,text,uuid)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$minimum_people[[:space:]]*,[[:space:]]*maximum_people[[:space:]]*,[[:space:]]*minimum_booking_notice_minutes$rx$,
    $repl$minimum_people, included_people, maximum_people, minimum_booking_notice_minutes$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: duplicate columns';
  end if;
  v_def := v_new_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$v_source\.minimum_people[[:space:]]*,[[:space:]]*v_source\.maximum_people[[:space:]]*,[[:space:]]*v_source\.minimum_booking_notice_minutes$rx$,
    $repl$v_source.minimum_people, v_source.included_people, v_source.maximum_people, v_source.minimum_booking_notice_minutes$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: duplicate values';
  end if;
  execute v_new_def;

  -- 6) CREATE administrativo: substitui a assinatura existente, sem aumentar
  -- a quantidade de RPCs. Cliente antigo pode omitir p_included_people.
  select pg_get_functiondef('public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$p_price_per_extra_person numeric[[:space:]]*,[[:space:]]*p_admin_id uuid[[:space:]]*\)$rx$,
    $repl$p_price_per_extra_person numeric, p_admin_id uuid, p_included_people integer DEFAULT NULL)$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$if[[:space:]]+coalesce\(p_minimum_people,0\)<1[[:space:]]+or[[:space:]]+coalesce\(p_maximum_people,0\)<p_minimum_people[[:space:]]+then$rx$,
    $repl$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people or coalesce(p_included_people,p_maximum_people)<p_minimum_people or coalesce(p_included_people,p_maximum_people)>p_maximum_people then$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$base_price[[:space:]]*,[[:space:]]*minimum_people[[:space:]]*,[[:space:]]*maximum_people[[:space:]]*,[[:space:]]*price_per_extra_person$rx$,
    $repl$base_price,minimum_people,included_people,maximum_people,price_per_extra_person$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$p_base_price[[:space:]]*,[[:space:]]*p_minimum_people[[:space:]]*,[[:space:]]*p_maximum_people[[:space:]]*,[[:space:]]*p_price_per_extra_person$rx$,
    $repl$p_base_price,p_minimum_people,coalesce(p_included_people,p_maximum_people),p_maximum_people,p_price_per_extra_person$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: create service catalog';
  end if;

  drop function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid);
  execute v_new_def;
  revoke all on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,integer) from public, anon, authenticated;
  grant execute on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,integer) to service_role;

  -- 7) CREATE + employee: mesma compatibilidade e passa included_people ao RPC base.
  select pg_get_functiondef('public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$p_employee_id uuid[[:space:]]*,[[:space:]]*p_admin_id uuid[[:space:]]*\)$rx$,
    $repl$p_employee_id uuid, p_admin_id uuid, p_included_people integer DEFAULT NULL)$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$p_price_per_extra_person[[:space:]]*,[[:space:]]*p_admin_id[[:space:]]*\)$rx$,
    $repl$p_price_per_extra_person,
    p_admin_id,
    p_included_people
  )$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: create service with employee';
  end if;

  drop function public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid);
  execute v_new_def;
  revoke all on function public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid,integer) from public, anon, authenticated;
  grant execute on function public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid,integer) to service_role;

  -- 8) UPDATE administrativo: included_people passa no mesmo CATALOG.
  select pg_get_functiondef('public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid)'::regprocedure)
    into v_def;

  v_new_def := regexp_replace(
    v_def,
    $rx$p_is_active boolean[[:space:]]*,[[:space:]]*p_sort_order integer[[:space:]]*,[[:space:]]*p_admin_id uuid[[:space:]]*\)$rx$,
    $repl$p_is_active boolean, p_sort_order integer, p_admin_id uuid, p_included_people integer DEFAULT NULL)$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$if[[:space:]]+coalesce\(p_minimum_people,0\)<1[[:space:]]+or[[:space:]]+coalesce\(p_maximum_people,0\)<p_minimum_people[[:space:]]+then$rx$,
    $repl$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people or coalesce(p_included_people,p_maximum_people)<p_minimum_people or coalesce(p_included_people,p_maximum_people)>p_maximum_people then$repl$
  );
  v_new_def := regexp_replace(
    v_new_def,
    $rx$minimum_people[[:space:]]*=[[:space:]]*p_minimum_people[[:space:]]*,[[:space:]]*maximum_people[[:space:]]*=[[:space:]]*p_maximum_people[[:space:]]*,[[:space:]]*price_per_extra_person[[:space:]]*=[[:space:]]*p_price_per_extra_person$rx$,
    $repl$minimum_people=p_minimum_people,included_people=coalesce(p_included_people,p_maximum_people),maximum_people=p_maximum_people,price_per_extra_person=p_price_per_extra_person$repl$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: update service catalog';
  end if;

  drop function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid);
  execute v_new_def;
  revoke all on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid,integer) from public, anon, authenticated;
  grant execute on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid,integer) to service_role;
end;
$migration$;
