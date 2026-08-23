begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

insert into auth.users(id) values
('97000000-0000-0000-0000-000000000001'),
('97000000-0000-0000-0000-000000000002');
insert into public.admin_users(id,auth_user_id,display_name,role,is_active) values
('97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000001','Audit Owner','OWNER',true),
('97000000-0000-0000-0000-000000000012','97000000-0000-0000-0000-000000000002','Operation User','OPERATION',true);

insert into public.categories(id,name,slug)
values ('97000000-0000-0000-0000-000000000020','Admin Authorship','admin-authorship-test');
insert into public.employees(id,name)
values ('97000000-0000-0000-0000-000000000021','Admin Authorship Employee');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,confirmation_percentage
) values (
  '97000000-0000-0000-0000-000000000022','97000000-0000-0000-0000-000000000020',
  'Admin Authorship Service','admin-authorship-service',60,100,1,1,5000,50
);
insert into public.service_employees(id,service_id,employee_id)
values ('97000000-0000-0000-0000-000000000023','97000000-0000-0000-0000-000000000022','97000000-0000-0000-0000-000000000021');
insert into public.customers(id,name,email,phone,cpf_cnpj)
values ('97000000-0000-0000-0000-000000000024','Audit Customer','audit.customer@example.com','48999994444','52998224725');
insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,
  primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,
  people_count,commercial_value
) values (
  '97000000-0000-0000-0000-000000000030','AUDIT-ADMIN-1',
  '97000000-0000-0000-0000-000000000022','97000000-0000-0000-0000-000000000023',
  'Admin Authorship Service','97000000-0000-0000-0000-000000000024',
  'CONFIRMED','PARTIALLY_PAID','2035-11-01 09:00:00-03','2035-11-01 10:00:00-03',60,1,100
);

create temporary table issued as
select public.service_issue_appointment_action_token(
  '97000000-0000-0000-0000-000000000030','CANCEL','EMAIL','a***@example.com','admin-audit-issue'
) payload;

select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued))::uuid,'wrong@example.com','203.0.113.97'::inet,'pgTAP admin audit','bad-a'),false,'first invalid verification is rejected');
select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued))::uuid,'wrong@example.com','203.0.113.97'::inet,'pgTAP admin audit','bad-b'),false,'second invalid verification is rejected');
select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued))::uuid,'wrong@example.com','203.0.113.97'::inet,'pgTAP admin audit','bad-c'),false,'third invalid verification reaches lock threshold');

select throws_ok(
  $$select public.service_admin_get_appointment_token_security_state('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000012')$$,
  'P0001','ADMIN_PERMISSION_DENIED','operation role cannot inspect protected token security state'
);
select is(
  (public.service_admin_get_appointment_token_security_state('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011')->>'locked')::boolean,
  true,
  'owner with AUDIT_VIEW sees verification lockout'
);
select throws_ok(
  $$select public.service_admin_unlock_appointment_token_verification('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000012','should fail','203.0.113.10'::inet,'pgTAP admin','deny-unlock',null)$$,
  'P0001','ADMIN_PERMISSION_DENIED','user without AUDIT_VIEW cannot unlock verification'
);
select lives_ok(
  $$select public.service_admin_unlock_appointment_token_verification('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011','Cliente confirmou solicitação por telefone','203.0.113.10'::inet,'pgTAP admin','unlock-1',null)$$,
  'authorized admin can unlock verification attempts'
);
select is(
  (public.service_admin_get_appointment_token_security_state('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011')->>'locked')::boolean,
  false,
  'unlock clears appointment and observed-origin lock buckets'
);
select is(
  public.service_verify_appointment_action_email(((select payload->>'token_id' from issued))::uuid,'audit.customer@example.com','203.0.113.97'::inet,'pgTAP admin audit','correct-after-unlock'),
  true,
  'valid active token can verify after authorized unlock'
);
select ok(
  exists(
    select 1 from public.appointment_authorship_events e
    where e.appointment_id='97000000-0000-0000-0000-000000000030'
      and e.action='TOKEN_VERIFICATION_UNLOCKED'
      and e.origin='ADMIN_UI'
      and e.admin_user_id='97000000-0000-0000-0000-000000000011'
      and e.actor_role='OWNER'
      and 'AUDIT_VIEW'=any(e.actor_permissions)
      and 'AGENDA_MANAGE'=any(e.actor_permissions)
      and e.ip_address='203.0.113.10'::inet
      and e.user_agent='pgTAP admin'
      and e.request_id='unlock-1'
      and e.reason='Cliente confirmou solicitação por telefone'
  ),
  'unlock persists admin identity, role, permissions, request context and reason'
);
select ok(
  (select min(network_retain_until-occurred_at) >= interval '5 years' - interval '1 minute'
   from public.appointment_authorship_events
   where appointment_id='97000000-0000-0000-0000-000000000030'),
  'admin authorship network evidence is retained for at least five years'
);
select throws_ok(
  $$update public.appointment_authorship_events set reason='tampered' where appointment_id='97000000-0000-0000-0000-000000000030'$$,
  '42501','APPOINTMENT_AUTHORSHIP_APPEND_ONLY','admin authorship evidence cannot be updated'
);
select throws_ok(
  $$delete from public.appointment_authorship_events where appointment_id='97000000-0000-0000-0000-000000000030'$$,
  '42501','APPOINTMENT_AUTHORSHIP_APPEND_ONLY','admin authorship evidence cannot be deleted'
);
select ok(not has_table_privilege('service_role','public.appointment_authorship_events','INSERT'),'service_role cannot insert authorship evidence directly');
select throws_ok(
  $$select public.service_admin_get_appointment_timeline('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000012')$$,
  'P0001','ADMIN_PERMISSION_DENIED','timeline requires AUDIT_VIEW'
);
select ok(
  (public.service_admin_get_appointment_timeline('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011')->'events')::text like '%TOKEN_VERIFICATION_UNLOCKED%'
  and (public.service_admin_get_appointment_timeline('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011')->'events')::text like '%VERIFY_FAILED%',
  'timeline joins business authorship and token evidence chronologically'
);
select ok(
  (public.service_admin_get_appointment_timeline('97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011'))::text not like '%'||(select payload->>'access_token' from issued)||'%',
  'timeline never exposes clear action token'
);

select public.service_consume_appointment_action_token(
  ((select payload->>'token_id' from issued))::uuid,'CANCEL_CONFIRMED','203.0.113.97'::inet,'pgTAP admin audit','consume-after-unlock','{}'::jsonb
);
insert into public.public_rate_limit_buckets(scope,key_hash,window_started_at,request_count,updated_at)
values (
  'TOKEN_VERIFY_APPOINTMENT',encode(digest('appointment:97000000-0000-0000-0000-000000000030','sha256'),'hex'),clock_timestamp(),3,clock_timestamp()
)
on conflict (scope,key_hash) do update set request_count=3,window_started_at=excluded.window_started_at,updated_at=excluded.updated_at;
select public.service_admin_unlock_appointment_token_verification(
  '97000000-0000-0000-0000-000000000030','97000000-0000-0000-0000-000000000011',
  'Nova tentativa autorizada','203.0.113.10'::inet,'pgTAP admin','unlock-consumed',null
);
select throws_ok(
  format(
    'select public.service_resolve_appointment_action_token(%L,%L,%L::inet,%L,%L)',
    (select payload->>'access_token' from issued),'CANCEL','203.0.113.97','pgTAP admin audit','reuse-after-unlock'
  ),
  'P0001','APPOINTMENT_TOKEN_INVALID',
  'unlock never revives a consumed token'
);

select * from finish();
rollback;
