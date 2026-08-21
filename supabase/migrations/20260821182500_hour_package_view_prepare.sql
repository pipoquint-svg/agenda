drop view public.hour_package_balances;

-- Transitional view used only between migrations so the legacy minutes column
-- can change type without a dependency from the canonical balance view.
create view public.hour_package_balances as
select p.id as hour_package_id
from public.hour_packages p;
