import { assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1'
import {
  infinitePayRuntime,
  infinitePayRuntimeFromRecord,
  loadInfinitePayRuntime,
} from './infinitepay-runtime.ts'

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

Deno.test('database runtime record remains disabled until the explicit flag is true', () => {
  assertEquals(
    infinitePayRuntimeFromRecord({
      handle: 'pierri_quint_pro',
      redirect_url: 'https://example.supabase.co/functions/v1/infinitepay-return',
      live_links_enabled: false,
    }),
    {
      handle: 'pierri_quint_pro',
      redirectUrl: 'https://example.supabase.co/functions/v1/infinitepay-return',
      liveLinksEnabled: false,
    },
  )

  assertThrows(
    () => infinitePayRuntimeFromRecord({
      handle: 'pierri_quint_pro',
      redirect_url: 'https://example.supabase.co/functions/v1/infinitepay-return',
      live_links_enabled: false,
    }, { creatingLink: true }),
    Error,
    'INFINITEPAY_LIVE_LINKS_DISABLED',
  )
})

Deno.test('database runtime loader uses service-role RPC data and can enable one controlled create window', async () => {
  const client = {
    rpc: async (name: string) => {
      assertEquals(name, 'service_get_infinitepay_runtime_config')
      return {
        data: {
          handle: 'pierri_quint_pro',
          redirect_url: 'https://example.supabase.co/functions/v1/infinitepay-return',
          live_links_enabled: true,
        },
        error: null,
      }
    },
  }
  assertEquals(await loadInfinitePayRuntime(client, { creatingLink: true }), {
    handle: 'pierri_quint_pro',
    redirectUrl: 'https://example.supabase.co/functions/v1/infinitepay-return',
    liveLinksEnabled: true,
  })
})

Deno.test('database runtime loader fails closed when configuration is missing', async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: 'INFINITEPAY_RUNTIME_CONFIG_MISSING' } }),
  }
  await assertRejects(
    () => loadInfinitePayRuntime(client),
    Error,
    'INFINITEPAY_RUNTIME_CONFIG_MISSING',
  )
})

Deno.test('database runtime rejects malformed records', () => {
  assertThrows(
    () => infinitePayRuntimeFromRecord({ handle: 'pierri_quint_pro', redirect_url: 'https://example.com', live_links_enabled: 'true' }),
    Error,
    'INFINITEPAY_RUNTIME_CONFIG_INVALID',
  )
})
