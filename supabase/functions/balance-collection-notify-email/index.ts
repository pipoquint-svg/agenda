import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { isRecipientAllowed, maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function enabled(): boolean {
  return (Deno.env.get('TRANSACTIONAL_EMAIL_ENABLED') ?? '').trim().toLowerCase() === 'true'
}

function allowRealRecipients(): boolean {
  return (Deno.env.get('ALLOW_REAL_EMAIL_RECIPIENTS') ?? '').trim().toLowerCase() === 'true'
}

function escapeHtml(value: string): string {
  return value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;')
}

function money(value: unknown): string {
  return new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(Number(value ?? 0))
}

function dateTime(value: string): string {
  return new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Sao_Paulo'}).format(new Date(value))
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'),405)
  try {
    requireInternal(req)
    const body = await req.json().catch(() => ({}))
    const collectionId = String(body?.collection_id ?? '').trim()
    if (!/^[0-9a-f-]{36}$/i.test(collectionId)) throw new Error('BALANCE_COLLECTION_ID_INVALID')
    if (!enabled()) return jsonResponse({skipped:true,reason:'TRANSACTIONAL_EMAIL_DISABLED'})

    const client = adminClient()
    const { data: collection, error: collectionError } = await client
      .from('appointment_balance_collections')
      .select('id,appointment_id,sequence,status,amount_snapshot,expires_at')
      .eq('id',collectionId).maybeSingle()
    if (collectionError || !collection) throw new Error('BALANCE_COLLECTION_NOT_FOUND')
    if (collection.status !== 'PENDING') return jsonResponse({skipped:true,reason:'BALANCE_COLLECTION_NOT_PENDING'})

    const { data: appointment, error: appointmentError } = await client
      .from('appointments')
      .select('id,primary_customer_id,start_at,service_name_snapshot')
      .eq('id',collection.appointment_id).maybeSingle()
    if (appointmentError || !appointment?.primary_customer_id) throw new Error('APPOINTMENT_LOOKUP_FAILED')

    const { data: customer, error: customerError } = await client
      .from('customers').select('name,email').eq('id',appointment.primary_customer_id).maybeSingle()
    if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')
    const recipient = normalizedEmail(customer.email)
    if (!recipient || !isRecipientAllowed(recipient,allowRealRecipients(),Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'))) {
      return jsonResponse({skipped:true,reason:'EMAIL_RECIPIENT_NOT_ALLOWED',recipient_masked:recipient?maskEmail(recipient):'***'})
    }

    const { data: description, error: descriptionError } = await client.rpc('appointment_commercial_description',{p_appointment_id:appointment.id})
    if (descriptionError) throw new Error('COMMERCIAL_DESCRIPTION_FAILED')
    const commercialDescription = String(description ?? appointment.service_name_snapshot ?? 'Locação de estúdio')
    const baseUrl = Deno.env.get('PUBLIC_BOOKING_BASE_URL')?.trim().replace(/\/$/,'') ?? ''
    if (!/^https:\/\//i.test(baseUrl)) throw new Error('PUBLIC_BOOKING_BASE_URL_INVALID')
    const payUrl = `${baseUrl}/reserva/saldo?collection=${encodeURIComponent(collection.id)}`
    const amount = money(collection.amount_snapshot)
    const expires = dateTime(collection.expires_at)
    const start = dateTime(appointment.start_at)
    const customerName = String(customer.name ?? 'Cliente').trim() || 'Cliente'

    const subject = `Saldo da sua locação, ${amount}`
    const text = [
      `Olá ${customerName},`,'',
      'Sua locação começou e o saldo restante já está disponível para pagamento.','',
      commercialDescription,
      `Início: ${start}`,
      `Saldo a pagar: ${amount}`,
      `Link válido até: ${expires}`,'',
      `Pagar saldo: ${payUrl}`,'',
      'Se você já realizou o pagamento presencialmente, desconsidere esta mensagem.','',
      'BlackSheep Estúdio Criativo',
    ].join('\n')

    const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;color:#111"><div style="max-width:640px;margin:0 auto;padding:24px 14px"><div style="background:#fff;border:1px solid #d7d7d7;border-radius:12px;padding:28px"><div style="font-size:13px;font-weight:700;letter-spacing:.04em;margin-bottom:12px">BLACKSHEEP ESTÚDIO CRIATIVO</div><h1 style="font-size:24px;line-height:1.2;margin:0 0 16px">Saldo da sua locação</h1><p style="font-size:16px;line-height:1.55;margin:0 0 20px">Olá ${escapeHtml(customerName)}. Sua locação começou e o saldo restante já está disponível para pagamento.</p><div style="border:1px solid #cfcfcf;border-radius:10px;padding:18px;margin:0 0 22px"><div style="font-size:16px;font-weight:700;margin-bottom:12px">${escapeHtml(commercialDescription)}</div><div style="font-size:15px;line-height:1.7">Início: <strong>${escapeHtml(start)}</strong><br>Saldo a pagar: <strong>${escapeHtml(amount)}</strong><br>Link válido até: <strong>${escapeHtml(expires)}</strong></div></div><a href="${escapeHtml(payUrl)}" style="display:inline-block;background:#111;color:#fff;text-decoration:none;font-weight:700;padding:14px 20px;border-radius:8px">Pagar saldo</a><p style="font-size:14px;line-height:1.55;margin:22px 0 0;color:#333">Se você já realizou o pagamento presencialmente, desconsidere esta mensagem.</p></div></div></body></html>`

    const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() ?? ''
    if (!from) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')
    const payload: EmailProviderPayload = {from,to:[recipient],subject,text,html}
    const replyTo = Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim()
    if (replyTo) payload.reply_to=replyTo
    const providerMessageId = await sendEmailWithProvider(payload,`rental-balance-email:${collection.id}`)

    await client.from('appointment_balance_collections').update({email_delivered_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('id',collection.id)
    return jsonResponse({skipped:false,collection_id:collection.id,recipient_masked:maskEmail(recipient),provider:'RESEND',provider_message_id:providerMessageId})
  } catch (error) {
    const code = error instanceof Error ? error.message : 'BALANCE_EMAIL_FAILED'
    return errorResponse(error,code==='INTERNAL_AUTH_REQUIRED'?401:500)
  }
})
