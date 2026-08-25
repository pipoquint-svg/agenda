const headers = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'x-robots-tag': 'noindex, nofollow, noarchive',
}

// Historical sandbox-only provider probe. It is permanently retired and must never
// send email, read provider credentials, or mutate application state.
Deno.serve(() => new Response(JSON.stringify({
  ok: false,
  error: 'PROVIDER_PROBE_DISABLED_AFTER_SUCCESSFUL_GATE',
}), { status: 410, headers }))
