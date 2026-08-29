import {
  isRecipientAllowed,
  isScopeEnabled,
  maskEmail,
} from './transactional-email.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('transactional email masks recipients in logs', () => {
  assert(maskEmail('Cliente.Teste@Example.com') === 'c***@example.com', 'email mask mismatch')
  assert(maskEmail('invalid') === '***', 'invalid email must be fully masked')
})

Deno.test('transactional email requires allowlist while real recipients are disabled', () => {
  const allowlist = 'teste1@example.com, TESTE2@example.com'
  assert(isRecipientAllowed('teste1@example.com', false, allowlist), 'allowlisted recipient must pass')
  assert(isRecipientAllowed('teste2@example.com', false, allowlist), 'allowlist must be case insensitive')
  assert(!isRecipientAllowed('cliente-real@example.com', false, allowlist), 'real recipient must fail closed')
  assert(isRecipientAllowed('cliente-real@example.com', true, ''), 'explicit live flag must allow recipient')
})

Deno.test('transactional email scopes fail closed', () => {
  assert(isScopeEnabled('BLACKSHEEP', 'BLACKSHEEP'), 'configured scope must pass')
  assert(!isScopeEnabled('SABRINA', 'BLACKSHEEP'), 'unconfigured scope must fail closed')
})
