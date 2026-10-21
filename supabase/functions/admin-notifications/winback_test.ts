import { assertEquals } from 'jsr:@std/assert@1'
import { greetingName, winbackKeys } from './winback.ts'

Deno.test('the message greets by first name', () => {
  assertEquals(greetingName('LARISSA SOUZA'), 'Larissa')
  assertEquals(greetingName('  danielli  '), 'Danielli')
  assertEquals(greetingName('Laís Costa'), 'Laís')
  assertEquals(greetingName(null), '')
})

Deno.test('one coupon and one message per customer and absence', () => {
  const keys = winbackKeys('c', 't', 'u', '2026-08-21T14:00:00+00:00')
  assertEquals(keys.issuance, 'winback:c:u:2026-08-21')
  assertEquals(keys.delivery, 'rewards-winback:t:u:2026-08-21:WHATSAPP:CUSTOMER')
  assertEquals(winbackKeys('c', 't', 'u', null).issuance, 'winback:c:u:unknown')
})
