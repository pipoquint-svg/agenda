import {
  ACTION_ACCESS_MINIMUM_RESPONSE_MS,
  actionAccessRemainingDelay,
  isActionOperationAllowed,
  mapActionAccessError,
} from './action-token-security.ts'

Deno.test('invalid token causes are externally indistinguishable', () => {
  const causes = [
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

  for (const cause of causes) {
    const mapped = mapActionAccessError(cause)
    if (mapped.code !== 'LINK_INVALID_OR_EXPIRED' || mapped.status !== 400) {
      throw new Error(`leaked token cause ${cause}: ${JSON.stringify(mapped)}`)
    }
  }
})

Deno.test('scope matrix rejects cross-action use', () => {
  if (!isActionOperationAllowed('CANCEL_PREVIEW', 'CANCEL')) throw new Error('cancel should allow cancel preview')
  if (isActionOperationAllowed('CANCEL_PREVIEW', 'RESCHEDULE')) throw new Error('reschedule token leaked into cancel')
  if (!isActionOperationAllowed('RESCHEDULE_SLOTS', 'RESCHEDULE')) throw new Error('reschedule should allow slots')
  if (isActionOperationAllowed('RESCHEDULE_SLOTS', 'CANCEL')) throw new Error('cancel token leaked into reschedule')
  if (isActionOperationAllowed('VERIFY_EMAIL', 'EDIT_DETAILS')) throw new Error('details token should not verify finance email')
})

Deno.test('response timing helper preserves minimum floor', () => {
  const startedAt = 1_000
  const remaining = actionAccessRemainingDelay(startedAt, startedAt + 20)
  if (remaining !== ACTION_ACCESS_MINIMUM_RESPONSE_MS - 20) throw new Error(`unexpected delay ${remaining}`)
  if (actionAccessRemainingDelay(startedAt, startedAt + ACTION_ACCESS_MINIMUM_RESPONSE_MS + 1) !== 0) {
    throw new Error('delay must never be negative')
  }
})

Deno.test('operational failures remain generic without becoming invalid-link disclosures', () => {
  const mapped = mapActionAccessError('UNEXPECTED_DATABASE_FAILURE')
  if (mapped.code !== 'ACTION_ACCESS_TEMPORARY_FAILURE' || mapped.status !== 503) {
    throw new Error(`unexpected operational mapping ${JSON.stringify(mapped)}`)
  }
})
