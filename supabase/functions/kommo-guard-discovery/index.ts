const headers = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'x-robots-tag': 'noindex, nofollow, noarchive',
}

// Historical provider-discovery probe used during the Kommo gate. Provider discovery
// is complete and Kommo LIVE remains disabled, so this endpoint must not read the
// Kommo token, call the provider, or mutate discovery cache.
Deno.serve(() => new Response(JSON.stringify({
  ok: false,
  error: 'KOMMO_GUARD_DISCOVERY_DISABLED',
}), { status: 410, headers }))
