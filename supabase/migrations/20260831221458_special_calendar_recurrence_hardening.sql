create or replace function public.special_calendar_holiday_key(p_name text)
returns text
language sql
immutable
parallel safe
set search_path to 'pg_catalog'
as $$
  select regexp_replace(
    lower(translate(btrim(coalesce(p_name, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')),
    '[[:space:]]+',
    ' ',
    'g'
  );
$$;

revoke all on function public.special_calendar_holiday_key(text) from public, anon, authenticated;
grant execute on function public.special_calendar_holiday_key(text) to service_role;
