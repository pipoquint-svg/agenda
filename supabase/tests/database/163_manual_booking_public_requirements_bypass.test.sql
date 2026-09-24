begin;

select plan(7);

select ok(
  position(
    'current_setting(''agenda.manual_booking'', true)'
    in pg_get_functiondef(
      'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure
    )
  ) > 0,
  'checkout promoter contains the isolated manual-booking flag'
);

select ok(
  position(
    'REQUIRED_SERVICE_FIELDS_MISSING'
    in pg_get_functiondef(
      'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure
    )
  ) > 0,
  'public required-field validation remains present'
);

select ok(
  position(
    'TERMS_NOT_ACCEPTED'
    in pg_get_functiondef(
      'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure
    )
  ) > 0,
  'public terms validation remains present'
);

select ok(
  position(
    'set_config(''agenda.manual_booking'', ''on'', true)'
    in pg_get_functiondef(
      'public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)'::regprocedure
    )
  ) > 0,
  'admin manual booking enables the transaction-local bypass'
);

select ok(
  position(
    'set_config(''agenda.manual_booking'', ''off'', true)'
    in pg_get_functiondef(
      'public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)'::regprocedure
    )
  ) > 0,
  'admin manual booking resets the transaction-local bypass'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure,
    'EXECUTE'
  ),
  'public app roles cannot invoke the internal promoter directly'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure,
    'EXECUTE'
  ),
  'service_role retains the controlled promoter path'
);

select * from finish();
rollback;
