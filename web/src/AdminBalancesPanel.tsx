import { FormEvent, useCallback, useEffect, useState } from 'react'
import {
  BalanceCollectionApiError,
  listAdminBalances,
  recordManualBalancePayment,
  reissueBalanceCollection,
  type AdminBalanceRow,
} from './balanceCollectionApi'

function money(value: number | string | null | undefined): string {
  return new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(Number(value ?? 0))
}

function dateTime(value: string | null | undefined): string {
  if (!value) return 'Não disponível'
  return new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Sao_Paulo'}).format(new Date(value))
}

function actionError(error: unknown): string {
  const code = error instanceof BalanceCollectionApiError ? error.code : ''
  if (code==='ADMIN_PERMISSION_DENIED') return 'Sua sessão não possui permissão para esta operação financeira.'
  if (code==='BALANCE_COLLECTION_STILL_ACTIVE') return 'Já existe uma cobrança ativa. Aguarde o vencimento antes de reemitir.'
  if (code==='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED') return 'Esta cobrança ainda não está em um estado que permita reemissão.'
  if (code==='MANUAL_PAYMENT_EXCEEDS_BALANCE') return 'O valor informado é maior que o saldo em aberto.'
  return 'Não foi possível concluir a operação financeira.'
}

export function AdminBalancesPanel({ accessToken, operationScope }: {
  accessToken: string
  operationScope: '' | 'BLACKSHEEP' | 'SABRINA'
}) {
  const [mode,setMode]=useState<'open'|'overdue'>('open')
  const [rows,setRows]=useState<AdminBalanceRow[]>([])
  const [loading,setLoading]=useState(false)
  const [error,setError]=useState('')
  const [notice,setNotice]=useState('')
  const [paymentRow,setPaymentRow]=useState<AdminBalanceRow|null>(null)
  const [amount,setAmount]=useState('')
  const [method,setMethod]=useState<'CASH'|'OTHER'>('CASH')

  const load=useCallback(async()=>{
    setLoading(true);setError('')
    try { setRows(await listAdminBalances({accessToken,mode,operationScope})) }
    catch(cause){setError(actionError(cause))}
    finally{setLoading(false)}
  },[accessToken,mode,operationScope])

  useEffect(()=>{void load()},[load])

  async function reissue(row: AdminBalanceRow){
    setError('');setNotice('')
    try{
      await reissueBalanceCollection({appointmentId:row.appointment_id,accessToken})
      setNotice('Nova cobrança emitida. O novo link terá validade de 48 horas.')
      await load()
    }catch(cause){setError(actionError(cause))}
  }

  function openPayment(row: AdminBalanceRow){
    setPaymentRow(row);setAmount(Number(row.balance_value ?? 0).toFixed(2));setMethod('CASH');setError('');setNotice('')
  }

  async function submitPayment(event: FormEvent){
    event.preventDefault()
    if(!paymentRow)return
    const value=Number(amount.replace(',','.'))
    if(!Number.isFinite(value)||value<=0){setError('Informe um valor válido.');return}
    setError('');setNotice('')
    try{
      const result=await recordManualBalancePayment({appointmentId:paymentRow.appointment_id,accessToken,amount:value,method})
      const data=result.data ?? {}
      if(result.provider_cleanup_pending){
        setNotice('Pagamento presencial registrado, mas a cobrança do provedor não pôde ser cancelada. A divergência ficou registrada para resolução administrativa.')
      }else if(data.partial_collection_policy_pending===true){
        setNotice('Pagamento parcial registrado. A cobrança existente permanece ativa pelo valor original até definirmos a política para pagamentos presenciais parciais.')
      }else{
        setNotice('Pagamento presencial registrado e saldo atualizado.')
      }
      setPaymentRow(null)
      await load()
    }catch(cause){setError(actionError(cause))}
  }

  return <section className="dashboard-card">
    <div className="table-heading">
      <div><h2>Controle de pagamentos</h2><span>Saldos em aberto e inadimplência após o vencimento da cobrança.</span></div>
      <div className="dashboard-presets">
        <button className={mode==='open'?'primary':'secondary'} type="button" onClick={()=>setMode('open')}>Saldos em aberto</button>
        <button className={mode==='overdue'?'primary':'secondary'} type="button" onClick={()=>setMode('overdue')}>Inadimplentes</button>
      </div>
    </div>
    {error?<div className="form-alert error" role="alert">{error}</div>:null}
    {notice?<div className="form-alert" role="status">{notice}</div>:null}
    {loading?<p role="status">Atualizando pagamentos.</p>:null}
    <div className="dashboard-pending-list">
      {rows.map(row=>{
        const active=row.collection_status==='PENDING'
        return <article key={row.appointment_id}>
          <div>
            <strong>{row.customer_name ?? 'Cliente'}</strong>
            <span>{row.service_name ?? row.public_code ?? 'Reserva'}</span>
            <small>Atendimento: {dateTime(row.start_at)}</small>
          </div>
          <div>
            <span>Total: {money(row.total_value)}</span>
            <span>Pago: {money(row.paid_value)}</span>
            <strong>Em aberto: {money(row.balance_value)}</strong>
            {active?<small>Cobrança ativa até {dateTime(row.collection_expires_at)}</small>:<small>{row.collection_status==='EXPIRED'?'Cobrança vencida':'Sem cobrança ativa'}</small>}
          </div>
          <div className="agenda-header-actions">
            <button className="secondary" type="button" onClick={()=>openPayment(row)}>Registrar pagamento presencial</button>
            <button className="secondary" type="button" disabled={active} title={active?`Cobrança ativa até ${dateTime(row.collection_expires_at)}`:'Emitir novo link por 48 horas'} onClick={()=>void reissue(row)}>Reemitir cobrança</button>
          </div>
        </article>
      })}
      {!loading&&rows.length===0?<p className="empty-state">{mode==='overdue'?'Nenhuma reserva inadimplente.':'Nenhum saldo em aberto.'}</p>:null}
    </div>

    {paymentRow?<form className="checkout-form" onSubmit={submitPayment}>
      <h3>Registrar pagamento presencial</h3>
      <p>{paymentRow.customer_name ?? 'Cliente'} · saldo atual {money(paymentRow.balance_value)}</p>
      <label><span>Valor recebido</span><input inputMode="decimal" required value={amount} onChange={event=>setAmount(event.target.value)} /></label>
      <label><span>Forma</span><select value={method} onChange={event=>setMethod(event.target.value as 'CASH'|'OTHER')}><option value="CASH">Dinheiro</option><option value="OTHER">Outra forma presencial</option></select></label>
      <div className="agenda-header-actions"><button className="primary" type="submit">Registrar pagamento</button><button className="secondary" type="button" onClick={()=>setPaymentRow(null)}>Cancelar</button></div>
    </form>:null}
  </section>
}
