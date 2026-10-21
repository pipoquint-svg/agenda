import { assertEquals } from 'jsr:@std/assert@1'
import { durationLabel } from './duration-label.ts'

Deno.test('duration in hours for messages', () => {
  assertEquals(durationLabel(120), '2h')
  assertEquals(durationLabel(90), '1h30')
  assertEquals(durationLabel(65), '1h05')
  assertEquals(durationLabel(60), '1h')
  assertEquals(durationLabel(45), '45 min')
  assertEquals(durationLabel(null), '0 min')
})
