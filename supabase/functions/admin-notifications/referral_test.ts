import { assertEquals } from 'jsr:@std/assert@1'
import { chunks, referralBatchSize, referralCodeDeliveryKey, saoPauloDay } from './referral.ts'

Deno.test('the day follows São Paulo, not UTC', () => {
  assertEquals(saoPauloDay(new Date('2026-10-22T02:30:00Z')), '2026-10-21')
  assertEquals(saoPauloDay(new Date('2026-10-22T03:30:00Z')), '2026-10-22')
})

Deno.test('one referral code message per customer and day', () => {
  assertEquals(referralCodeDeliveryKey('t1', 'c1', '2026-10-21'), 'rewards-referral-code:t1:c1:2026-10-21:WHATSAPP:CUSTOMER')
})

Deno.test('sends per call stay between 1 and 25, 15 by default', () => {
  assertEquals(referralBatchSize(undefined), 15)
  assertEquals(referralBatchSize(5), 5)
  assertEquals(referralBatchSize(0), 15)
  assertEquals(referralBatchSize(100), 15)
})

Deno.test('chunks split a list', () => {
  assertEquals(chunks([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
})
