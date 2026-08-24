import { buildMercadoPagoWebhookManifest, verifyMercadoPagoWebhookSignature } from './mercado-pago.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

async function hmacHex(secret: string, text: string): Promise<string> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const result = new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(text)))
  return Array.from(result).map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

Deno.test('Mercado Pago Orders webhook lowercases alphanumeric data.id in HMAC manifest', async () => {
  const manifest = buildMercadoPagoWebhookManifest('ORDTST01M0TAKWKB9ETA8VYCQR1T3Q2J', 'request-xyz', '1742505638683')
  assert(
    manifest === 'id:ordtst01m0takwkb9eta8vycqr1t3q2j;request-id:request-xyz;ts:1742505638683;',
    'Orders data.id must be lowercase in webhook manifest',
  )

  const secret = 'test-secret'
  const signature = await hmacHex(secret, manifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1742505638683,v1=${signature}`,
    requestId: 'request-xyz',
    dataId: 'ORDTST01M0TAKWKB9ETA8VYCQR1T3Q2J',
    secret,
  })
  assert(valid, 'uppercase Order query id must validate against lowercase provider manifest')
})

Deno.test('Mercado Pago numeric webhook data.id remains unchanged', () => {
  const manifest = buildMercadoPagoWebhookManifest('123456789', 'request-xyz', '1742505638683')
  assert(manifest === 'id:123456789;request-id:request-xyz;ts:1742505638683;', 'numeric data.id changed unexpectedly')
})
