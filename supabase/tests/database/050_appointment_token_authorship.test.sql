begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(29);

insert into public.categories(id,name,slug)
values ('96000000-0000-0000-0000-000000000001','Token Authorship','token-authorship-test');
insert into public.employees(id,name)
values ('96000000-0000-0000-0000-000000000002','Token Authorship Employee');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,confirmation_percentage
) values (
  '96000000-0000-0000-0000-000000000010','96000000-0000-0000-0000-000000000001',
  'Token Authorship Service','token-authorship-service',60,100,1,1,5000,50
);
insert into public.service_employees(id,service_id,employee_id)
values ('96000000-0000-0000-0000-000000000011','96000000-0000-0000-0000-000000000010','96000000-0000-0000-0000-000000000002');
insert into public.customers(id,name,email,phone,cpf_cnpj)
values ('96000000-0000-0000-0000-000000000020','Token Customer','token.customer@example.com','48999993333','52998224725');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,
  primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,
  people_count,commercial_value
) values
('96000000-0000-0000-0000-000000000030','TOKEN-AUTH-1','96000000-0000-0000-0000-000000000010','96000000-0000-0000-0000-000000000011','Token Authorship Service','96000000-0000-0000-0000-000000000020','CONFIRMED','PARTIALLY_PAID','2035-10-01 09:00:00-03','2035-10-01 10:00:00-03',60,1,100),
('96000000-0000-0000-0000-000000000031','TOKEN-AUTH-2','96000000-0000-0000-0000-000000000010','96000000-0000-0000-0000-000000000011','Token Authorship Service','96000000-0000-0000-0000-000000000020','CONFIRMED','PARTIALLY_PAID','2035-10-02 09:00:00-03','2035-10-02 10:00:00-03',60,1,100);

create temporary table issued_one as
select public.service_issue_appointment_action_token(
  '96000000-0000-0000-0000-000000000030','CANCEL','EMAIL','t***@example.com','issue-1'
) payload;
create temporary table issued_two as
select public.service_issue_appointment_action_token(
  '96000000-0000-0000-0000-000000000031','CANCEL','EMAIL','t***@example.com','issue-2'
) payload;

select is((select payload->>'scope' from issued_one),'CANCEL','action token has explicit CANCEL scope');
select is(
  (select (payload->>'expires_at')::timestamptz from issued_one),
  '2035-10-01 09:00:00-03'::timestamptz,
  'action token expires exactly at appointment start'
);
select isnt(
  (select token_hash from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_one))::uuid),
  (select payload->>'access_token' from issued_one),
  'database stores token hash, not clear token'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid and event_type='ISSUED'),
  1,
  'token issuance creates evidence event'
);
select ok(
  (select metadata_json::text not like '%'||(select payload->>'access_token' from issued_one)||'%' from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid and event_type='ISSUED'),
  'issuance evidence never contains clear token'
);

create temporary table resolved_one as
select public.service_resolve_appointment_action_token(
  (select payload->>'access_token' from issued_one),'CANCEL','203.0.113.20'::inet,'pgTAP token test','access-1'
) payload;
select is((select payload->>'appointment_id' from resolved_one),'96000000-0000-0000-0000-000000000030','action token resolves only its appointment');
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid and event_type='ACCESS'),
  1,
  'token access is appended to evidence chain'
);
select ok(
  exists(
    select 1 from public.appointment_token_network_evidence ne
    join public.appointment_token_events e on e.id=ne.token_event_id
    where e.appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid
      and e.event_type='ACCESS'
      and ne.ip_address='203.0.113.20'::inet
      and ne.user_agent='pgTAP token test'
  ),
  'access network evidence stores IP and User-Agent separately'
);
select ok(
  (select min(ne.retain_until-ne.occurred_at) >= interval '5 years' - interval '1 minute'
   from public.appointment_token_network_evidence ne
   join public.appointment_token_events e on e.id=ne.token_event_id
   where e.appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid),
  'network evidence retains IP and User-Agent for at least five years'
);

select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued_one))::uuid,'wrong@example.com','203.0.113.20'::inet,'pgTAP token test','bad-1'),false,'first invalid email is rejected');
select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued_one))::uuid,'wrong@example.com','203.0.113.20'::inet,'pgTAP token test','bad-2'),false,'second invalid email is rejected');
select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued_one))::uuid,'wrong@example.com','203.0.113.20'::inet,'pgTAP token test','bad-3'),false,'third invalid email is rejected and reaches lock threshold');
select throws_ok(
  format(
    'select public.service_verify_appointment_action_email(%L::uuid,%L,%L::inet,%L,%L)',
    (select payload->>'token_id' from issued_one),'token.customer@example.com','203.0.113.20','pgTAP token test','correct-after-lock'
  ),
  'P0001','RATE_LIMITED',
  'correct email cannot bypass the three-attempt lockout'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_one))::uuid and event_type='VERIFY_FAILED'),
  3,
  'three invalid verifications are preserved as evidence'
);

create temporary table resolved_two as
select public.service_resolve_appointment_action_token(
  (select payload->>'access_token' from issued_two),'CANCEL','203.0.113.21'::inet,'pgTAP token test','access-2'
) payload;
select is(
  public.service_verify_appointment_action_email(((select payload->>'token_id' from issued_two))::uuid,'token.customer@example.com','203.0.113.21'::inet,'pgTAP token test','verify-ok'),
  true,
  'registered email verifies a fresh cancellation token'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_two))::uuid and event_type='VERIFIED'),
  1,
  'successful verification is appended to evidence chain'
);
select lives_ok(
  format(
    'select public.service_consume_appointment_action_token(%L::uuid,%L,%L::inet,%L,%L,%L::jsonb)',
    (select payload->>'token_id' from issued_two),'CANCEL_CONFIRMED','203.0.113.21','pgTAP token test','consume-2','{"financial_effect":"TEST_ONLY"}'
  ),
  'action token can be consumed after the action'
);
select ok(
  (select consumed_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_two))::uuid),
  'consumption timestamp is persisted'
);
select is(
  (select consumed_action from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_two))::uuid),
  'CANCEL_CONFIRMED',
  'consumed action is persisted'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from issued_two))::uuid and event_type in ('ACTION_EXECUTED','CONSUMED')),
  2,
  'action and consumption are separate append-only evidence events'
);
select throws_ok(
  format(
    'select public.service_resolve_appointment_action_token(%L,%L,%L::inet,%L,%L)',
    (select payload->>'access_token' from issued_two),'CANCEL','203.0.113.21','pgTAP token test','reuse'
  ),
  'P0001','APPOINTMENT_TOKEN_INVALID',
  'consumed token cannot be reused'
);

select throws_ok(
  format(
    'update public.appointment_token_events set request_id=%L where appointment_access_token_id=%L::uuid',
    'tampered',(select payload->>'token_id' from issued_two)
  ),
  '42501','APPOINTMENT_TOKEN_EVIDENCE_APPEND_ONLY',
  'business token evidence is append-only'
);
select throws_ok(
  $$delete from public.appointment_token_network_evidence where true$$,
  '42501','APPOINTMENT_TOKEN_EVIDENCE_APPEND_ONLY',
  'network evidence cannot be directly deleted'
);
select ok(not has_table_privilege('service_role','public.appointment_token_events','UPDATE'),'service_role cannot update token events');
select ok(not has_table_privilege('service_role','public.appointment_token_events','DELETE'),'service_role cannot delete token events');
select ok(not has_table_privilege('service_role','public.appointment_token_network_evidence','DELETE'),'service_role cannot delete network evidence');
select ok(not has_function_privilege('service_role','public.maintenance_purge_appointment_token_network_evidence(timestamptz,text,text)','EXECUTE'),'application service_role cannot invoke five-year maintenance purge');
select ok(not has_function_privilege('anon','public.service_issue_appointment_action_token(uuid,text,text,text,text)','EXECUTE'),'anonymous SQL client cannot issue action tokens');
select ok(not has_function_privilege('authenticated','public.service_resolve_appointment_action_token(text,text,inet,text,text)','EXECUTE'),'ordinary authenticated SQL client cannot resolve action tokens directly');

select * from finish();
rollback;
