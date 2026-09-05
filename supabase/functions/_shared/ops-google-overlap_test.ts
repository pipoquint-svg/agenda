import {
  isGoogleOnlyTechnicalOverlap,
  type OpsResourceAllocation,
  type OpsScheduleDivergence,
} from './ops-google-overlap.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

const divergence: OpsScheduleDivergence = {
  id: '00000000-0000-0000-0000-000000000001',
  source: 'GOOGLE',
  reason: 'GOOGLE_EVENT_CONFLICT',
  status: 'OPEN',
  detected_at: '2035-01-15T11:00:00.000Z',
  resource_id: '00000000-0000-0000-0000-000000000002',
  google_calendar_event_id: 'event-a',
  desired_range: '["2035-01-15 19:00:00+00","2035-01-15 22:00:00+00")',
}

function allocation(overrides: Partial<OpsResourceAllocation> = {}): OpsResourceAllocation {
  return {
    allocation_type: 'EXTERNAL_BLOCK',
    status: 'EXTERNAL_ACTIVE',
    external_source: 'GOOGLE',
    google_calendar_event_id: 'event-b',
    checkout_hold_id: null,
    appointment_id: null,
    ...overrides,
  }
}

Deno.test('Google x Google only is technical and not a critical ops incident', () => {
  assert(
    isGoogleOnlyTechnicalOverlap(divergence, [allocation()]),
    'another active Google external block should prove a technical overlap',
  )
})

Deno.test('Google overlap plus manual block remains actionable', () => {
  const rows = [
    allocation(),
    allocation({
      allocation_type: 'MANUAL_BLOCK',
      status: 'BLOCKED',
      external_source: null,
      google_calendar_event_id: null,
    }),
  ]
  assert(
    !isGoogleOnlyTechnicalOverlap(divergence, rows),
    'manual blocker must keep divergence actionable',
  )
})

Deno.test('Google conflict without another provable Google block remains actionable', () => {
  assert(
    !isGoogleOnlyTechnicalOverlap(divergence, []),
    'absence of a proven Google blocker must fail closed operationally',
  )
})

Deno.test('expired checkout hold does not turn Google-only overlap into a critical incident', () => {
  const rows = [
    allocation(),
    allocation({
      allocation_type: 'CHECKOUT_HOLD',
      status: 'HELD',
      external_source: null,
      google_calendar_event_id: null,
      checkout_hold_id: 'hold-expired',
    }),
  ]
  assert(
    isGoogleOnlyTechnicalOverlap(divergence, rows, new Set()),
    'expired/non-active checkout hold must be ignored',
  )
})

Deno.test('active checkout hold keeps Google conflict actionable', () => {
  const rows = [
    allocation(),
    allocation({
      allocation_type: 'CHECKOUT_HOLD',
      status: 'HELD',
      external_source: null,
      google_calendar_event_id: null,
      checkout_hold_id: 'hold-active',
    }),
  ]
  assert(
    !isGoogleOnlyTechnicalOverlap(divergence, rows, new Set(['hold-active'])),
    'active checkout hold must keep divergence actionable',
  )
})

Deno.test('expired awaiting-payment appointment does not create a false critical incident', () => {
  const rows = [
    allocation(),
    allocation({
      allocation_type: 'APPOINTMENT',
      status: 'AWAITING_PAYMENT',
      external_source: null,
      google_calendar_event_id: null,
      appointment_id: 'appointment-expired',
    }),
  ]
  assert(
    isGoogleOnlyTechnicalOverlap(
      divergence,
      rows,
      new Set(),
      new Set(['appointment-expired']),
    ),
    'expired awaiting-payment allocation must be ignored',
  )
})

Deno.test('active awaiting-payment appointment keeps Google conflict actionable', () => {
  const rows = [
    allocation(),
    allocation({
      allocation_type: 'APPOINTMENT',
      status: 'AWAITING_PAYMENT',
      external_source: null,
      google_calendar_event_id: null,
      appointment_id: 'appointment-active',
    }),
  ]
  assert(
    !isGoogleOnlyTechnicalOverlap(divergence, rows),
    'active awaiting-payment appointment must keep divergence actionable',
  )
})
