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

  v_new_def := replace(
    v_def,
    $old$v_price:=v_after_day_time+greatest(p_people_count-v_service.minimum_people,0)*v_service.price_per_extra_person;$old$,
    $new$v_price:=v_after_day_time+greatest(p_people_count-v_service.included_people,0)*v_service.price_per_extra_person;$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base pricing';
  end if;
  v_def := v_new_def;

  v_new_def := replace(
    v_def,
    $old$'people_adjustment',round(v_people_adjustment,2),'extras_total'$old$,
    $new$'people_adjustment',round(v_people_adjustment,2),'extra_people_count',greatest(p_people_count-v_service.included_people,0),'extra_people_amount',round(greatest(p_people_count-v_service.included_people,0)*v_service.price_per_extra_person,2),'included_people',v_service.included_people,'maximum_people',v_service.maximum_people,'price_per_extra_person',v_service.price_per_extra_person,'extras_total'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base metadata';
  end if;
  execute v_new_def;

  -- 2) Quote BLOCKS: mesma semântica. O teto máximo continua sendo validado
  -- pela função original; apenas o cálculo do excedente é acrescentado.
  select pg_get_functiondef('public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$    v_price := v_after_day_time;

    for v_rule in select value from jsonb_array_elements(v_people_rules)$old$,
    $new$    v_price := v_after_day_time
      + greatest(p_people_count - v_service.included_people, 0) * v_service.price_per_extra_person;

    for v_rule in select value from jsonb_array_elements(v_people_rules)$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch pricing';
  end if;
  v_def := v_new_def;

  v_new_def := replace(
    v_def,
    $old$      'people_adjustment', round(v_people_adjustment,2),
      'extras_total'$old$,
    $new$      'people_adjustment', round(v_people_adjustment,2),
      'extra_people_count', greatest(p_people_count - v_service.included_people, 0),
      'extra_people_amount', round(greatest(p_people_count - v_service.included_people, 0) * v_service.price_per_extra_person, 2),
      'included_people', v_service.included_people,
      'maximum_people', v_service.maximum_people,
      'price_per_extra_person', v_service.price_per_extra_person,
      'extras_total'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch metadata';
  end if;
  execute v_new_def;

  -- 3) Catálogo público: configuração + opções autoritativas de pessoas.
  select pg_get_functiondef('public.public_get_booking_page(text)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$'minimum_people',s.minimum_people,'maximum_people',s.maximum_people,'requires_terms'$old$,
    $new$'minimum_people',s.minimum_people,'included_people',s.included_people,'maximum_people',s.maximum_people,'price_per_extra_person',s.price_per_extra_person,'people_options',coalesce((select jsonb_agg(jsonb_build_object('count',g,'included',(g<=s.included_people),'extra_people_count',greatest(g-s.included_people,0),'extra_people_amount',round(greatest(g-s.included_people,0)*s.price_per_extra_person,2)) order by g) from generate_series(s.minimum_people,s.maximum_people) g),'[]'::jsonb),'requires_terms'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: public_get_booking_page';
  end if;
  execute v_new_def;

  -- 4) Read model administrativo passa a expor included_people.
  select pg_get_functiondef('public.service_admin_list_service_settings()'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$'minimum_people',s.minimum_people,'maximum_people',s.maximum_people,'price_per_extra_person'$old$,
    $new$'minimum_people',s.minimum_people,'included_people',s.included_people,'maximum_people',s.maximum_people,'price_per_extra_person'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: service_admin_list_service_settings';
  end if;
  execute v_new_def;

  -- 5) Duplicação de serviço preserva included_people.
  select pg_get_functiondef('public.service_admin_duplicate_service_audited(uuid,text,text,uuid)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$base_price,minimum_people,maximum_people,minimum_booking_notice_minutes$old$,
    $new$base_price,minimum_people,included_people,maximum_people,minimum_booking_notice_minutes$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: duplicate columns';
  end if;
  v_def := v_new_def;

  v_new_def := replace(
    v_def,
    $old$v_source.base_price,v_source.minimum_people,v_source.maximum_people,v_source.minimum_booking_notice_minutes$old$,
    $new$v_source.base_price,v_source.minimum_people,v_source.included_people,v_source.maximum_people,v_source.minimum_booking_notice_minutes$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: duplicate values';
  end if;
  execute v_new_def;

  -- 6) CREATE administrativo: mantém compatibilidade com clientes antigos
  -- usando p_included_people default NULL => maximum_people.
  select pg_get_functiondef('public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$p_price_per_extra_person numeric, p_admin_id uuid)$old$,
    $new$p_price_per_extra_person numeric, p_admin_id uuid, p_included_people integer DEFAULT NULL)$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001',message='INVALID_PEOPLE_RANGE';end if;$old$,
    $new$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people or coalesce(p_included_people,p_maximum_people)<p_minimum_people or coalesce(p_included_people,p_maximum_people)>p_maximum_people then raise exception using errcode='P0001',message='INVALID_PEOPLE_RANGE';end if;$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$base_price,minimum_people,maximum_people,price_per_extra_person,is_active$old$,
    $new$base_price,minimum_people,included_people,maximum_people,price_per_extra_person,is_active$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$p_base_price,p_minimum_people,p_maximum_people,p_price_per_extra_person,false$old$,
    $new$p_base_price,p_minimum_people,coalesce(p_included_people,p_maximum_people),p_maximum_people,p_price_per_extra_person,false$new$
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

  v_new_def := replace(
    v_def,
    $old$p_employee_id uuid, p_admin_id uuid)$old$,
    $new$p_employee_id uuid, p_admin_id uuid, p_included_people integer DEFAULT NULL)$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$    p_price_per_extra_person,
    p_admin_id
  );$old$,
    $new$    p_price_per_extra_person,
    p_admin_id,
    p_included_people
  );$new$
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

  v_new_def := replace(
    v_def,
    $old$p_is_active boolean, p_sort_order integer, p_admin_id uuid)$old$,
    $new$p_is_active boolean, p_sort_order integer, p_admin_id uuid, p_included_people integer DEFAULT NULL)$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001',message='INVALID_PEOPLE_RANGE'; end if;$old$,
    $new$if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people or coalesce(p_included_people,p_maximum_people)<p_minimum_people or coalesce(p_included_people,p_maximum_people)>p_maximum_people then raise exception using errcode='P0001',message='INVALID_PEOPLE_RANGE'; end if;$new$
  );
  v_new_def := replace(
    v_new_def,
    $old$minimum_people=p_minimum_people,maximum_people=p_maximum_people,price_per_extra_person=p_price_per_extra_person$old$,
    $new$minimum_people=p_minimum_people,included_people=coalesce(p_included_people,p_maximum_people),maximum_people=p_maximum_people,price_per_extra_person=p_price_per_extra_person$new$
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
