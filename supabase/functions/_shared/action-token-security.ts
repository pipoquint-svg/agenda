export const ACTION_ACCESS_MINIMUM_RESPONSE_MS = 120
export const PERSONAL_LINK_WARNING = 'link pessoal, válido por tempo limitado, não encaminhe'

export type ActionAccessErrorMapping = {
  code: string
  status: number
}

const invalidLinkSignals = [
  'APPOINTMENT_TOKEN_INVALID',
  'APPOINTMENT_TOKEN_EXPIRED',
  'APPOINTMENT_TOKEN_REVOKED',
  'TOKEN_SCOPE_DENIED',
  'ACTION_TOKEN_SCOPE_INVALID',
  'APPOINTMENT_NOT_CANCELLABLE',
  'APPOINTMENT_NOT_RESCHEDULABLE',
  'CLIENT_RESCHEDULE_ACTION_INVALID',
  'LINK_INVALID_OR_EXPIRED',
]

export function isActionOperationAllowed(operation: string, scope: string): boolean {
  if (operation === 'RESOLVE') return true
  if (operation === 'VERIFY_EMAIL') return scope === 'CANCEL' || scope === 'RESCHEDULE'
  if (operation === 'CANCEL_PREVIEW' || operation === 'EXECUTE_CANCEL') return scope === 'CANCEL'
  if (
    operation === 'RESCHEDULE_SLOTS'
    || operation === 'RESCHEDULE_CREATE_HOLD'
    || operation === 'EXECUTE_RESCHEDULE'
  ) return scope === 'RESCHEDULE'
  return false
}

export function mapActionAccessError(raw: string): ActionAccessErrorMapping {
  if (raw === 'RATE_LIMITED') return { code: 'ACTION_ACCESS_RATE_LIMITED', status: 429 }
  if (raw.startsWith('RATE_LIMIT_BACKEND_FAILED')) {
    return { code: 'ACTION_ACCESS_TEMPORARY_FAILURE', status: 503 }
  }
  if (raw === 'ACTION_OPERATION_INVALID') return { code: 'ACTION_REQUEST_INVALID', status: 400 }
  if (raw.includes('CANCEL_CONFIRMATION_REQUIRED') || raw.includes('RESCHEDULE_CONFIRMATION_REQUIRED')) {
    return { code: 'ACTION_CONFIRMATION_REQUIRED', status: 400 }
  }
  if (raw.includes('CANCEL_EMAIL_VERIFICATION_REQUIRED') || raw.includes('RESCHEDULE_EMAIL_VERIFICATION_REQUIRED')) {
    return { code: 'ACTION_VERIFICATION_REQUIRED', status: 400 }
  }
  if (raw.includes('RESCHEDULE_DIFFERENCE_PAYMENT_REQUIRED')) {
    return { code: 'ACTION_PAYMENT_REQUIRED', status: 409 }
  }
  if (raw.includes('RESCHEDULE_HOLD_EXPIRED')) return { code: 'RESCHEDULE_HOLD_EXPIRED', status: 409 }
  if (raw.includes('CLIENT_RESCHEDULE_LIMIT_REACHED')) {
    return { code: 'CLIENT_RESCHEDULE_LIMIT_REACHED', status: 409 }
  }
  if (
    raw.includes('RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED')
    || raw.includes('APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING')
    || raw.includes('APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID')
  ) {
    console.error('[OPERATION_ALERT] APPOINTMENT_CHANGE_REQUIRES_ASSISTANCE', {
      reason: raw.includes('APPOINTMENT_CHANGE_POLICY') ? 'HISTORICAL_POLICY_SNAPSHOT_UNAVAILABLE' : 'PACKAGE_RECONCILIATION_REQUIRED',
    })
    return { code: 'RESCHEDULE_REQUIRES_ASSISTANCE', status: 409 }
  }
  if (raw.includes('RESCHEDULE_DATE_INVALID') || raw.includes('RESCHEDULE_TIME_INVALID')) {
    return { code: 'ACTION_REQUEST_INVALID', status: 400 }
  }
  if (invalidLinkSignals.some((signal) => raw.includes(signal))) {
    return { code: 'LINK_INVALID_OR_EXPIRED', status: 400 }
  }
  return { code: 'ACTION_ACCESS_TEMPORARY_FAILURE', status: 503 }
}

export function actionAccessRemainingDelay(startedAt: number, now = Date.now()): number {
  return Math.max(0, ACTION_ACCESS_MINIMUM_RESPONSE_MS - (now - startedAt))
}
