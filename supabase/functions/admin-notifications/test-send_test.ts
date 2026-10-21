import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import { maskPhone, testParameters, testRecipient } from './test-send.ts'

Deno.test('normalizes Brazilian numbers and refuses others', () => {
  assertEquals(testRecipient('48991919121'), '5548991919121')
  assertEquals(testRecipient('(48) 99191-9121'), '5548991919121')
  assertEquals(testRecipient('+55 48 99191-9121'), '5548991919121')
  assertThrows(() => testRecipient('9919121'), Error, 'WHATSAPP_TEST_RECIPIENT_INVALID')
  assertThrows(() => testRecipient('+1 555 123 4567 89'), Error, 'WHATSAPP_TEST_RECIPIENT_INVALID')
  assertEquals(maskPhone('5548991919121'), '+55 48 9****-9121')
})

Deno.test('sends the approved samples and the button suffix', () => {
  const params = testParameters({
    name: 'agenda_x',
    language: 'pt_BR',
    category: 'UTILITY',
    body_text: 'Olá {{1}}',
    body_examples: ['Ana Souza'],
    header_text: null,
    header_example: null,
    footer_text: null,
    ttl_seconds: null,
    button_text: 'Gerenciar reserva',
    button_url: 'https://reservas.exemplo.com/{{1}}',
    button_example: 'https://reservas.exemplo.com/r/BS7K2Q#abc',
  })
  assertEquals(params.body_parameters, ['Ana Souza'])
  assertEquals(params.button_parameter, 'r/BS7K2Q#abc')
})
