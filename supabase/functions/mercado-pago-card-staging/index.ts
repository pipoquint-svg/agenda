const headers = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'x-robots-tag': 'noindex, nofollow, noarchive',
}

// Historical sandbox endpoint retained only so the deployed slug can be safely
// tombstoned after the Mercado Pago integration audit. It must not create tokens,
// Orders, charges or expose credentials. Permanent provider tests live in the
// explicit GitHub sandbox gates.
Deno.serve(() => new Response(JSON.stringify({
  error: {
    code: 'MP_CARD_STAGING_RETIRED',
    message: 'Temporary Mercado Pago card staging probe retired after sandbox validation.',
  },
}), { status: 410, headers }))
