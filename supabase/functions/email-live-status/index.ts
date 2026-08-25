const headers = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'x-robots-tag': 'noindex, nofollow, noarchive',
}

// Historical sandbox-only live-status probe. It is permanently retired and must
// never expose provider/runtime configuration or mutate application state.
Deno.serve(() => new Response(JSON.stringify({
  error: 'GONE',
}), { status: 410, headers }))
