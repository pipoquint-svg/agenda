create domain public.pricing_rule_scope as text
  check (value in ('DAY_TIME', 'PEOPLE'));

create domain public.pricing_action_type as text
  check (value in ('REPLACE_PRICE', 'ADD_AMOUNT', 'ADD_PERCENT'));

create table public.pricing_rules (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  name text not null,
  rule_scope public.pricing_rule_scope not null,
  days_of_week smallint[],
  start_local_time time without time zone,
  end_local_time time without time zone,
  min_people integer,
  max_people integer,
  valid_from_date date,
  valid_until_date date,
  action_type public.pricing_action_type not null,
  amount numeric(12,2),
  percentage numeric(7,4),
  priority integer not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (days_of_week is null or days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]),
  check (start_local_time is null or end_local_time is null or start_local_time < end_local_time),
  check (min_people is null or min_people >= 1),
  check (max_people is null or max_people >= 1),
  check (min_people is null or max_people is null or max_people >= min_people),
  check (valid_from_date is null or valid_until_date is null or valid_until_date >= valid_from_date),
  check (
    (action_type in ('REPLACE_PRICE','ADD_AMOUNT') and amount is not null and amount >= 0 and percentage is null)
    or
    (action_type = 'ADD_PERCENT' and percentage is not null and percentage >= 0 and amount is null)
  ),
  check (
    (rule_scope = 'DAY_TIME' and min_people is null and max_people is null)
    or
    (rule_scope = 'PEOPLE' and min_people is not null and max_people is not null
      and days_of_week is null and start_local_time is null and end_local_time is null)
  )
);

create index pricing_rules_service_active_priority_idx
  on public.pricing_rules (service_id, priority, id)
  where is_active;

create table public.availability_rules (
  id uuid primary key default gen_random_uuid(),
  service_employee_id uuid not null references public.service_employees(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_local_time time without time zone not null,
  end_local_time time without time zone not null,
  slot_interval_minutes integer not null check (slot_interval_minutes > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_local_time < end_local_time),
  unique (service_employee_id, weekday, start_local_time, end_local_time)
);

create index availability_rules_lookup_idx
  on public.availability_rules (service_employee_id, weekday, start_local_time, end_local_time)
  where is_active;

create table public.resource_availability_rules (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_local_time time without time zone not null,
  end_local_time time without time zone not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_local_time < end_local_time),
  unique (resource_id, weekday, start_local_time, end_local_time)
);

create index resource_availability_rules_lookup_idx
  on public.resource_availability_rules (resource_id, weekday, start_local_time, end_local_time)
  where is_active;

create table public.availability_exceptions (
  id uuid primary key default gen_random_uuid(),
  service_employee_id uuid references public.service_employees(id) on delete cascade,
  resource_id uuid references public.resources(id) on delete cascade,
  exception_type text not null check (exception_type in ('BLOCK', 'OPEN')),
  start_at timestamptz not null,
  end_at timestamptz not null,
  reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (end_at > start_at),
  check (service_employee_id is not null or resource_id is not null)
);

create index availability_exceptions_service_employee_idx
  on public.availability_exceptions (service_employee_id, start_at, end_at)
  where service_employee_id is not null;

create index availability_exceptions_resource_idx
  on public.availability_exceptions (resource_id, start_at, end_at)
  where resource_id is not null;
