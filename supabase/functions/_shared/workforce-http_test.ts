import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import {
  parseWorkforceCommand,
  workforceErrorCode,
  workforceErrorStatus,
  workforceMonthParam,
  workforceUuidParam,
  workforcePdfResponse,
  workforceViewArgs,
} from './workforce-http.ts'

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

Deno.test('validates read view parameters', () => {
  assertEquals(workforceMonthParam(new URL('https://x/?month=2026-10')), '2026-10')
  assertThrows(() => workforceMonthParam(new URL('https://x/?month=2026-13')), Error, 'WORKFORCE_FIELD_INVALID:month')
  assertThrows(() => workforceMonthParam(new URL('https://x/')), Error, 'WORKFORCE_FIELD_INVALID:month')
  assertEquals(workforceUuidParam(new URL(`https://x/?employee_id=${KEY.toUpperCase()}`), 'employee_id'), KEY)
  assertThrows(() => workforceUuidParam(new URL('https://x/?employee_id=1;drop'), 'employee_id'), Error, 'WORKFORCE_FIELD_INVALID:employee_id')
})

Deno.test('resolves read views and rejects unknown ones', () => {
  const views = {
    setup: { rpc: 'rpc_setup', args: () => ({}) },
    summary: { rpc: 'rpc_summary', args: (url: URL) => ({ p_month: workforceMonthParam(url) }) },
  }
  assertEquals(workforceViewArgs(new URL('https://x/'), views, 'setup'), { rpc: 'rpc_setup', args: {} })
  assertEquals(workforceViewArgs(new URL('https://x/?view=summary&month=2026-09'), views, 'setup'),
    { rpc: 'rpc_summary', args: { p_month: '2026-09' } })
  assertThrows(() => workforceViewArgs(new URL('https://x/?view=__proto__'), views, 'setup'), Error, 'WORKFORCE_VIEW_UNKNOWN')
  assertThrows(() => workforceViewArgs(new URL('https://x/?view=summary'), views, 'setup'), Error, 'WORKFORCE_FIELD_INVALID:month')
})

Deno.test('PDF responses are attachments, never cached, with a sanitized filename', () => {
  const response = workforcePdfResponse(new Uint8Array([37, 80, 68, 70]), 'jornada 2026-09"\r\n.pdf')
  assertEquals(response.headers.get('content-type'), 'application/pdf')
  assertEquals(response.headers.get('cache-control'), 'no-store')
  assertEquals(response.headers.get('content-disposition'), 'attachment; filename="jornada_2026-09___.pdf"')
})
