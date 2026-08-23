import { functionsBaseUrl, publicApiKey } from './supabase'

export type ActionScope = 'CANCEL' | 'RESCHEDULE'

export type ActionEnvelope<T> = {
  data: T
}

export type ActionAccessFailure = {
  error?: { code?: string }
  data?: Record<string, unknown>
}

export class AppointmentActionError extends Error {
  code: string
  status: number
  data: Record<string, unknown> | null

  constructor(code: string, status: number, data: Record<string, unknown> | null = null) {
    super(code)
    this.code = code
    this.status = status
    this.data = data
  }
}

export type ActionResolve = {
  valid: true
  scope: ActionScope
  expires_at: string | null
  accessed_at: string
  warning: string
}

export type CancelPreview = ActionResolve & {
  requires_explicit_confirmation: true
  requires_email_verification: true
  financial: {
    contract_value: number
    penalty_amount: number
    refund_amount: number
    settlement_default: 'REFUND' | null
  }
}

export type RescheduleSlot = {
  slot_start_at: string
  slot_end_at: string
  core_start_at: string
  core_end_at: string
  pre_service_minutes: number
  post_service_minutes: number
  duration_minutes: number
}

export type RescheduleSlots = {
  valid: true
  scope: 'RESCHEDULE'
  local_date: string
  slots: RescheduleSlot[]
  expires_at: string | null
  accessed_at: string
  warning: string
}

export type RescheduleProposal = {
  policy_action_id: string
  new_slot: {
    checkout_hold_id?: string
    expires_at?: string
    slot_start_at?: string
    slot_end_at?: string
    core_start_at?: string
    core_end_at?: string
  }
  requires_explicit_confirmation: true
  requires_email_verification: boolean
  requires_payment: boolean
  financial: {
    contract_value: number
    new_contract_value: number
    penalty_amount: number
    difference_due: number
    excess_amount: number
  }
}

function newRequestId(): string {
  return crypto.randomUUID()
}

async function actionRequest<T>(
  token: string,
  scope: ActionScope,
  operation: string,
  body: Record<string, unknown> = {},
): Promise<T> {
  const response = await fetch(`${functionsBaseUrl}/appointment-action-access`, {
    method: 'POST',
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
      'content-type': 'application/json',
      'x-appointment-token': token,
      'x-request-id': newRequestId(),
    },
    body: JSON.stringify({ operation, scope, ...body }),
  })

  let payload: ActionEnvelope<T> | ActionAccessFailure | null = null
  try {
    payload = await response.json() as ActionEnvelope<T> | ActionAccessFailure
  } catch {
    payload = null
  }

  if (!response.ok) {
    const failure = payload as ActionAccessFailure | null
    throw new AppointmentActionError(
      failure?.error?.code ?? 'ACTION_ACCESS_TEMPORARY_FAILURE',
      response.status,
      failure?.data && typeof failure.data === 'object' ? failure.data : null,
    )
  }

  const envelope = payload as ActionEnvelope<T> | null
  if (!envelope?.data) throw new AppointmentActionError('ACTION_ACCESS_TEMPORARY_FAILURE', 503)
  return envelope.data
}

export function resolveAppointmentAction(token: string, scope: ActionScope): Promise<ActionResolve> {
  return actionRequest(token, scope, 'RESOLVE')
}

export function getCancelPreview(token: string): Promise<CancelPreview> {
  return actionRequest(token, 'CANCEL', 'CANCEL_PREVIEW')
}

export function executeCancellation(
  token: string,
  email: string,
  sessionId: string,
  reason?: string,
): Promise<Record<string, unknown>> {
  return actionRequest(token, 'CANCEL', 'EXECUTE_CANCEL', {
    email,
    confirmed: true,
    session_id: sessionId,
    reason: reason?.trim() || null,
  })
}

export function getRescheduleSlots(token: string, localDate: string): Promise<RescheduleSlots> {
  return actionRequest(token, 'RESCHEDULE', 'RESCHEDULE_SLOTS', { local_date: localDate })
}

export function createRescheduleProposal(token: string, requestedStartAt: string): Promise<RescheduleProposal> {
  return actionRequest(token, 'RESCHEDULE', 'RESCHEDULE_CREATE_HOLD', { requested_start_at: requestedStartAt })
}

export function executeReschedule(
  token: string,
  policyActionId: string,
  sessionId: string,
  email?: string,
): Promise<Record<string, unknown>> {
  return actionRequest(token, 'RESCHEDULE', 'EXECUTE_RESCHEDULE', {
    policy_action_id: policyActionId,
    email: email?.trim() || null,
    confirmed: true,
    session_id: sessionId,
  })
}
