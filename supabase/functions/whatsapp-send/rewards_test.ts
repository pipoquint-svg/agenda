import { assertEquals } from 'jsr:@std/assert@1'
import {
  couponDateLabel,
  couponDaysLeft,
  couponDiscountLabel,
  hoursLabel,
  issuanceKey,
  messageUsesVariable,
  rewardsDeliveryKey,
  rewardsScheduleMatches,
  rewardsSkipReason,
  triggerServes,
} from './rewards.ts'

const template = { id: 't1', schedule_mode: 'AFTER_END', schedule_offset_minutes: 30 }

Deno.test('a changed reservation still matches the Rewards schedule', () => {
  assertEquals(rewardsScheduleMatches('t1:1:AFTER_END:30', template), true)
  assertEquals(rewardsScheduleMatches('t1:7:AFTER_END:30', template), true)
})

Deno.test('a changed trigger or another template does not match', () => {
  assertEquals(rewardsScheduleMatches('t1:1:AFTER_END:15', template), false)
  assertEquals(rewardsScheduleMatches('t2:1:AFTER_END:30', template), false)
  assertEquals(rewardsScheduleMatches('t1:1:BEFORE_END:30', { ...template, schedule_mode: 'BEFORE_END' }), false)
  assertEquals(rewardsScheduleMatches('t1:x:AFTER_END:30', template), false)
  assertEquals(rewardsScheduleMatches('t1:1:AFTER_END:30:extra', template), false)
  assertEquals(rewardsScheduleMatches('', template), false)
})

Deno.test('keys do not depend on the reservation version', () => {
  assertEquals(issuanceKey('c', 'a'), 'rewards-dispatch:c:a')
  assertEquals(rewardsDeliveryKey('t', 'a'), 'rewards:t:a:REWARDS_COUPON_ISSUED:WHATSAPP:CUSTOMER')
})

Deno.test('unpaid waits; other refusals are final', () => {
  assertEquals(rewardsSkipReason('MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED'), 'REWARDS_WAITING_PAYMENT')
  assertEquals(rewardsSkipReason('MARKETING_CAMPAIGN_NOT_ACTIVE'), 'REWARDS_NOT_ELIGIBLE:MARKETING_CAMPAIGN_NOT_ACTIVE')
  assertEquals(rewardsSkipReason(''), 'REWARDS_NOT_ELIGIBLE:UNKNOWN')
})

Deno.test('coupon values for the message', () => {
  assertEquals(couponDiscountLabel('PERCENT', '15.00'), '15%')
  assertEquals(couponDiscountLabel('PERCENT', 12.5), '12,5%')
  assertEquals(couponDiscountLabel('FIXED', 50).replace(/\s/g, ' '), 'R$ 50,00')
  assertEquals(couponDiscountLabel('FIXED', 0), '')
  assertEquals(couponDateLabel('2026-11-20T02:30:00Z'), '19/11/2026')
  assertEquals(couponDateLabel(null), '')
  const now = Date.parse('2026-10-21T12:00:00Z')
  assertEquals(couponDaysLeft('2026-11-20T12:00:00Z', now), '30')
  assertEquals(couponDaysLeft('2026-10-21T13:00:00Z', now), '1')
  assertEquals(couponDaysLeft('2026-10-20T12:00:00Z', now), '0')
})

Deno.test('each Rewards message serves its own campaigns', () => {
  assertEquals(triggerServes('REWARDS_COUPON_ISSUED', 'RENTAL_COMPLETED_FINANCIALLY_CLEARED'), true)
  assertEquals(triggerServes('REWARDS_COUPON_ISSUED', 'REFERRAL_FIRST_RENTAL'), false)
  assertEquals(triggerServes('REWARDS_REFERRAL_REWARD', 'REFERRAL_FIRST_RENTAL'), true)
  assertEquals(triggerServes('REWARDS_REFERRAL_REWARD', 'INACTIVITY'), false)
  assertEquals(rewardsDeliveryKey('t', 'a', 'REWARDS_REFERRAL_REWARD'), 'rewards:t:a:REWARDS_REFERRAL_REWARD:WHATSAPP:CUSTOMER')
})

Deno.test('free hours read naturally', () => {
  assertEquals(hoursLabel(60), '1 hora')
  assertEquals(hoursLabel(120), '2 horas')
  assertEquals(hoursLabel(90), '1h30')
  assertEquals(hoursLabel(45), '45 minutos')
})

Deno.test('a customer link counts only when the message shows it', () => {
  const body = 'Olá {{customer.name}}! Seu saldo é {{ payment.balance }}.'
  assertEquals(messageUsesVariable(body, 'balance.payment_url', 'appointment.manage_url'), false)
  assertEquals(messageUsesVariable(body + ' {{appointment.manage_url}}', null, 'appointment.manage_url'), true)
  assertEquals(messageUsesVariable(body, 'appointment.manage_url', 'appointment.manage_url'), true)
  assertEquals(messageUsesVariable(body, null, 'payment.balance'), true)
})
