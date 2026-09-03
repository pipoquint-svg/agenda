import { reconcileMercadoPagoCandidate, type ReconcileCandidate } from './logic.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function orderFor(candidate: ReconcileCandidate, status: string, externalReference = candidate.id) {
  return {
    id: candidate.provider_payment_id,
    external_reference: externalReference,
    total_amount: Number(candidate.cash_amount),
    status,
    transactions: {
      payments: [{
        id: 'provider-payment-1',
        status,
        status_detail: status === 'processed' ? 'accredited' : 'pending_waiting_payment',
        amount: Number(candidate.cash_amount),
        payment_method: { id: 'pix', type: 'bank_transfer' },
        last_updated_date: '2026-09-03T12:00:00Z',
        created_date: '2026-09-03T11:55:00Z',
      }],
    },
  }
}

const candidate: ReconcileCandidate = {
  id: '11111111-1111-4111-8111-111111111111',
  appointment_id: '22222222-2222-4222-8222-222222222222',
  cash_amount: 50,
  method: 'PIX',
  provider_payment_id: 'ORD_TEST_RECONCILE_1',
  updated_at: '2026-09-03T11:55:00Z',
}

Deno.test('lost webhook converges pending local payment to approved provider state', async () => {
  const applyCalls: Array<Record<string, unknown>> = []
  let quarantineCalls = 0
  const deps = {
    getOrder: async () => orderFor(candidate, 'processed'),
    quarantine: async () => { quarantineCalls += 1 },
    apply: async (input: Record<string, unknown>) => {
      applyCalls.push(input)
      return { transaction_status: 'APPROVED', idempotent_replay: applyCalls.length > 1 }
    },
  }

  const first = await reconcileMercadoPagoCandidate(candidate, deps)
  const second = await reconcileMercadoPagoCandidate(candidate, deps)

  assert(first.normalized_status === 'APPROVED', 'provider approved status was not normalized')
  assert(first.transaction_status === 'APPROVED', 'state machine result did not converge to approved')
  assert(first.changed === true, 'pending to approved must be reported as changed')
  assert(second.event_key === first.event_key, 'repeated reconciliation must use a deterministic event key')
  assert(applyCalls.length === 2, 'both periodic passes must reuse the same state-machine boundary')
  assert(quarantineCalls === 0, 'valid provider state must not be quarantined')
})

Deno.test('pending provider state remains pending and is safe to retry later', async () => {
  const result = await reconcileMercadoPagoCandidate(candidate, {
    getOrder: async () => orderFor(candidate, 'created'),
    quarantine: async () => { throw new Error('unexpected quarantine') },
    apply: async () => ({ transaction_status: 'PENDING', idempotent_replay: false }),
  })

  assert(result.normalized_status === 'PENDING', 'pending provider state was not preserved')
  assert(result.changed === false, 'pending to pending must not be reported as a state change')
})

Deno.test('provider mismatch is quarantined and never applied', async () => {
  let quarantined = 0
  let applied = 0
  let thrown = ''
  try {
    await reconcileMercadoPagoCandidate(candidate, {
      getOrder: async () => orderFor(candidate, 'processed', 'different-transaction'),
      quarantine: async () => { quarantined += 1 },
      apply: async () => { applied += 1; return {} },
    })
  } catch (error) {
    thrown = error instanceof Error ? error.message : String(error)
  }

  assert(thrown === 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED', 'mismatch must fail closed')
  assert(quarantined === 1, 'mismatch must be quarantined exactly once')
  assert(applied === 0, 'mismatched provider state must never reach the financial state machine')
})
