create or replace function public.blacksheep_rental_special_date(p_date date)
returns boolean
language plpgsql
immutable
strict
set search_path = pg_catalog, public
as $function$
declare
  v_year integer := extract(year from p_date)::integer;
  v_a integer;
  v_b integer;
  v_c integer;
  v_d integer;
  v_e integer;
  v_f integer;
  v_g integer;
  v_h integer;
  v_i integer;
  v_k integer;
  v_l integer;
  v_m integer;
  v_month integer;
  v_day integer;
  v_easter date;
begin
  -- Feriados nacionais de data fixa usados comercialmente pela BlackSheep.
  if (extract(month from p_date)::integer, extract(day from p_date)::integer) in (
    (1,1),   -- Confraternizacao Universal
    (4,21),  -- Tiradentes
    (5,1),   -- Dia do Trabalho
    (9,7),   -- Independencia do Brasil
    (10,12), -- Nossa Senhora Aparecida
    (11,2),  -- Finados
    (11,15), -- Proclamacao da Republica
    (11,20), -- Consciencia Negra
    (12,25)  -- Natal
  ) then
    return true;
  end if;

  -- Computo gregoriano da Pascoa (Meeus/Jones/Butcher), usado para as datas moveis.
  v_a := v_year % 19;
  v_b := v_year / 100;
  v_c := v_year % 100;
  v_d := v_b / 4;
  v_e := v_b % 4;
  v_f := (v_b + 8) / 25;
  v_g := (v_b - v_f + 1) / 3;
  v_h := (19 * v_a + v_b - v_d - v_g + 15) % 30;
  v_i := v_c / 4;
  v_k := v_c % 4;
  v_l := (32 + 2 * v_e + 2 * v_i - v_h - v_k) % 7;
  v_m := (v_a + 11 * v_h + 22 * v_l) / 451;
  v_month := (v_h + v_l - 7 * v_m + 114) / 31;
  v_day := ((v_h + v_l - 7 * v_m + 114) % 31) + 1;
  v_easter := make_date(v_year, v_month, v_day);

  -- Calendario comercial BlackSheep: pontos facultativos de fechamento contam como feriado.
  return p_date = v_easter - 48  -- segunda de Carnaval
      or p_date = v_easter - 47  -- terca de Carnaval
      or p_date = v_easter - 2   -- Paixao de Cristo / Sexta-feira Santa
      or p_date = v_easter + 60; -- Corpus Christi
end;
$function$;

comment on function public.blacksheep_rental_special_date(date) is
  'Calendario comercial da locacao BlackSheep: feriados nacionais + Carnaval (segunda/terca), Sexta-feira Santa e Corpus Christi. Usado para adicional de 20% por bloco, sem acumular com noite/fim de semana.';

do $patch$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
  v_old_decl text := E'  v_block_dow smallint;\n  v_surcharge numeric;';
  v_new_decl text := E'  v_block_dow smallint;\n  v_block_special_date boolean;\n  v_block_matched_percent numeric;\n  v_surcharge numeric;';
  v_old_loop text := E'        for v_rule in select value from jsonb_array_elements(v_day_rules)\n        loop\n          if coalesce(v_rule->>\'action_type\',\'\') = \'ADD_PERCENT\'\n             and (v_rule->>\'valid_from_date\' is null or v_block_local_date >= (v_rule->>\'valid_from_date\')::date)\n             and (v_rule->>\'valid_until_date\' is null or v_block_local_date <= (v_rule->>\'valid_until_date\')::date)\n             and (\n               v_rule->\'days_of_week\' is null\n               or jsonb_typeof(v_rule->\'days_of_week\') = \'null\'\n               or exists (\n                 select 1 from jsonb_array_elements_text(v_rule->\'days_of_week\') d\n                 where d::smallint = v_block_dow\n               )\n             )\n             and (v_rule->>\'start_local_time\' is null or v_block_local_time >= (v_rule->>\'start_local_time\')::time)\n             and (v_rule->>\'end_local_time\' is null or v_block_local_time < (v_rule->>\'end_local_time\')::time)\n          then\n            v_surcharge := v_surcharge\n              + ((v_dynamic_base / (v_contracted_minutes / 30)::numeric)\n                 * ((v_rule->>\'percentage\')::numeric / 100));\n          end if;\n        end loop;';
  v_new_loop text := E'        v_block_special_date := v_service.slug = \'locacao-estudio\'\n          and v_service.operation_scope = \'BLACKSHEEP\'\n          and public.blacksheep_rental_special_date(v_block_local_date);\n        v_block_matched_percent := 0;\n\n        for v_rule in select value from jsonb_array_elements(v_day_rules)\n        loop\n          if coalesce(v_rule->>\'action_type\',\'\') = \'ADD_PERCENT\'\n             and (v_rule->>\'valid_from_date\' is null or v_block_local_date >= (v_rule->>\'valid_from_date\')::date)\n             and (v_rule->>\'valid_until_date\' is null or v_block_local_date <= (v_rule->>\'valid_until_date\')::date)\n             and (\n               v_rule->\'days_of_week\' is null\n               or jsonb_typeof(v_rule->\'days_of_week\') = \'null\'\n               or exists (\n                 select 1 from jsonb_array_elements_text(v_rule->\'days_of_week\') d\n                 where d::smallint = v_block_dow\n               )\n             )\n             and (v_rule->>\'start_local_time\' is null or v_block_local_time >= (v_rule->>\'start_local_time\')::time)\n             and (v_rule->>\'end_local_time\' is null or v_block_local_time < (v_rule->>\'end_local_time\')::time)\n          then\n            if v_block_special_date then\n              v_block_matched_percent := v_block_matched_percent + coalesce((v_rule->>\'percentage\')::numeric, 0);\n            else\n              v_surcharge := v_surcharge\n                + ((v_dynamic_base / (v_contracted_minutes / 30)::numeric)\n                   * (coalesce((v_rule->>\'percentage\')::numeric, 0) / 100));\n            end if;\n          end if;\n        end loop;\n\n        if v_block_special_date then\n          v_surcharge := v_surcharge\n            + ((v_dynamic_base / (v_contracted_minutes / 30)::numeric)\n               * (greatest(v_block_matched_percent, 20) / 100));\n        end if;';
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'calculate_booking_quotes_for_duration_batch'
    and pg_get_function_identity_arguments(p.oid) = 'p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_ats timestamp with time zone[], p_coupon_code text';

  if v_oid is null then
    raise exception 'calculate_booking_quotes_for_duration_batch not found';
  end if;

  v_definition := pg_get_functiondef(v_oid);
  v_patched := v_definition;

  if position('v_block_special_date boolean' in v_patched) = 0 then
    v_patched := replace(v_patched, v_old_decl, v_new_decl);
    if v_patched = v_definition then
      raise exception 'holiday pricing declaration patch anchor not found';
    end if;
  end if;

  if position('public.blacksheep_rental_special_date(v_block_local_date)' in v_patched) = 0 then
    v_definition := v_patched;
    v_patched := replace(v_patched, v_old_loop, v_new_loop);
    if v_patched = v_definition then
      raise exception 'holiday pricing block loop patch anchor not found';
    end if;
  end if;

  v_patched := replace(v_patched, 'BLOCK_DAY_TIME_PROPORTIONAL_V1', 'BLOCK_DAY_TIME_HOLIDAY_PROPORTIONAL_V2');
  execute v_patched;
end;
$patch$;
