import { assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1'
import { infinitePayRuntime } from './infinitepay-runtime.ts'

Deno.test('InfinitePay runtime reads existing payments without enabling new links', () => {
  assertEquals(
    infinitePayRuntime({ handle: '$sabrina.pierri', liveLinksEnabled: 'false' }),
    { handle: 'sabrina.pierri', redirectUrl: null, liveLinksEnabled: false },
  )
})

Deno.test('InfinitePay live checkout creation is fail-closed', () => {
  assertThrows(
    () => infinitePayRuntime({
      handle: 'sabrina.pierri',
      liveLinksEnabled: 'false',
      redirectUrl: 'https://www.sabrinapierri.com.br/natal-2026',
      creatingLink: true,
    }),
    Error,
    'INFINITEPAY_LIVE_LINKS_DISABLED',
  )
})

Deno.test('InfinitePay live checkout requires a safe HTTPS return URL', () => {
  assertThrows(
    () => infinitePayRuntime({
      handle: 'sabrina.pierri',
      liveLinksEnabled: 'true',
      redirectUrl: 'http://example.com/return',
      creatingLink: true,
    }),
    Error,
    'INFINITEPAY_REDIRECT_URL_INVALID',
  )
})

Deno.test('InfinitePay live checkout accepts explicit configuration only when complete', () => {
  assertEquals(
    infinitePayRuntime({
      handle: 'sabrina.pierri',
      liveLinksEnabled: 'true',
      redirectUrl: 'https://www.sabrinapierri.com.br/natal-2026?payment=return',
      creatingLink: true,
    }),
    {
      handle: 'sabrina.pierri',
      redirectUrl: 'https://www.sabrinapierri.com.br/natal-2026?payment=return',
      liveLinksEnabled: true,
    },
  )
})
