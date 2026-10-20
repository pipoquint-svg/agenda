import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import { customerLinkButton, customerLinkSuffix } from './customer-link.ts'

Deno.test('the manage link button keeps the site fixed and the path variable', () => {
  const button = customerLinkButton('appointment.manage_url')
  assertEquals(button.url, 'https://www.blacksheepestudiocriativo.com.br/{{1}}')
  assertEquals(button.example.startsWith('https://www.blacksheepestudiocriativo.com.br/gerenciar-reserva#token='), true)
  assertEquals(
    customerLinkSuffix('appointment.manage_url', 'https://www.blacksheepestudiocriativo.com.br/gerenciar-reserva#token=abc&scope=RESCHEDULE'),
    'gerenciar-reserva#token=abc&scope=RESCHEDULE',
  )
  assertThrows(() => customerLinkSuffix('appointment.manage_url', 'https://outro.com.br/x'), Error, 'WHATSAPP_BUTTON_LINK_MISMATCH')
})

Deno.test('payment buttons follow the configured payment sites', () => {
  Deno.env.set('PREBOOK_PUBLIC_BASE_URL', 'https://blacksheepestudiocriativo.com.br')
  assertEquals(customerLinkButton('pre_reservation.payment_url').url, 'https://blacksheepestudiocriativo.com.br/{{1}}')
  Deno.env.delete('PUBLIC_BOOKING_BASE_URL')
  assertThrows(() => customerLinkButton('balance.payment_url'), Error, 'WHATSAPP_BUTTON_LINK_UNAVAILABLE')
  Deno.env.set('PUBLIC_BOOKING_BASE_URL', 'https://www.blacksheepestudiocriativo.com.br/agenda')
  const balance = customerLinkButton('balance.payment_url')
  assertEquals(balance.url, 'https://www.blacksheepestudiocriativo.com.br/{{1}}')
  assertEquals(balance.example.endsWith('/agenda/pagar-saldo#token=' + 'a'.repeat(64)), true)
})
