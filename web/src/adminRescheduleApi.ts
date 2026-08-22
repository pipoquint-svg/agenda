import { functionsBaseUrl, publicApiKey } from './supabase'

export type AdminRescheduleSlot = {
  slot_start_at: string
  slot_end_at: string
  core_start_at: string
  core_end_at: string
  pre_service_minutes: number
  post_service_minutes: number
  duration_minutes: number
  package_delta_seconds?: number
}

export type AdminRescheduleHold = {
  policy_action_id: string
  policy_action_status: 'PREVIEW' | 'AWAITING_PENALTY_PAYMENT' | string
  appointment_id: string
  original_start_at: string
  new_slot: {
    checkout_hold_id: string
    expires_at: string
    slot_start_at: string
    slot_end_at: string
    core_start_at: string
    core_end_at: string
  }
  penalty_type: string
  penalty_value: number | string
  penalty_due_now: number | string
  package_reconciliation?: {
    uses_package?: boolean
    delta_seconds?: number | string
    is_special_period?: boolean
  }
}

export type AdminRescheduleApplyResult = {
  policy_action_id: string
  appointment_id: string
  status: 'APPLIED'
  old_start_at?: string
  new_start_at?: string
  new_end_at?: string
  appointment_version?: number
  google_sync_enqueued?: boolean
  already_applied?: boolean
  package_reconciliation?: Record<string, unknown>
}

export type AdminReschedulePenaltyPayment = {
  policy_action_id: string
  payment_transaction_id: string
  cash_amount: number | string
  status: 'PAID'
  idempotent_replay: boolean
}

export class AdminRescheduleError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

async function call(body: Record<string, unknown>, accessToken: string): Promise<any> {
  const response = await fetch(`${functionsBaseUrl}/admin-reschedule-actions`, {
    method: 'POST',
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })

  if (!response.ok) {
    let code = 'ADMIN_RESCHEDULE_ACTION_FAILED'
    try {
      const data = await response.json()
      code = data?.error?.code ?? code
    } catch {
      // Stable generic error for non-JSON failures.
    }
    throw new AdminRescheduleError(code)
  }
  return response.json()
}

export async function listAdminRescheduleSlots(input: {
  appointmentId: string
  localDate: string
  accessToken: string
}): Promise<AdminRescheduleSlot[]> {
  const result = await call({ action: 'LIST_SLOTS', appointment_id: input.appointmentId, local_date: input.localDate }, input.accessToken)
  return result.slots ?? []
}

export async function createAdminRescheduleHold(input: {
  appointmentId: string
  requestedStartAt: string
  accessToken: string
}): Promise<AdminRescheduleHold> {
  return call({ action: 'CREATE_HOLD', appointment_id: input.appointmentId, requested_start_at: input.requestedStartAt }, input.accessToken)
}

export async function registerAdminReschedulePenalty(input: {
  appointmentId: string
  policyActionId: string
  method: 'PIX' | 'CARD' | 'CASH' | 'TRANSFER' | 'OTHER'
  notes: string | null
  accessToken: string
}): Promise<AdminReschedulePenaltyPayment> {
  return call({
    action: 'REGISTER_PENALTY',
    appointment_id: input.appointmentId,
    policy_action_id: input.policyActionId,
    method: input.method,
    notes: input.notes,
  }, input.accessToken)
}

export async function applyAdminReschedule(input: {
  appointmentId: string
  policyActionId: string
  accessToken: string
}): Promise<AdminRescheduleApplyResult> {
  return call({ action: 'APPLY', appointment_id: input.appointmentId, policy_action_id: input.policyActionId }, input.accessToken)
}
