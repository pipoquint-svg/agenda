type QueryError = { message?: string; code?: string } | null

type OpsQueryClient = {
  from(table: string): any
}

export type OpsScheduleDivergence = {
  id: string
  source: string
  reason: string
  status: string
  detected_at: string
  resource_id: string | null
  google_calendar_event_id: string | null
  desired_range: string | null
}

export type OpsResourceAllocation = {
  allocation_type: string
  status: string
  external_source: string | null
  google_calendar_event_id: string | null
  checkout_hold_id: string | null
  appointment_id: string | null
}

type CheckoutHoldState = {
  id: string
  status: string
  expires_at: string
}

type AppointmentState = {
  id: string
  status: string
  hold_expires_at: string | null
}

const BLOCKING_STATUSES = ['HELD', 'AWAITING_PAYMENT', 'CONFIRMED', 'BLOCKED', 'EXTERNAL_ACTIVE']

function isPureGoogleExternalBlock(allocation: OpsResourceAllocation): boolean {
  return allocation.allocation_type === 'EXTERNAL_BLOCK'
    && allocation.status === 'EXTERNAL_ACTIVE'
    && allocation.external_source === 'GOOGLE'
}

export function isGoogleOnlyTechnicalOverlap(
  divergence: OpsScheduleDivergence,
  allocations: OpsResourceAllocation[],
  activeCheckoutHoldIds: ReadonlySet<string> = new Set(),
  expiredAwaitingAppointmentIds: ReadonlySet<string> = new Set(),
): boolean {
  if (divergence.source !== 'GOOGLE'
    || divergence.reason !== 'GOOGLE_EVENT_CONFLICT'
    || !divergence.resource_id
    || !divergence.desired_range) return false

  const otherAllocations = allocations.filter((allocation) =>
    allocation.google_calendar_event_id !== divergence.google_calendar_event_id
    && BLOCKING_STATUSES.includes(allocation.status)
  )

  const hasAnotherGoogleBlock = otherAllocations.some(isPureGoogleExternalBlock)
  if (!hasAnotherGoogleBlock) return false

  const hasActionableNonGoogleBlock = otherAllocations.some((allocation) => {
    if (isPureGoogleExternalBlock(allocation)) return false

    if (allocation.status === 'HELD' && allocation.allocation_type === 'CHECKOUT_HOLD') {
      return Boolean(allocation.checkout_hold_id && activeCheckoutHoldIds.has(allocation.checkout_hold_id))
    }

    if (allocation.status === 'AWAITING_PAYMENT'
      && allocation.appointment_id
      && expiredAwaitingAppointmentIds.has(allocation.appointment_id)) return false

    return true
  })

  return !hasActionableNonGoogleBlock
}

function projectDivergence(row: OpsScheduleDivergence) {
  return {
    source: row.source,
    reason: row.reason,
    status: row.status,
    detected_at: row.detected_at,
  }
}

function throwOnQueryError(error: QueryError): void {
  if (error) throw new Error('OPS_ALERT_QUERY_FAILED')
}

export async function listActionableScheduleDivergences(
  client: OpsQueryClient,
  staleBefore: string,
  now: Date,
): Promise<Array<{ source: string; reason: string; status: string; detected_at: string }>> {
  const { data, error } = await client
    .from('schedule_divergences')
    .select('id,source,reason,status,detected_at,resource_id,google_calendar_event_id,desired_range')
    .eq('status', 'OPEN')
    .lte('detected_at', staleBefore)
  throwOnQueryError(error)

  const rows = (data ?? []) as OpsScheduleDivergence[]
  const actionable: Array<{ source: string; reason: string; status: string; detected_at: string }> = []

  for (const row of rows) {
    if (row.source !== 'GOOGLE'
      || row.reason !== 'GOOGLE_EVENT_CONFLICT'
      || !row.resource_id
      || !row.desired_range) {
      actionable.push(projectDivergence(row))
      continue
    }

    const allocationsResult = await client
      .from('resource_allocations')
      .select('allocation_type,status,external_source,google_calendar_event_id,checkout_hold_id,appointment_id')
      .eq('resource_id', row.resource_id)
      .in('status', BLOCKING_STATUSES)
      .filter('occupied_range', 'ov', row.desired_range)
    throwOnQueryError(allocationsResult.error)

    const allocations = (allocationsResult.data ?? []) as OpsResourceAllocation[]
    const otherAllocations = allocations.filter((allocation) =>
      allocation.google_calendar_event_id !== row.google_calendar_event_id
    )

    const holdIds = [...new Set(otherAllocations
      .filter((allocation) => allocation.status === 'HELD'
        && allocation.allocation_type === 'CHECKOUT_HOLD'
        && allocation.checkout_hold_id)
      .map((allocation) => allocation.checkout_hold_id as string))]

    const appointmentIds = [...new Set(otherAllocations
      .filter((allocation) => allocation.status === 'AWAITING_PAYMENT' && allocation.appointment_id)
      .map((allocation) => allocation.appointment_id as string))]

    const activeCheckoutHoldIds = new Set<string>()
    if (holdIds.length > 0) {
      const holdResult = await client
        .from('checkout_holds')
        .select('id,status,expires_at')
        .in('id', holdIds)
      throwOnQueryError(holdResult.error)
      for (const hold of (holdResult.data ?? []) as CheckoutHoldState[]) {
        if (hold.status === 'ACTIVE' && Date.parse(hold.expires_at) > now.getTime()) {
          activeCheckoutHoldIds.add(hold.id)
        }
      }
    }

    const expiredAwaitingAppointmentIds = new Set<string>()
    if (appointmentIds.length > 0) {
      const appointmentResult = await client
        .from('appointments')
        .select('id,status,hold_expires_at')
        .in('id', appointmentIds)
      throwOnQueryError(appointmentResult.error)
      for (const appointment of (appointmentResult.data ?? []) as AppointmentState[]) {
        if (appointment.status === 'AWAITING_PAYMENT'
          && appointment.hold_expires_at
          && Date.parse(appointment.hold_expires_at) <= now.getTime()) {
          expiredAwaitingAppointmentIds.add(appointment.id)
        }
      }
    }

    if (!isGoogleOnlyTechnicalOverlap(
      row,
      allocations,
      activeCheckoutHoldIds,
      expiredAwaitingAppointmentIds,
    )) actionable.push(projectDivergence(row))
  }

  return actionable
}
