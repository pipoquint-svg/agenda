import { useMemo, useState } from 'react'
import type { ChangePolicyPreview } from './adminAgendaApi'
import {
  AdminRescheduleError,
  applyAdminReschedule,
  createAdminRescheduleHold,
  listAdminRescheduleSlots,
  type AdminRescheduleApplyResult,
  type AdminRescheduleHold,
  type AdminRescheduleSlot,
} from './adminRescheduleApi'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

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
  if (code === 'RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED') return 'Esta reserva usa pacote de horas. A remarcação automática ficará disponível após a reconciliação específica do pacote.'
  if (code === 'SLOT_NO_LONGER_AVAILABLE') return 'Esse horário acabou de ficar indisponível. Escolha outro.'
  if (code === 'RESCHEDULE_HOLD_EXPIRED') return 'A proteção do novo horário expirou. Escolha o horário novamente.'
  if (code === 'RESCHEDULE_PENALTY_PAYMENT_REQUIRED') return 'A remarcação depende do pagamento da multa antes da troca.'
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

  const penaltyDue = Number(hold?.penalty_due_now ?? preview.penalty_due_now ?? 0)
  const canApply = Boolean(hold && penaltyDue <= 0 && acknowledged && !applying)
  const minDate = useMemo(localToday, [])

  async function searchSlots() {
    if (!date) return
    setLoadingSlots(true)
    setError('')
    setHold(null)
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
    try {
      const next = await createAdminRescheduleHold({
        appointmentId,
        requestedStartAt: slot.slot_start_at,
        accessToken,
      })
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

  async function apply() {
    if (!hold || !canApply) return
    setApplying(true)
    setError('')
    try {
      const result = await applyAdminReschedule({
        appointmentId,
        policyActionId: hold.policy_action_id,
        accessToken,
      })
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
          {penaltyDue > 0 ? (
            <div className="form-alert error">Multa necessária para concluir: {money.format(penaltyDue)}. O pagamento da multa ainda precisa ser concluído antes da troca.</div>
          ) : (
            <>
              <label className="cancellation-ack"><input type="checkbox" checked={acknowledged} onChange={(event) => setAcknowledged(event.target.checked)} /><span>Confirmo a troca para o novo horário protegido.</span></label>
              <button className="primary" type="button" disabled={!canApply} onClick={() => void apply()}>{applying ? 'Remarcando…' : 'Confirmar novo horário'}</button>
            </>
          )}
          <button className="secondary" type="button" disabled={applying} onClick={() => { setHold(null); setAcknowledged(false); if (date) void searchSlots() }}>Escolher outro horário</button>
        </div>
      )}
      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
    </div>
  )
}
