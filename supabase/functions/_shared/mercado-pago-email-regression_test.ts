import { payerEmailForProvider } from './mercado-pago-email.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('Mercado Pago provider preserves reservation payer email', () => {
  assert(
    payerEmailForProvider('cliente.teste@example.com') === 'cliente.teste@example.com',
    'provider payer email must stay aligned with the payer used in the Brick',
  )
})
