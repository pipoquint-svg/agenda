import { useState } from 'react'
import { invoiceRequest, type InvoiceFields } from './invoiceCheckoutApi'
export type InvoiceBooking = InvoiceFields & {status?:string;appointment_status?:string;public_code?:string;cash_due?:number|string|null;hold_expires_at?:string|null;pre_reservation_expires_at?:string|null}
export function InvoiceBookingState({result,accessToken,onConfirmed}:{result:InvoiceBooking;accessToken?:string;onConfirmed?:()=>void}) {
  const [confirmed,setConfirmed]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState('')
  const status=confirmed?'CONFIRMED':result.status??result.appointment_status
  const date=(value?:string|null)=>value?new Date(value).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'}):'conforme o prazo cadastrado'
  async function confirm(){if(!accessToken)return;setBusy(true);setError('');try{const reply=await invoiceRequest<{status:string}>('prebook-access',{action:'CONFIRM_INVOICE',access_token:accessToken});if(reply.status!=='CONFIRMED')throw new Error();setConfirmed(true);onConfirmed?.()}catch{setError('Não foi possível confirmar. Verifique o prazo ou fale com a equipe.')}finally{setBusy(false)}}
  return <section className="checkout-panel checkout-result" aria-live="polite"><h2>{status==='CONFIRMED'?'Reserva confirmada com faturamento':'Pré-reserva com faturamento'}</h2>
    <p>Código: <strong>{result.public_code}</strong></p><p>Não há pagamento antecipado neste checkout.</p>
    {result.cash_due!=null?<p>Valor a faturar: <strong>{new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(Number(result.cash_due))}</strong>.</p>:null}
    <p>Vencimento: <strong>{date(result.invoice_due_at)}</strong>.</p>
    {status==='AWAITING_PAYMENT'?<><p>{result.requires_manual_confirmation?'A reserva aguarda a confirmação da equipe.':'Confirme sua reserva para garantir este horário.'} Prazo: {date(result.pre_reservation_expires_at??result.hold_expires_at)}. Sem confirmação, o horário será liberado.</p>
      {!result.requires_manual_confirmation&&accessToken?<button type="button" disabled={busy} onClick={()=>void confirm()}>Confirmar com faturamento</button>:null}</>:status!=='CONFIRMED'?<p>Este agendamento não está mais ativo. Consulte a equipe.</p>:null}
    {error?<p role="alert">{error}</p>:null}</section>
}
