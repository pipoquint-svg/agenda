const API_URL = requiredEnv('LOCAL_API_URL').replace(/\/+$/, '')
const ANON_KEY = requiredEnv('LOCAL_ANON_KEY')
const SERVICE_ROLE_KEY = requiredEnv('LOCAL_SERVICE_ROLE_KEY')

const BOOKING_PAGE = 'local-verify-locacao'
const SERVICE_ID = '99100000-0000-0000-0000-000000000010'
const SERVICE_EMPLOYEE_ID = '99100000-0000-0000-0000-000000000020'
let localPhoneSequence = 0

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function closeTo(actual: number, expected: number, delta = 0.01): boolean {
  return Math.abs(actual - expected) <= delta
}

function nextLocalPhone(): string {
  localPhoneSequence += 1
  return `+55489999${String(localPhoneSequence).padStart(5, '0')}`
}

async function requestJson(
  url: string,
  init: RequestInit,
  expectedStatuses: number[] = [200],
): Promise<Record<string, any>> {
  const response = await fetch(url, init)
  const text = await response.text()
  let body: Record<string, any> = {}
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    throw new Error(`INVALID_JSON:${response.status}:${text.slice(0, 200)}`)
  }
  if (!expectedStatuses.includes(response.status)) {
    throw new Error(`HTTP_${response.status}:${url}:${JSON.stringify(body)}`)
  }
  return body
}

function edgeHeaders(extra: Record<string, string> = {}): HeadersInit {
  return {
    apikey: ANON_KEY,
    authorization: `Bearer ${ANON_KEY}`,
    'content-type': 'application/json',
    'user-agent': 'BlackSheep Local Verification E2E',
    ...extra,
  }
}

function serviceRoleHeaders(extra: Record<string, string> = {}): HeadersInit {
  return {
    apikey: SERVICE_ROLE_KEY,
    authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    'content-type': 'application/json',
    ...extra,
  }
}

async function createBooking(slot: string, suffix: string): Promise<{
  appointmentId: string
  accessToken: string
  publicCode: string
  holdToken: string
}> {
  const holdResponse = await requestJson(`${API_URL}/functions/v1/booking-hold`, {
    method: 'POST',
    headers: edgeHeaders(),
    body: JSON.stringify({
      booking_page_slug: BOOKING_PAGE,
      service_id: SERVICE_ID,
      service_employee_id: SERVICE_EMPLOYEE_ID,
      requested_start_at: slot,
      contracted_minutes: 60,
      extra_selections: [],
      people_count: 1,
      attribution_json: { source: 'local-verification', test: suffix },
    }),
  }, [201])

  const hold = holdResponse.hold ?? {}
  const holdToken = String(hold.checkout_hold_token ?? '')
  assert(holdToken.length >= 32, 'booking-hold must return a valid checkout token')
  assert(hold.status === 'ACTIVE', 'booking-hold must be ACTIVE')
  assert(Number(hold.commercial_value) === 180, `rental quote must be 180, got ${hold.commercial_value}`)

  const unique = `${suffix}-${crypto.randomUUID().slice(0, 8)}`
  await requestJson(`${API_URL}/functions/v1/booking-checkout`, {
    method: 'POST',
    headers: edgeHeaders(),
    body: JSON.stringify({
      action: 'BIND_CUSTOMER',
      checkout_hold_token: holdToken,
      name: `Cliente Local ${unique}`,
      email: `${unique}@example.test`,
      phone: nextLocalPhone(),
      tax_id: null,
    }),
  })

  const context = await requestJson(`${API_URL}/functions/v1/booking-checkout`, {
    method: 'POST',
    headers: edgeHeaders(),
    body: JSON.stringify({ action: 'CONTEXT', checkout_hold_token: holdToken }),
  })
  assert(context.data?.service?.id === SERVICE_ID || context.data?.service_id === SERVICE_ID || context.data, 'checkout context must resolve')

  const submit = await requestJson(`${API_URL}/functions/v1/booking-submit`, {
    method: 'POST',
    headers: edgeHeaders({ 'x-request-id': crypto.randomUUID() }),
    body: JSON.stringify({
      checkout_hold_token: holdToken,
      checkout_mode: 'PAY_NOW',
      term_version_ids: [],
      answers: [],
    }),
  })

  const appointment = submit.appointment ?? {}
  const appointmentId = String(appointment.appointment_id ?? '')
  const accessToken = String(appointment.access_token ?? '')
  const publicCode = String(appointment.public_code ?? '')
  assert(/^[0-9a-f-]{36}$/i.test(appointmentId), 'booking-submit must create an appointment')
  assert(accessToken.length >= 32, 'booking-submit must return appointment access token')
  assert(appointment.status === 'AWAITING_PAYMENT', `paid rental must await payment, got ${appointment.status}`)
  assert(Number(appointment.cash_due) === 180, `cash due must be 180, got ${appointment.cash_due}`)

  return { appointmentId, accessToken, publicCode, holdToken }
}

async function paymentContext(accessToken: string): Promise<Record<string, any>> {
  return requestJson(`${API_URL}/functions/v1/mercado-pago-payment`, {
    method: 'GET',
    headers: edgeHeaders({ 'x-appointment-token': accessToken }),
  })
}

async function diagnosePaymentApply(accessToken: string): Promise<Record<string, any>> {
  return requestJson(`${API_URL}/rest/v1/rpc/qa_diagnose_local_payment_apply`, {
    method: 'POST',
    headers: serviceRoleHeaders(),
    body: JSON.stringify({ p_access_token: accessToken }),
  })
}

async function payPix(accessToken: string, paymentKind: 'MINIMUM' | 'FULL'): Promise<Record<string, any>> {
  try {
    return await requestJson(`${API_URL}/functions/v1/mercado-pago-payment`, {
      method: 'POST',
      headers: edgeHeaders({ 'x-appointment-token': accessToken }),
      body: JSON.stringify({
        payment_kind: paymentKind,
        method: 'PIX',
        request_key: crypto.randomUUID(),
      }),
    }, [200, 201])
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (message.includes('PAYMENT_STATUS_APPLY_FAILED')) {
      const diagnostic = await diagnosePaymentApply(accessToken)
      throw new Error(`PAYMENT_STATUS_APPLY_DIAGNOSTIC:${JSON.stringify(diagnostic)}`)
    }
    throw error
  }
}

async function createAdminSession(): Promise<string> {
  const email = `local-admin-${crypto.randomUUID()}@example.test`
  const password = `LocalOnly-${crypto.randomUUID()}-A1!`

  const created = await requestJson(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: serviceRoleHeaders(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  }, [200, 201])
  const authUserId = String(created.id ?? created.user?.id ?? '')
  assert(/^[0-9a-f-]{36}$/i.test(authUserId), 'local admin auth user must be created')

  // The local fixture owns setup of the administrative row. We intentionally do
  // not grant direct REST access to admin_users/admin_user_permissions.
  await requestJson(`${API_URL}/rest/v1/rpc/qa_register_local_verification_admin`, {
    method: 'POST',
    headers: serviceRoleHeaders(),
    body: JSON.stringify({ p_auth_user_id: authUserId }),
  })

  const session = await requestJson(`${API_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const accessToken = String(session.access_token ?? '')
  assert(accessToken.length > 40, 'local admin must receive an access token')
  return accessToken
}

async function adminChange(accessToken: string, body: Record<string, unknown>, expectedStatuses = [200]): Promise<Record<string, any>> {
  return requestJson(`${API_URL}/functions/v1/admin-change-actions`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
      'x-forwarded-for': '127.0.0.1',
      'x-request-id': crypto.randomUUID(),
      'user-agent': 'BlackSheep Local Verification Admin E2E',
    },
    body: JSON.stringify(body),
  }, expectedStatuses)
}

async function readAppointment(appointmentId: string): Promise<Record<string, any>> {
  const response = await requestJson(
    `${API_URL}/rest/v1/appointments?id=eq.${encodeURIComponent(appointmentId)}&select=id,status,financial_status,commercial_value`,
    {
      method: 'GET',
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
    },
  )
  if (!Array.isArray(response)) return response
  return response[0] ?? {}
}

Deno.test('Item 1 rental E2E: hold, reservation, checkout, initial balance and cancellation stay local', async () => {
  const booking = await createBooking('2035-11-10T10:00:00-03:00', 'base-flow')

  const before = await paymentContext(booking.accessToken)
  assert(Number(before.financial?.contract_balance) === 180, 'initial contract balance must be 180')
  assert(before.payment_methods?.pix_available === true, 'local Mercado Pago mock must be available')

  const cancellable = await createBooking('2035-11-11T10:00:00-03:00', 'cancel-flow')
  const adminToken = await createAdminSession()
  await adminChange(adminToken, {
    action: 'CANCEL',
    appointment_id: cancellable.appointmentId,
    settlement_choice: 'NONE',
    reason: 'Item 1 local verification cancellation',
  })
  const cancelled = await readAppointment(cancellable.appointmentId)
  assert(cancelled.status === 'CANCELLED', `cancellation must persist, got ${cancelled.status}`)
})

Deno.test('Phase 2A ACL baseline: Pix signal and balance succeed against rebuilt production ACL', async () => {
  const paid = await createBooking('2035-11-15T10:00:00-03:00', 'phase-2a-target')

  const minimum = await payPix(paid.accessToken, 'MINIMUM')
  assert(minimum.provider?.status === 'approved', `minimum Pix must be approved by local mock: ${JSON.stringify(minimum)}`)

  const afterMinimum = await paymentContext(paid.accessToken)
  const remaining = Number(afterMinimum.financial?.contract_balance)
  assert(remaining > 0 && remaining < 180, `minimum payment must leave a positive balance, got ${remaining}`)
  assert(closeTo(remaining, 90), `50% minimum must leave 90, got ${remaining}`)

  const full = await payPix(paid.accessToken, 'FULL')
  assert(full.provider?.status === 'approved', 'balance Pix must be approved by local mock')

  const afterFull = await paymentContext(paid.accessToken)
  assert(closeTo(Number(afterFull.financial?.contract_balance), 0), 'balance must be fully settled')
  assert(afterFull.appointment?.appointment_status === 'CONFIRMED', 'appointment must be confirmed after payment')
})

Deno.test('Item A: NO_SHOW preserves debt, creates no refund or credit, and records evidenced authorship', async () => {
  const booking = await createBooking('2035-11-12T10:00:00-03:00', 'item-a-no-show')
  await payPix(booking.accessToken, 'MINIMUM')

  const serviceHeaders = serviceRoleHeaders()
  const beforeFinancial = await requestJson(`${API_URL}/rest/v1/rpc/get_appointment_financial_summary`, {
    method: 'POST',
    headers: serviceHeaders,
    body: JSON.stringify({ p_appointment_id: booking.appointmentId }),
  })
  const balanceBefore = Number(beforeFinancial.contract_balance)
  assert(closeTo(balanceBefore, 90), `NO_SHOW fixture must start with 90 open, got ${balanceBefore}`)

  const beforeRefunds = await requestJson(
    `${API_URL}/rest/v1/payment_transactions?appointment_id=eq.${encodeURIComponent(booking.appointmentId)}&transaction_type=eq.REFUND&select=id`,
    { method: 'GET', headers: serviceHeaders },
  )
  const beforeCredits = await requestJson(
    `${API_URL}/rest/v1/customer_balance_movements?appointment_id=eq.${encodeURIComponent(booking.appointmentId)}&select=id`,
    { method: 'GET', headers: serviceHeaders },
  )
  assert(Array.isArray(beforeRefunds), 'refund baseline must be a list')
  assert(Array.isArray(beforeCredits), 'credit baseline must be a list')

  await requestJson(
    `${API_URL}/rest/v1/appointments?id=eq.${encodeURIComponent(booking.appointmentId)}`,
    {
      method: 'PATCH',
      headers: serviceHeaders,
      body: JSON.stringify({
        start_at: '2025-01-15T10:00:00-03:00',
        end_at: '2025-01-15T11:00:00-03:00',
        core_start_at: '2025-01-15T10:00:00-03:00',
        core_end_at: '2025-01-15T11:00:00-03:00',
      }),
    },
    [204],
  )

  const adminToken = await createAdminSession()
  const changed = await adminChange(adminToken, {
    action: 'NO_SHOW',
    appointment_id: booking.appointmentId,
    reason: 'Item A controlled local no-show evidence',
  })
  assert(changed.status === 'NO_SHOW', `NO_SHOW endpoint must succeed, got ${JSON.stringify(changed)}`)

  const appointment = await readAppointment(booking.appointmentId)
  assert(appointment.status === 'NO_SHOW', `status must be NO_SHOW, got ${appointment.status}`)

  const afterRefunds = await requestJson(
    `${API_URL}/rest/v1/payment_transactions?appointment_id=eq.${encodeURIComponent(booking.appointmentId)}&transaction_type=eq.REFUND&select=id`,
    { method: 'GET', headers: serviceHeaders },
  )
  assert(Array.isArray(afterRefunds), 'refund result must be a list')
  assert(afterRefunds.length === beforeRefunds.length, 'NO_SHOW must not create a refund transaction')

  const afterCredits = await requestJson(
    `${API_URL}/rest/v1/customer_balance_movements?appointment_id=eq.${encodeURIComponent(booking.appointmentId)}&select=id`,
    { method: 'GET', headers: serviceHeaders },
  )
  assert(Array.isArray(afterCredits), 'credit result must be a list')
  assert(afterCredits.length === beforeCredits.length, 'NO_SHOW must not create customer credit')

  const afterFinancial = await requestJson(`${API_URL}/rest/v1/rpc/get_appointment_financial_summary`, {
    method: 'POST',
    headers: serviceHeaders,
    body: JSON.stringify({ p_appointment_id: booking.appointmentId }),
  })
  const balanceAfter = Number(afterFinancial.contract_balance)
  assert(balanceAfter > 0, 'NO_SHOW balance must remain due')
  assert(closeTo(balanceAfter, balanceBefore), `NO_SHOW balance changed from ${balanceBefore} to ${balanceAfter}`)

  const auditRows = await requestJson(
    `${API_URL}/rest/v1/audit_logs?entity_id=eq.${encodeURIComponent(booking.appointmentId)}&action=eq.APPOINTMENT_NO_SHOW&select=admin_user_id,origin,action,after_json`,
    { method: 'GET', headers: serviceHeaders },
  )
  assert(Array.isArray(auditRows) && auditRows.length === 1, 'NO_SHOW must create exactly one audit log')
  assert(/^[0-9a-f-]{36}$/i.test(String(auditRows[0].admin_user_id ?? '')), 'audit log must identify the admin author')
  assert(auditRows[0].origin === 'ADMIN', 'audit log origin must be ADMIN')
  assert(
    auditRows[0].after_json?.financial_rule === 'SERVICE_PERFORMED_NO_REFUND_NO_CREDIT_BALANCE_DUE_REMAINS',
    'audit log must record the no-refund/no-credit/open-balance rule',
  )

  const evidence = await requestJson(`${API_URL}/rest/v1/rpc/qa_get_no_show_evidence`, {
    method: 'POST',
    headers: serviceHeaders,
    body: JSON.stringify({ p_appointment_id: booking.appointmentId }),
  })
  assert(evidence.action === 'APPOINTMENT_NO_SHOW', 'authorship event action must identify NO_SHOW')
  assert(evidence.origin === 'ADMIN_UI', 'authorship event origin must identify the administrative screen')
  assert(/^[0-9a-f-]{36}$/i.test(String(evidence.admin_user_id ?? '')), 'authorship event must identify the admin author')
  assert(evidence.has_ip === true, 'authorship event must retain IP evidence')
  assert(evidence.has_user_agent === true, 'authorship event must retain user-agent evidence')
  assert(evidence.has_request_id === true, 'authorship event must retain request evidence')
})
