-- Prevent case-insensitive customer e-mail duplication without modifying existing rows.
-- PostgreSQL unique indexes allow multiple NULL values, so customers without e-mail remain valid.

do $$
begin
  if exists (
    select 1
    from public.customers
    where email is not null
    group by lower(email)
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'CUSTOMERS_EMAIL_DUPLICATES_EXIST';
  end if;
end
$$;

create unique index customers_email_lower_uq
  on public.customers (lower(email));
