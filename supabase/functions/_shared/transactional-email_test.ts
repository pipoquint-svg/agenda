import {
  buildConfirmationEmail,
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

Deno.test('confirmation renderer escapes HTML and keeps reservation facts', () => {
  const message = buildConfirmationEmail({
    brandName: 'BlackSheep Estúdio Criativo',
    customerName: '<Cliente>',
    serviceName: 'Locação <Studio>',
    startAt: '2026-09-15T15:00:00Z',
    durationMinutes: 120,
    publicCode: 'ABC123',
    totalValue: 1000,
    paidValue: 500,
    balanceValue: 500,
  })

  assert(message.subject.includes('ABC123'), 'subject must contain public code')
  assert(message.text.includes('Locação <Studio>'), 'plain text must contain service name')
  assert(message.text.includes('R$'), 'plain text must contain financial summary')
  assert(!message.html.includes('<Cliente>'), 'customer HTML must be escaped')
  assert(message.html.includes('&lt;Cliente&gt;'), 'escaped customer must be present')
  assert(message.html.includes('ABC123'), 'HTML must contain public code')
})
