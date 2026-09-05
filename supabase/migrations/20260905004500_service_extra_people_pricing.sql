-- Pessoas por serviço: maximum_people passa a representar o máximo incluído no preço.
-- Pessoas acima desse limite são permitidas somente quando price_per_extra_person > 0
-- e são cobradas exclusivamente pelo excedente.
--
-- Mantemos compatibilidade com serviços sem adicional configurado (ex.: Locação):
-- nesses casos maximum_people continua funcionando como teto efetivo.

do $migration$
declare
  v_def text;
  v_new_def text;
begin
  -- 1) Validação pública da seleção.
  select pg_get_functiondef('public.assert_public_booking_selection(text,uuid,uuid,jsonb,integer)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$if p_people_count<v_service.minimum_people or p_people_count>v_service.maximum_people then raise exception using errcode='P0001',message='INVALID_PEOPLE_COUNT'; end if;$old$,
    $new$if p_people_count<v_service.minimum_people or (p_people_count>v_service.maximum_people and coalesce(v_service.price_per_extra_person,0)<=0) then raise exception using errcode='P0001',message='INVALID_PEOPLE_COUNT'; end if;$new$
  );

  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: assert_public_booking_selection';
  end if;
  execute v_new_def;

  -- 2) Quote de serviços FIXED: deixa de cobrar a partir do mínimo e passa a
  -- cobrar somente acima do máximo incluído.
  select pg_get_functiondef('public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$if p_people_count>v_service.maximum_people then raise exception using errcode='P0001',message='PEOPLE_ABOVE_MAXIMUM'; end if;$old$,
    $new$if p_people_count>v_service.maximum_people and coalesce(v_service.price_per_extra_person,0)<=0 then raise exception using errcode='P0001',message='PEOPLE_ABOVE_MAXIMUM'; end if;$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base validation';
  end if;
  v_def := v_new_def;

  v_new_def := replace(
    v_def,
    $old$v_price:=v_after_day_time+greatest(p_people_count-v_service.minimum_people,0)*v_service.price_per_extra_person;$old$,
    $new$v_price:=v_after_day_time+greatest(p_people_count-v_service.maximum_people,0)*v_service.price_per_extra_person;$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base pricing';
  end if;
  v_def := v_new_def;

  v_new_def := replace(
    v_def,
    $old$'people_adjustment',round(v_people_adjustment,2),'extras_total'$old$,
    $new$'people_adjustment',round(v_people_adjustment,2),'extra_people_count',greatest(p_people_count-v_service.maximum_people,0),'extra_people_amount',round(greatest(p_people_count-v_service.maximum_people,0)*v_service.price_per_extra_person,2),'maximum_included_people',v_service.maximum_people,'price_per_extra_person',v_service.price_per_extra_person,'extras_total'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quote_catalog_base metadata';
  end if;
  execute v_new_def;

  -- 3) Quote de serviços BLOCKS: mesma semântica do FIXED.
  select pg_get_functiondef('public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode='P0001', message='INVALID_PEOPLE_COUNT';
  end if;$old$,
    $new$if p_people_count < v_service.minimum_people
     or (p_people_count > v_service.maximum_people and coalesce(v_service.price_per_extra_person,0) <= 0) then
    raise exception using errcode='P0001', message='INVALID_PEOPLE_COUNT';
  end if;$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch validation';
  end if;
  v_def := v_new_def;

  -- Há uma única atribuição desta forma no batch atual, imediatamente antes
  -- das regras PEOPLE. O excedente entra antes dessas regras, preservando a
  -- ordem comercial já existente.
  v_new_def := replace(
    v_def,
    $old$    v_price := v_after_day_time;

    for v_rule in select value from jsonb_array_elements(v_people_rules)$old$,
    $new$    v_price := v_after_day_time
      + greatest(p_people_count - v_service.maximum_people, 0) * v_service.price_per_extra_person;

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
      'extra_people_count', greatest(p_people_count - v_service.maximum_people, 0),
      'extra_people_amount', round(greatest(p_people_count - v_service.maximum_people, 0) * v_service.price_per_extra_person, 2),
      'maximum_included_people', v_service.maximum_people,
      'price_per_extra_person', v_service.price_per_extra_person,
      'extras_total'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: calculate_booking_quotes_for_duration_batch metadata';
  end if;
  execute v_new_def;

  -- 4) Catálogo público: expõe a configuração necessária para a apresentação
  -- do seletor, sem tornar o browser fonte autoritativa do total.
  select pg_get_functiondef('public.public_get_booking_page(text)'::regprocedure)
    into v_def;

  v_new_def := replace(
    v_def,
    $old$'maximum_people',s.maximum_people,'requires_terms'$old$,
    $new$'maximum_people',s.maximum_people,'price_per_extra_person',s.price_per_extra_person,'allows_extra_people',(coalesce(s.price_per_extra_person,0)>0),'requires_terms'$new$
  );
  if v_new_def = v_def then
    raise exception 'MIGRATION_EXPECTED_FRAGMENT_NOT_FOUND: public_get_booking_page';
  end if;
  execute v_new_def;
end;
$migration$;
