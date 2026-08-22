import { useState } from 'react'
import { getChangePolicyPreview, type ChangePolicyPreview } from './adminAgendaApi'
import './appointmentChangePreview.css'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

function currency(value: number | string | null | undefined): string {
  const next = Number(value ?? 0)
  return money.format(Number.isFinite(next) ? next : 0)
}

function penaltyText(preview: ChangePolicyPreview): string {
  if (preview.penalty_type === 'NONE' || Number(preview.penalty_amount) === 0) return 'Sem multa'
  if (preview.penalty_type === 'FIXED') return `${currency(preview.penalty_amount)} de multa fixa`
  return `${Number(preview.penalty_value)}% = ${currency(preview.penalty_amount)}`
}

function PreviewResult({ preview }: { preview: ChangePolicyPreview }) {
  return (
    <div className="change-preview-result">
      <div className="change-preview-headline">
        <strong>{preview.action_type === 'RESCHEDULE' ? 'Remarcação' : 'Cancelamento'}</strong>
        <span>{preview.inside_notice_window ? `Dentro de ${preview.notice_hours}h` : `Fora da janela de ${preview.notice_hours}h`}</span>
      </div>
      <dl>
        <div><dt>Valor contratado</dt><dd>{currency(preview.contract_value)}</dd></div>
        <div><dt>Valor já pago</dt><dd>{currency(preview.net_paid)}</dd></div>
        <div><dt>Multa aplicável</dt><dd>{penaltyText(preview)}</dd></div>
        {preview.action_type === 'RESCHEDULE' ? (
          <>
            <div><dt>Remarcações anteriores</dt><dd>{preview.prior_customer_reschedules}</dd></div>
            <div><dt>Pagamento necessário agora</dt><dd>{currency(preview.penalty_due_now)}</dd></div>
          </>
        ) : (
          <>
            <div><dt>Estorno possível</dt><dd>{preview.refund_allowed ? currency(preview.refundable_amount) : 'Não permitido'}</dd></div>
            <div><dt>Crédito possível</dt><dd>{preview.credit_allowed ? `${currency(preview.credit_amount)} • ${preview.credit_validity_days} dias` : 'Não permitido'}</dd></div>
            {Number(preview.cancellation_penalty_outstanding) > 0 ? <div><dt>Multa ainda devida</dt><dd>{currency(preview.cancellation_penalty_outstanding)}</dd></div> : null}
          </>
        )}
      </dl>
    </div>
  )
}

export function AppointmentChangePreview({ appointmentId, accessToken, appointmentStatus }: {
  appointmentId: string
  accessToken: string
  appointmentStatus: string
}) {
  const [preview, setPreview] = useState<ChangePolicyPreview | null>(null)
  const [loading, setLoading] = useState<'RESCHEDULE' | 'CANCEL' | null>(null)
  const [error, setError] = useState('')

  const actionable = !['CANCELLED', 'COMPLETED', 'EXPIRED', 'NO_SHOW'].includes(appointmentStatus)
  if (!actionable) return null

  async function load(type: 'RESCHEDULE' | 'CANCEL') {
    setLoading(type)
    setError('')
    try {
      setPreview(await getChangePolicyPreview(appointmentId, type, accessToken))
    } catch {
      setPreview(null)
      setError('Não foi possível calcular a política deste serviço. Verifique se ela está configurada.')
    } finally {
      setLoading(null)
    }
  }

  return (
    <section className="agenda-detail-section change-preview-section">
      <div className="change-preview-title">
        <div><h3>Alterar reserva</h3><p>Confira a regra financeira antes de executar qualquer alteração.</p></div>
      </div>
      <div className="change-preview-actions">
        <button className="secondary" type="button" disabled={loading !== null} onClick={() => void load('RESCHEDULE')}>{loading === 'RESCHEDULE' ? 'Calculando…' : 'Simular remarcação'}</button>
        <button className="secondary" type="button" disabled={loading !== null} onClick={() => void load('CANCEL')}>{loading === 'CANCEL' ? 'Calculando…' : 'Simular cancelamento'}</button>
      </div>
      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
      {preview ? <PreviewResult preview={preview} /> : null}
      <small className="change-preview-warning">Esta etapa é somente uma prévia. Nenhuma reserva, pagamento ou horário é alterado aqui.</small>
    </section>
  )
}
