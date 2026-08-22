import { useMemo, useState } from 'react'
import type { ChangePolicyPreview } from './adminAgendaApi'
import {
  AdminRescheduleError,
  applyAdminReschedule,
  createAdminRescheduleHold,
  listAdminRescheduleSlots,
  registerAdminReschedulePenalty,
  type AdminRescheduleApplyResult,
  type AdminRescheduleHold,
  type AdminReschedulePenaltyPayment,
  type AdminRescheduleSlot,
} from './adminRescheduleApi'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

type PenaltyMethod = 'PIX' | 'CARD' | 'CASH' | 'TRANSFER' | 'OTHER'

function localToday(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date())
  const p = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${p.year}-${p.month}-${p.day}`
}

function time(value: string): string {
  return new Intl.DateTimeFormat('pt-BR', {
    hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function errorText(error: unknown): string {
  const code = error instanceof AdminRescheduleError ? error.code : ''
  if (code === 'HOUR_PACKAGE_INSUFFICIENT_BALANCE') return 'O pacote não possui saldo suficiente para o consumo adicional deste horário.'
  if (code === 'HOUR_PACKAGE_OUTSIDE_VALIDITY') return 'O pacote não é válido na nova data escolhida.'
  if (code === 'SLOT_NO_LONGER_AVAILABLE') return 'Esse horário acabou de ficar indisponível. Escolha outro.'
  if (code === 'RESCHEDULE_HOLD_EXPIRED') return 'A proteção do novo horário expirou. Escolha o horário novamente.'
  if (code === 'RESCHEDULE_PENALTY_PAYMENT_REQUIRED') return 'Registre o recebimento da multa antes de confirmar a troca.'
  if (code === 'INVALID_PENALTY_PAYMENT_METHOD') return 'Escolha uma forma válida de recebimento da multa.'
  if (code === 'RESCHEDULE_PENALTY_NOT_PAYABLE') return 'A multa já foi liquidada ou não está mais disponível para cobrança.'
  if (code === 'APPOINTMENT_NOT_RESCHEDULABLE') return 'Esta reserva não pode mais ser remarcada neste estado.'
  return 'Não foi possível concluir a remarcação.'
}

export function AppointmentRescheduleFlow({
  appointmentId,
  accessToken,
  preview,
  onApplied,
}: {
  appointmentId: string
  accessToken: string
  preview: ChangePolicyPreview
  onApplied?: (result: AdminRescheduleApplyResult) => void | Promise<void>
}) {
  const [date, setDate] = useState('')
  const [slots, setSlots] = useState<AdminRescheduleSlot[]>([])
  const [hold, setHold] = useState<AdminRescheduleHold | null>(null)
  const [loadingSlots, setLoadingSlots] = useState(false)
  const [protecting, setProtecting] = useState<string | null>(null)
  const [applying, setApplying] = useState(false)
  const [acknowledged, setAcknowledged] = useState(false)
  const [error, setError] = useState('')
  const [applied, setApplied] = useState<AdminRescheduleApplyResult | null>(null)
  const [penaltyMethod, setPenaltyMethod] = useState<PenaltyMethod>('PIX')
  const [penaltyNotes, setPenaltyNotes] = useState('')
  const [registeringPenalty, setRegisteringPenalty] = useState(false)
  const [penaltyPayment, setPenaltyPayment] = useState<AdminReschedulePenaltyPayment | null>(null)

  const penaltyDue = Number(hold?.penalty_due_now ?? preview.penalty_due_now ?? 0)
  const penaltySatisfied = penaltyDue <= 0 || penaltyPayment?.status === 'PAID'
  const canApply = Boolean(hold && penaltySatisfied && acknowledged && !applying)
  const minDate = useMemo(localToday, [])

  async function searchSlots() {
    if (!date) return
    setLoadingSlots(true)
    setError('')
    setHold(null)
    setPenaltyPayment(null)
    setSlots([])
    try {
      setSlots(await listAdminRescheduleSlots({ appointmentId, localDate: date, accessToken }))
    } catch (cause) {
      setError(errorText(cause))
    } finally {
      setLoadingSlots(false)
    }
  }

  async function protect(slot: AdminRescheduleSlot) {
    setProtecting(slot.slot_start_at)
    setError('')
    setAcknowledged(false)
    setPenaltyPayment(null)
    try {
      const next = await createAdminRescheduleHold({ appointmentId, requestedStartAt: slot.slot_start_at, accessToken })
      setHold(next)
      setSlots([])
    } catch (cause) {
      setError(errorText(cause))
      if (date) {
        try { setSlots(await listAdminRescheduleSlots({ appointmentId, localDate: date, accessToken })) } catch { /* keep action error */ }
      }
    } finally {
      setProtecting(null)
    }
  }

  async function registerPenalty() {
    if (!hold || penaltyDue <= 0) return
    setRegisteringPenalty(true)
    setError('')
    try {
      setPenaltyPayment(await registerAdminReschedulePenalty({
        appointmentId,
        policyActionId: hold.policy_action_id,
        method: penaltyMethod,
        notes: penaltyNotes.trim() || null,
        accessToken,
      }))
    } catch (cause) {
      setError(errorText(cause))
    } finally {
      setRegisteringPenalty(false)
    }
  }

  async function apply() {
    if (!hold || !canApply) return
    setApplying(true)
    setError('')
    try {
      const result = await applyAdminReschedule({ appointmentId, policyActionId: hold.policy_action_id, accessToken })
      setApplied(result)
      await onApplied?.(result)
    } catch (cause) {
      setError(errorText(cause))
    } finally {
      setApplying(false)
    }
  }

  if (applied) {
    return (
      <div className="reschedule-success" role="status">
        <strong>Reserva remarcada.</strong>
        {applied.new_start_at ? <span>Novo horário: {time(applied.new_start_at)}.</span> : null}
        {applied.package_reconciliation && applied.package_reconciliation.uses_package ? <small>O consumo do pacote de horas foi reconciliado com o novo período.</small> : null}
        {applied.google_sync_enqueued ? <small>A atualização do Google foi enfileirada.</small> : null}
      </div>
    )
  }

  return (
    <div className="reschedule-execution">
      {!hold ? (
        <>
          <div className="reschedule-date-row">
            <label><span>Nova data</span><input type="date" min={minDate} value={date} onChange={(event) => { setDate(event.target.value); setSlots([]) }} /></label>
            <button className="secondary" type="button" disabled={!date || loadingSlots} onClick={() => void searchSlots()}>{loadingSlots ? 'Buscando…' : 'Ver horários'}</button>
          </div>
          {slots.length > 0 ? (
            <div className="reschedule-slots">
              {slots.map((slot) => (
                <button type="button" key={slot.slot_start_at} disabled={protecting !== null} onClick={() => void protect(slot)}>
                  <strong>{time(slot.slot_start_at)}–{time(slot.slot_end_at)}</strong>
                  {slot.core_start_at !== slot.slot_start_at ? <small>Atendimento {time(slot.core_start_at)}–{time(slot.core_end_at)}</small> : null}
                  {Number(slot.package_delta_seconds ?? 0) > 0 ? <small>Pacote: +{Math.round(Number(slot.package_delta_seconds) / 60)} min de consumo neste período.</small> : null}
                  {Number(slot.package_delta_seconds ?? 0) < 0 ? <small>Pacote: devolve {Math.round(Math.abs(Number(slot.package_delta_seconds)) / 60)} min de saldo.</small> : null}
                  {protecting === slot.slot_start_at ? <span>Protegendo…</span> : null}
                </button>
              ))}
            </div>
          ) : date && !loadingSlots ? <small className="change-preview-warning">Nenhum horário selecionado. Consulte a data para ver a disponibilidade real.</small> : null}
        </>
      ) : (
        <div className="reschedule-hold">
          <strong>Novo horário protegido: {time(hold.new_slot.slot_start_at)}–{time(hold.new_slot.slot_end_at)}</strong>
          <small>O horário antigo continua ocupado até a confirmação final.</small>
          {hold.package_reconciliation?.uses_package ? (
            <div className="reschedule-package-note">
              <strong>Pacote de horas</strong>
              {Number(hold.package_reconciliation.delta_seconds ?? 0) > 0 ? <span>Este período consumirá mais {Math.round(Number(hold.package_reconciliation.delta_seconds) / 60)} min do pacote.</span> : null}
              {Number(hold.package_reconciliation.delta_seconds ?? 0) < 0 ? <span>Este período devolverá {Math.round(Math.abs(Number(hold.package_reconciliation.delta_seconds)) / 60)} min ao pacote.</span> : null}
              {Number(hold.package_reconciliation.delta_seconds ?? 0) === 0 ? <span>O consumo do pacote não muda.</span> : null}
            </div>
          ) : null}

          {penaltyDue > 0 && !penaltyPayment ? (
            <div className="reschedule-penalty">
              <div className="form-alert error">Multa necessária para concluir: <strong>{money.format(penaltyDue)}</strong>.</div>
              <div className="reschedule-penalty-fields">
                <label><span>Recebido por</span><select value={penaltyMethod} onChange={(event) => setPenaltyMethod(event.target.value as PenaltyMethod)}><option value="PIX">PIX</option><option value="CARD">Cartão</option><option value="CASH">Dinheiro</option><option value="TRANSFER">Transferência</option><option value="OTHER">Outro</option></select></label>
                <label><span>Observação (opcional)</span><input value={penaltyNotes} onChange={(event) => setPenaltyNotes(event.target.value)} placeholder="Ex.: PIX recebido no WhatsApp" /></label>
              </div>
              <small>Use este botão somente depois de confirmar que o valor foi efetivamente recebido. A multa é registrada separadamente e não reduz o saldo do contrato.</small>
              <button className="secondary" type="button" disabled={registeringPenalty} onClick={() => void registerPenalty()}>{registeringPenalty ? 'Registrando…' : `Registrar recebimento de ${money.format(penaltyDue)}`}</button>
            </div>
          ) : null}

          {penaltyPayment ? <div className="reschedule-penalty-paid">Multa recebida e registrada: <strong>{money.format(Number(penaltyPayment.cash_amount))}</strong>.</div> : null}

          {penaltySatisfied ? (
            <>
              <label className="cancellation-ack"><input type="checkbox" checked={acknowledged} onChange={(event) => setAcknowledged(event.target.checked)} /><span>Confirmo a troca para o novo horário protegido.</span></label>
              <button className="primary" type="button" disabled={!canApply} onClick={() => void apply()}>{applying ? 'Remarcando…' : 'Confirmar novo horário'}</button>
            </>
          ) : null}
          <button className="secondary" type="button" disabled={applying || registeringPenalty} onClick={() => { setHold(null); setPenaltyPayment(null); setAcknowledged(false); if (date) void searchSlots() }}>Escolher outro horário</button>
        </div>
      )}
      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
    </div>
  )
}
