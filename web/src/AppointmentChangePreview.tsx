import { useState } from 'react'
import {
  AdminAppointmentActionError,
  cancelAdminAppointment,
  type AdminCancellationResult,
  type CancellationSettlementChoice,
} from './adminAppointmentActionsApi'
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

function cancellationError(error: unknown): string {
  const code = error instanceof AdminAppointmentActionError ? error.code : ''
  if (code === 'CANCELLATION_SETTLEMENT_CHOICE_REQUIRED') return 'Escolha entre estorno e crédito antes de confirmar.'
  if (code === 'CANCELLATION_REFUND_NOT_AVAILABLE') return 'O estorno não está disponível para esta reserva pela política atual.'
  if (code === 'CANCELLATION_CREDIT_NOT_AVAILABLE') return 'O crédito não está disponível para esta reserva pela política atual.'
  if (code === 'APPOINTMENT_NOT_CANCELLABLE') return 'Esta reserva já não pode ser cancelada neste estado.'
  return 'Não foi possível cancelar a reserva. Recarregue a prévia antes de tentar novamente.'
}

function CancellationSuccess({ result }: { result: AdminCancellationResult }) {
  return (
    <div className="cancellation-success" role="status">
      <strong>Reserva cancelada e horário liberado.</strong>
      {result.policy_action_status === 'PENDING_REFUND' ? <p>O estorno foi solicitado e está pendente de confirmação do provedor. Ainda não está marcado como reembolsado.</p> : null}
      {result.policy_action_status === 'CREDIT_ISSUED' ? <p>Crédito emitido{result.coupon?.code ? <>: <strong>{result.coupon.code}</strong></> : null}{result.credit_amount ? ` no valor de ${currency(result.credit_amount)}` : ''}.</p> : null}
      {result.policy_action_status === 'AWAITING_PENALTY_PAYMENT' ? <p>A agenda foi liberada, mas há multa ainda pendente de pagamento: {currency(result.penalty_outstanding)}.</p> : null}
      {result.google_sync_enqueued ? <small>A atualização do calendário Google foi enfileirada.</small> : null}
    </div>
  )
}

export function AppointmentChangePreview({ appointmentId, accessToken, appointmentStatus, onAppointmentChanged }: {
  appointmentId: string
  accessToken: string
  appointmentStatus: string
  onAppointmentChanged?: (result: AdminCancellationResult) => void | Promise<void>
}) {
  const [preview, setPreview] = useState<ChangePolicyPreview | null>(null)
  const [loading, setLoading] = useState<'RESCHEDULE' | 'CANCEL' | null>(null)
  const [error, setError] = useState('')
  const [settlement, setSettlement] = useState<CancellationSettlementChoice>(null)
  const [reason, setReason] = useState('')
  const [acknowledged, setAcknowledged] = useState(false)
  const [executingCancel, setExecutingCancel] = useState(false)
  const [cancelResult, setCancelResult] = useState<AdminCancellationResult | null>(null)

  const actionable = !['CANCELLED', 'COMPLETED', 'EXPIRED', 'NO_SHOW'].includes(appointmentStatus) && !cancelResult
  if (!actionable && !cancelResult) return null

  async function load(type: 'RESCHEDULE' | 'CANCEL') {
    setLoading(type)
    setError('')
    setCancelResult(null)
    setAcknowledged(false)
    setSettlement(null)
    try {
      setPreview(await getChangePolicyPreview(appointmentId, type, accessToken))
    } catch {
      setPreview(null)
      setError('Não foi possível calcular a política deste serviço. Verifique se ela está configurada.')
    } finally {
      setLoading(null)
    }
  }

  async function executeCancellation() {
    if (!preview || preview.action_type !== 'CANCEL' || !acknowledged) return
    const hasRefund = preview.refund_allowed && Number(preview.refundable_amount) > 0
    const hasCredit = preview.credit_allowed && Number(preview.credit_amount) > 0
    if ((hasRefund || hasCredit) && !settlement) {
      setError('Escolha como tratar o saldo elegível antes de cancelar.')
      return
    }

    setExecutingCancel(true)
    setError('')
    try {
      const result = await cancelAdminAppointment({
        appointmentId,
        settlementChoice: settlement,
        reason: reason.trim() || null,
        accessToken,
      })
      setCancelResult(result)
      setPreview(null)
      await onAppointmentChanged?.(result)
    } catch (cause) {
      setError(cancellationError(cause))
      try {
        setPreview(await getChangePolicyPreview(appointmentId, 'CANCEL', accessToken))
      } catch {
        // Keep original mutation error if a fresh preview is also unavailable.
      }
    } finally {
      setExecutingCancel(false)
    }
  }

  const cancelPreview = preview?.action_type === 'CANCEL' ? preview : null
  const hasRefund = Boolean(cancelPreview?.refund_allowed && Number(cancelPreview.refundable_amount) > 0)
  const hasCredit = Boolean(cancelPreview?.credit_allowed && Number(cancelPreview.credit_amount) > 0)

  return (
    <section className="agenda-detail-section change-preview-section">
      <div className="change-preview-title">
        <div><h3>Alterar reserva</h3><p>Confira a regra financeira antes de executar qualquer alteração.</p></div>
      </div>

      {cancelResult ? <CancellationSuccess result={cancelResult} /> : (
        <>
          <div className="change-preview-actions">
            <button className="secondary" type="button" disabled={loading !== null || executingCancel} onClick={() => void load('RESCHEDULE')}>{loading === 'RESCHEDULE' ? 'Calculando…' : 'Simular remarcação'}</button>
            <button className="secondary" type="button" disabled={loading !== null || executingCancel} onClick={() => void load('CANCEL')}>{loading === 'CANCEL' ? 'Calculando…' : 'Simular cancelamento'}</button>
          </div>
          {error ? <div className="form-alert error" role="alert">{error}</div> : null}
          {preview ? <PreviewResult preview={preview} /> : null}

          {cancelPreview ? (
            <div className="cancellation-execution">
              {(hasRefund || hasCredit) ? (
                <fieldset>
                  <legend>Destino do saldo elegível</legend>
                  {hasRefund ? <label><input type="radio" name={`settlement-${appointmentId}`} checked={settlement === 'REFUND'} onChange={() => setSettlement('REFUND')} /><span><strong>Estorno</strong><small>{currency(cancelPreview.refundable_amount)} — ficará pendente até confirmação real do provedor.</small></span></label> : null}
                  {hasCredit ? <label><input type="radio" name={`settlement-${appointmentId}`} checked={settlement === 'CREDIT'} onChange={() => setSettlement('CREDIT')} /><span><strong>Crédito de uso</strong><small>{currency(cancelPreview.credit_amount)} com validade de {cancelPreview.credit_validity_days} dias.</small></span></label> : null}
                </fieldset>
              ) : <div className="cancellation-no-settlement">Não há saldo elegível para estorno ou crédito nesta condição.</div>}

              <label className="cancellation-reason"><span>Motivo interno (opcional)</span><textarea rows={2} maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Ex.: solicitação do cliente pelo WhatsApp" /></label>

              <label className="cancellation-ack"><input type="checkbox" checked={acknowledged} onChange={(event) => setAcknowledged(event.target.checked)} /><span>Confirmo que revisei a política acima. Ao continuar, o horário será liberado imediatamente e esta ação ficará registrada no histórico.</span></label>

              <button className="danger-action" type="button" disabled={!acknowledged || executingCancel || ((hasRefund || hasCredit) && !settlement)} onClick={() => void executeCancellation()}>{executingCancel ? 'Cancelando…' : 'Confirmar cancelamento da reserva'}</button>
            </div>
          ) : <small className="change-preview-warning">A simulação não altera reserva, pagamento ou horário.</small>}
        </>
      )}
    </section>
  )
}
