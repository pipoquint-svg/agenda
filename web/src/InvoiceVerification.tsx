import { useEffect, useState } from 'react'
import { invoiceRequest } from './invoiceCheckoutApi'
export function InvoiceVerification({ holdToken, onVerified }: {holdToken:string;onVerified:(token:string)=>void}) {
  const [code,setCode]=useState(''), [sent,setSent]=useState(false), [verified,setVerified]=useState(false)
  const [busy,setBusy]=useState(false), [error,setError]=useState(''), [expires,setExpires]=useState<string|null>(null)
  useEffect(()=>{if(!expires)return;const delay=new Date(expires).getTime()-Date.now();const timer=setTimeout(()=>{setVerified(false);onVerified('')},Math.max(0,delay));return()=>clearTimeout(timer)},[expires,onVerified])
  async function request(){setBusy(true);setError('');try{const result=await invoiceRequest<{sent:boolean}>('booking-checkout',{action:'REQUEST_BENEFIT_VERIFICATION',checkout_hold_token:holdToken});if(!result.sent)throw new Error();setSent(true)}catch{setError('Não foi possível enviar o código. Aguarde um momento e tente novamente.')}finally{setBusy(false)}}
  async function verify(){setBusy(true);setError('');try{const result=await invoiceRequest<{verified:boolean;session_token:string;expires_at:string}>('booking-checkout',{action:'VERIFY_BENEFIT_CODE',checkout_hold_token:holdToken,code});if(!result.verified||!result.session_token)throw new Error();onVerified(result.session_token);setExpires(result.expires_at);setVerified(true);setCode('')}catch{setError('Código inválido ou expirado. Revise o código ou solicite outro.')}finally{setBusy(false)}}
  return <section className="checkout-section"><h3>Confirmar identidade para faturamento</h3><p>Use o código enviado ao e-mail cadastrado para concluir sem pagamento antecipado.</p>
    {verified?<p role="status">Identidade confirmada.</p>:<><button type="button" disabled={busy} onClick={()=>void request()}>{sent?'Reenviar código':'Enviar código por e-mail'}</button>{sent?<><label>Código de seis dígitos<input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={event=>setCode(event.target.value.replace(/\D/g,''))}/></label><button type="button" disabled={busy||code.length!==6} onClick={()=>void verify()}>Confirmar código</button></>:null}</>}
    {error?<p role="alert">{error}</p>:null}</section>
}
