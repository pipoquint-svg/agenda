// HTTP boundary shared by the workforce Edge Functions (ADR-017).
// The browser only chooses a command, an idempotency key and a command payload.
// Identity (actor, tenant, employer, employee) is resolved server-side; the
// SQL command validates the payload again and rejects forged fields.

export const workforceCorsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

export function workforceJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...workforceCorsHeaders,
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  })
}

export type WorkforceCommandEnvelope<C extends string> = {
  command: C
  idempotencyKey: string
  payload: Record<string, unknown>
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ENVELOPE_KEYS = ['command', 'idempotency_key', 'payload']

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function parseWorkforceCommand<C extends string>(
  body: unknown,
  allowedCommands: readonly C[],
): WorkforceCommandEnvelope<C> {
  if (!isPlainObject(body)) throw new Error('WORKFORCE_REQUEST_INVALID')
  const keys = Object.keys(body)
  if (keys.length !== ENVELOPE_KEYS.length || keys.some((key) => !ENVELOPE_KEYS.includes(key))) {
    throw new Error('WORKFORCE_REQUEST_INVALID')
  }
  const command = body.command
  if (typeof command !== 'string' || !(allowedCommands as readonly string[]).includes(command)) {
    throw new Error('WORKFORCE_COMMAND_UNKNOWN')
  }
  const idempotencyKey = body.idempotency_key
  if (typeof idempotencyKey !== 'string' || !UUID_PATTERN.test(idempotencyKey)) {
    throw new Error('WORKFORCE_IDEMPOTENCY_KEY_REQUIRED')
  }
  if (!isPlainObject(body.payload)) throw new Error('WORKFORCE_PAYLOAD_INVALID')
  return { command: command as C, idempotencyKey: idempotencyKey.toLowerCase(), payload: body.payload }
}

// Only stable, shaped error codes leave the boundary. Database messages that do
// not follow the WORKFORCE_/ADMIN_ code contract are collapsed so no internal
// detail (or any user-provided free text) is echoed back or logged by callers.
const CODE_PATTERN = /^(WORKFORCE|ADMIN)_[A-Z0-9_]+(?::[a-z_]+)?$/

export function workforceErrorCode(error: unknown): string {
  const message = error instanceof Error ? error.message : typeof error === 'string' ? error : ''
  const candidate = message.trim()
  return CODE_PATTERN.test(candidate) ? candidate : 'WORKFORCE_REQUEST_FAILED'
}

export function workforceErrorStatus(code: string): number {
  if (code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED') return 401
  if (
    code === 'WORKFORCE_OWNER_REQUIRED'
    || code === 'WORKFORCE_EMPLOYEE_REQUIRED'
    || code === 'WORKFORCE_TENANT_AMBIGUOUS'
    || code === 'ADMIN_PERMISSION_DENIED'
  ) {
    return 403
  }
  if (code.endsWith('_NOT_FOUND')) return 404
  if (code === 'WORKFORCE_IDEMPOTENCY_KEY_REUSED') return 409
  if (code === 'WORKFORCE_REQUEST_FAILED') return 500
  return 400
}

export function workforceErrorResponse(error: unknown): Response {
  const code = workforceErrorCode(error)
  return workforceJson({ error: { code } }, workforceErrorStatus(code))
}
