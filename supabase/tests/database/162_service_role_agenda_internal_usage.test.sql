begin;

select plan(5);

select ok(
  has_schema_privilege('service_role', 'agenda_internal', 'USAGE'),
  'service_role can traverse the private agenda_internal schema'
);

select ok(
  not has_schema_privilege('service_role', 'agenda_internal', 'CREATE'),
  'service_role cannot create objects in agenda_internal'
);

select ok(
  not has_schema_privilege('anon', 'agenda_internal', 'USAGE'),
  'anon cannot traverse agenda_internal'
);

select ok(
  not has_schema_privilege('authenticated', 'agenda_internal', 'USAGE'),
  'authenticated cannot traverse agenda_internal'
);

select ok(
  has_function_privilege(
    'service_role',
    'agenda_internal.calculate_booking_resource_ranges_resolved_duration(uuid,jsonb,timestamptz,integer,integer,integer)'::regprocedure,
    'EXECUTE'
  ),
  'service_role keeps only the explicitly granted helper execution path'
);

select * from finish();
rollback;
