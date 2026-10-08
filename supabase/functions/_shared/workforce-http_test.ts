import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import { parseWorkforceCommand, workforceErrorCode, workforceErrorStatus } from './workforce-http.ts'

const COMMANDS = ['SAVE_EMPLOYER', 'SAVE_EMPLOYEE'] as const
const KEY = '5b0f6f5e-6c1f-4d3e-9d3a-1f2e3d4c5b6a'

Deno.test('accepts a well-formed command envelope', () => {
  const parsed = parseWorkforceCommand(
    { command: 'SAVE_EMPLOYER', idempotency_key: KEY.toUpperCase(), payload: { legal_name: 'X' } },
    COMMANDS,
  )
  assertEquals(parsed.command, 'SAVE_EMPLOYER')
  assertEquals(parsed.idempotencyKey, KEY)
  assertEquals(parsed.payload, { legal_name: 'X' })
})

Deno.test('rejects identity fields smuggled next to the envelope', () => {
  assertThrows(
    () => parseWorkforceCommand({ command: 'SAVE_EMPLOYER', idempotency_key: KEY, payload: {}, tenant_id: KEY }, COMMANDS),
    Error,
    'WORKFORCE_REQUEST_INVALID',
  )
  assertThrows(
    () => parseWorkforceCommand({ command: 'SAVE_EMPLOYER', idempotency_key: KEY, payload: {}, employee_id: KEY }, COMMANDS),
    Error,
    'WORKFORCE_REQUEST_INVALID',
  )
})

Deno.test('rejects unknown commands, missing keys and non-object payloads', () => {
  assertThrows(() => parseWorkforceCommand({ command: 'CLOSE_PERIOD', idempotency_key: KEY, payload: {} }, COMMANDS), Error, 'WORKFORCE_COMMAND_UNKNOWN')
  assertThrows(() => parseWorkforceCommand({ command: 'SAVE_EMPLOYER', idempotency_key: 'abc', payload: {} }, COMMANDS), Error, 'WORKFORCE_IDEMPOTENCY_KEY_REQUIRED')
  assertThrows(() => parseWorkforceCommand({ command: 'SAVE_EMPLOYER', idempotency_key: KEY, payload: [] }, COMMANDS), Error, 'WORKFORCE_PAYLOAD_INVALID')
  assertThrows(() => parseWorkforceCommand(null, COMMANDS), Error, 'WORKFORCE_REQUEST_INVALID')
})

Deno.test('only shaped error codes leave the boundary', () => {
  assertEquals(workforceErrorCode(new Error('WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:tenant_id')), 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:tenant_id')
  assertEquals(workforceErrorCode(new Error('duplicate key value violates unique constraint "x"')), 'WORKFORCE_REQUEST_FAILED')
  assertEquals(workforceErrorCode(new Error('WORKFORCE_X: observação sensível')), 'WORKFORCE_REQUEST_FAILED')
})

Deno.test('maps error codes to HTTP status', () => {
  assertEquals(workforceErrorStatus('ADMIN_AUTH_REQUIRED'), 401)
  assertEquals(workforceErrorStatus('WORKFORCE_OWNER_REQUIRED'), 403)
  assertEquals(workforceErrorStatus('WORKFORCE_EMPLOYEE_REQUIRED'), 403)
  assertEquals(workforceErrorStatus('WORKFORCE_EMPLOYER_NOT_FOUND'), 404)
  assertEquals(workforceErrorStatus('WORKFORCE_IDEMPOTENCY_KEY_REUSED'), 409)
  assertEquals(workforceErrorStatus('WORKFORCE_CNPJ_INVALID'), 400)
  assertEquals(workforceErrorStatus('WORKFORCE_REQUEST_FAILED'), 500)
})
