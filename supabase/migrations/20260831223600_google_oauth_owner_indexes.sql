create index if not exists google_oauth_states_employee_idx
  on public.google_oauth_states(employee_id)
  where employee_id is not null;
