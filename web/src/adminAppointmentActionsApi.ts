import { functionsBaseUrl, publicApiKey } from './supabase'

export type CancellationSettlementChoice = 'REFUND' | 'CREDIT' | null

export type AdminCancellationResult = {
  appointment_id: string
  status: 'CANCELLED'
  version?: number
  policy_action_id?: string | null
  policy_action_status?: string | null
  settlement_choice?: CancellationSettlementChoice
  penalty_amount?: number | string
  penalty_outstanding?: number | string
  refund_amount?: number | string
  credit_amount?: number | string
  coupon?: {
    coupon_id?: string
    code?: string
    amount?: number | string
    expires_at?: string
  } | null
  package_reversal_movement_id?: string | null
  google_sync_enqueued?: boolean
  already_cancelled?: boolean
}

export type AdminRefundProcessingResult = {
  policy_action_id: string
  appointment_id: string
  refund_status: string
  refunded_now: Array<Record<string, unknown>>
  remaining_refund_cash: number | string
  manual_refund_cash: number | string
  completed: boolean
}

export class AdminAppointmentActionError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

async function actionRequest(body: Record<string, unknown>, accessToken: string): Promise<any> {
  const response = await fetch(`${functionsBaseUrl}/admin-appointment-actions`, {
    method: 'POST',
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })

  if (!response.ok) {
    let code = 'ADMIN_APPOINTMENT_ACTION_FAILED'
    try {
      const payload = await response.json()
      code = payload?.error?.code ?? code
    } catch {
      // Keep generic code when provider returns non-JSON.
    }
    throw new AdminAppointmentActionError(code)
  }

  return response.json()
}

export async function cancelAdminAppointment(input: {
  appointmentId: string
  settlementChoice: CancellationSettlementChoice
  reason: string | null
  accessToken: string
}): Promise<AdminCancellationResult> {
  return actionRequest({
    action: 'CANCEL',
    appointment_id: input.appointmentId,
    settlement_choice: input.settlementChoice,
    reason: input.reason,
  }, input.accessToken)
}

export async function processAdminCancellationRefund(input: {
  policyActionId: string
  accessToken: string
}): Promise<AdminRefundProcessingResult> {
  return actionRequest({
    action: 'PROCESS_REFUND',
    policy_action_id: input.policyActionId,
  }, input.accessToken)
}
