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

Deno.test('Item 7 known defect is isolated: NO_SHOW fails exactly because the RPC is absent', async () => {
  const booking = await createBooking('2035-11-12T10:00:00-03:00', 'no-show-known-failure')
  const adminToken = await createAdminSession()
  const result = await adminChange(adminToken, {
    action: 'NO_SHOW',
    appointment_id: booking.appointmentId,
    reason: 'Expected failure for Item 7',
  }, [400])
  const code = String(result.error?.code ?? '')
  assert(
    code.includes('service_admin_mark_appointment_no_show_evidenced'),
    `NO_SHOW must fail only on missing Item 7 RPC; received: ${code}`,
  )
})

// TODO(Item 7): remove `ignore: true` when
// public.service_admin_mark_appointment_no_show_evidenced is implemented/aligned.
// Item 7 is not complete while this expected-failure marker exists.
Deno.test({
  name: 'TODO(Item 7): NO_SHOW succeeds and persists NO_SHOW once missing RPC is restored',
  ignore: true,
  fn: async () => {
    const booking = await createBooking('2035-11-13T10:00:00-03:00', 'no-show-item-7-target')
    const adminToken = await createAdminSession()
    await adminChange(adminToken, {
      action: 'NO_SHOW',
      appointment_id: booking.appointmentId,
      reason: 'Item 7 target behavior',
    })
    const appointment = await readAppointment(booking.appointmentId)
    assert(appointment.status === 'NO_SHOW', `Item 7 target status must be NO_SHOW, got ${appointment.status}`)
  },
})
