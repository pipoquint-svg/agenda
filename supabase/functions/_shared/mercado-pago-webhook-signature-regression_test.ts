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

Deno.test('Mercado Pago Orders webhook validates provider lowercase alphanumeric data.id manifest', async () => {
  const dataId = 'ORDTST01M0TAKWKB9ETA8VYCQR1T3Q2J'
  const canonicalManifest = `id:${dataId.toLowerCase()};request-id:request-xyz;ts:1742505638683;`
  const secret = 'test-secret'
  const signature = await hmacHex(secret, canonicalManifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1742505638683,v1=${signature}`,
    requestId: 'request-xyz',
    dataId,
    secret,
  })
  assert(valid, 'uppercase Order query id must validate against lowercase provider manifest')
})

Deno.test('Mercado Pago webhook omits request-id component when provider does not send it', async () => {
  const dataId = 'ORDTST01M0TAKWKB9ETA8VYCQR1T3Q2J'
  const canonicalManifest = `id:${dataId.toLowerCase()};ts:1742505638683;`
  const secret = 'test-secret'
  const signature = await hmacHex(secret, canonicalManifest)
  const valid = await verifyMercadoPagoWebhookSignature({
    signature: `ts=1742505638683,v1=${signature}`,
    requestId: null,
    dataId,
    secret,
  })
  assert(valid, 'webhook without x-request-id must validate against a manifest that omits request-id')
})

Deno.test('Mercado Pago numeric webhook data.id remains unchanged', () => {
  const manifest = buildMercadoPagoWebhookManifest('123456789', 'request-xyz', '1742505638683')
  assert(manifest === 'id:123456789;request-id:request-xyz;ts:1742505638683;', 'numeric data.id changed unexpectedly')
})

Deno.test('Mercado Pago manifest never serializes an empty request-id field', () => {
  const manifest = buildMercadoPagoWebhookManifest('123456789', '', '1742505638683')
  assert(manifest === 'id:123456789;ts:1742505638683;', 'empty request-id must be omitted from the manifest')
})
