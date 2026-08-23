import { FormEvent, useEffect, useMemo, useState } from 'react'
import {
  AppointmentActionError,
  type ActionResolve,
  type ActionScope,
  type CancelPreview,
  type RescheduleProposal,
  type RescheduleSlot,
  createRescheduleProposal,
  executeCancellation,
  executeReschedule,
  getCancelPreview,
  getRescheduleSlots,
  resolveAppointmentAction,
} from './appointmentActionApi'
import './manageReservation.css'

function money(value: number): string {
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(value || 0)
}

function dateTime(value: string | null | undefined): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return '—'
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(parsed)
}

function localToday(): string {
  const now = new Date()
  const year = now.getFullYear()
  const month = String(now.getMonth() + 1).padStart(2, '0')
  const day = String(now.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function actionSessionId(): string {
  const key = 'blacksheep:appointment-action-session'
  const existing = sessionStorage.getItem(key)
  if (existing) return existing
  const created = crypto.randomUUID()
  sessionStorage.setItem(key, created)
  return created
}

function actionParams(): { token: string; scope: ActionScope | null } {
  const params = new URLSearchParams(window.location.search)
  const token = params.get('token')?.trim() ?? ''
  const raw = (params.get('scope') ?? params.get('acao') ?? params.get('action') ?? '').trim().toUpperCase()
  if (raw === 'CANCEL' || raw === 'CANCELAR' || raw === 'CANCELAMENTO') return { token, scope: 'CANCEL' }
  if (raw === 'RESCHEDULE' || raw === 'REMARCAR' || raw === 'REMARCACAO' || raw === 'REMARCAÇÃO') {
    return { token, scope: 'RESCHEDULE' }
  }
  return { token, scope: null }
}

function errorMessage(error: unknown): string {
  const code = error instanceof AppointmentActionError ? error.code : 'ACTION_ACCESS_TEMPORARY_FAILURE'
  switch (code) {
    case 'LINK_INVALID_OR_EXPIRED': return 'Este link não é mais válido. Entre em contato com a BlackSheep para receber ajuda.'
    case 'ACTION_ACCESS_RATE_LIMITED': return 'Foram feitas muitas tentativas. Tente novamente mais tarde ou fale com a BlackSheep.'
    case 'ACTION_VERIFICATION_REQUIRED': return 'Confirme o e-mail cadastrado para continuar.'
    case 'ACTION_PAYMENT_REQUIRED': return 'Existe uma diferença de valor que precisa ser paga antes de concluir a remarcação.'
    case 'RESCHEDULE_HOLD_EXPIRED': return 'O horário selecionado expirou. Escolha novamente um horário disponível.'
    case 'CLIENT_RESCHEDULE_LIMIT_REACHED': return 'Esta reserva atingiu o limite de remarcações pelo link. Fale com a BlackSheep.'
    case 'RESCHEDULE_REQUIRES_ASSISTANCE': return 'Esta reserva precisa de atendimento da BlackSheep para ser remarcada.'
    default: return 'Não foi possível concluir agora. Tente novamente em instantes.'
  }
}

function LinkNotice({ access }: { access: ActionResolve }) {
  return (
    <div className="manage-link-notice" role="note">
      <span>{access.warning}</span>
      <small>Válido até {dateTime(access.expires_at)} · acesso em {dateTime(access.accessed_at)}</small>
    </div>
  )
}

function CancelFlow({ token, access }: { token: string; access: ActionResolve }) {
  const [preview, setPreview] = useState<CancelPreview | null>(null)
  const [email, setEmail] = useState('')
  const [reason, setReason] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const sessionId = useMemo(actionSessionId, [])

  useEffect(() => {
    let alive = true
    getCancelPreview(token)
      .then((value) => { if (alive) setPreview(value) })
      .catch((cause) => { if (alive) setError(errorMessage(cause)) })
    return () => { alive = false }
  }, [token])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!confirmed || !email.trim()) return
    setBusy(true)
    setError('')
    try {
      await executeCancellation(token, email, sessionId, reason)
      setDone(true)
    } catch (cause) {
      setError(errorMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  if (done) {
    return (
      <section className="manage-state-card success" aria-live="polite">
        <span className="manage-state-icon">✓</span>
        <h2>Cancelamento registrado</h2>
        <p>A reserva foi atualizada. Os valores seguem exatamente a política apresentada antes da confirmação.</p>
      </section>
    )
  }

  return (
    <>
      <LinkNotice access={preview ?? access} />
      <section className="manage-section">
        <div className="manage-section-heading">
          <span className="manage-step">1</span>
          <div>
            <h2>Confira antes de cancelar</h2>
            <p>O cálculo abaixo vem diretamente da regra financeira da sua reserva.</p>
          </div>
        </div>

        {!preview && !error && <div className="manage-skeleton">Calculando as condições do cancelamento…</div>}
        {preview && (
          <div className="manage-financial-grid">
            <div><span>Valor da reserva</span><strong>{money(preview.financial.contract_value)}</strong></div>
            <div><span>Valor retido</span><strong>{money(preview.financial.penalty_amount)}</strong></div>
            <div className="highlight"><span>Valor a devolver</span><strong>{money(preview.financial.refund_amount)}</strong></div>
          </div>
        )}
      </section>

      <form className="manage-section manage-form" onSubmit={submit}>
        <div className="manage-section-heading">
          <span className="manage-step">2</span>
          <div>
            <h2>Confirme o cancelamento</h2>
            <p>Para proteger uma ação financeira, confirme o e-mail cadastrado na reserva.</p>
          </div>
        </div>

        <label>
          E-mail cadastrado
          <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
        </label>
        <label>
          Motivo <span className="optional">opcional</span>
          <textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} />
        </label>
        <label className="manage-confirm">
          <input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} />
          <span>Li os valores acima e confirmo que desejo cancelar esta reserva.</span>
        </label>
        {error && <div className="form-alert error" role="alert">{error}</div>}
        <button className="manage-danger" type="submit" disabled={busy || !confirmed || !email.trim() || !preview}>
          {busy ? 'Cancelando…' : 'Confirmar cancelamento'}
        </button>
      </form>
    </>
  )
}

function RescheduleFlow({ token, access }: { token: string; access: ActionResolve }) {
  const [date, setDate] = useState('')
  const [slots, setSlots] = useState<RescheduleSlot[]>([])
  const [proposal, setProposal] = useState<RescheduleProposal | null>(null)
  const [email, setEmail] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const sessionId = useMemo(actionSessionId, [])

  async function searchSlots() {
    if (!date) return
    setBusy(true)
    setError('')
    setProposal(null)
    try {
      const result = await getRescheduleSlots(token, date)
      setSlots(result.slots)
    } catch (cause) {
      setSlots([])
      setError(errorMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  async function chooseSlot(slot: RescheduleSlot) {
    setBusy(true)
    setError('')
    try {
      const result = await createRescheduleProposal(token, slot.slot_start_at)
      setProposal(result)
    } catch (cause) {
      setProposal(null)
      setError(errorMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!proposal || !confirmed || proposal.requires_payment) return
    if (proposal.requires_email_verification && !email.trim()) return
    setBusy(true)
    setError('')
    try {
      await executeReschedule(token, proposal.policy_action_id, sessionId, email)
      setDone(true)
    } catch (cause) {
      setError(errorMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  if (done) {
    return (
      <section className="manage-state-card success" aria-live="polite">
        <span className="manage-state-icon">✓</span>
        <h2>Remarcação concluída</h2>
        <p>O novo horário foi confirmado e passou a ser o horário oficial da reserva.</p>
      </section>
    )
  }

  return (
    <>
      <LinkNotice access={access} />
      <section className="manage-section">
        <div className="manage-section-heading">
          <span className="manage-step">1</span>
          <div>
            <h2>Escolha uma nova data</h2>
            <p>Mostramos somente horários que o backend confirma como disponíveis.</p>
          </div>
        </div>
        <div className="manage-date-row">
          <input aria-label="Nova data" type="date" min={localToday()} value={date} onChange={(event) => setDate(event.target.value)} />
          <button className="secondary" type="button" onClick={searchSlots} disabled={busy || !date}>
            {busy ? 'Consultando…' : 'Ver horários'}
          </button>
        </div>
        {slots.length > 0 && (
          <div className="manage-slots" aria-label="Horários disponíveis">
            {slots.map((slot) => (
              <button key={slot.slot_start_at} type="button" onClick={() => chooseSlot(slot)} disabled={busy}>
                <strong>{new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }).format(new Date(slot.core_start_at))}</strong>
                <span>{slot.duration_minutes} min</span>
              </button>
            ))}
          </div>
        )}
        {date && !busy && slots.length === 0 && !proposal && !error && <p className="manage-empty">Nenhum horário foi carregado para esta data.</p>}
      </section>

      {proposal && (
        <form className="manage-section manage-form" onSubmit={submit}>
          <div className="manage-section-heading">
            <span className="manage-step">2</span>
            <div>
              <h2>Revise a nova reserva</h2>
              <p>O horário fica protegido temporariamente enquanto você conclui esta etapa.</p>
            </div>
          </div>

          <div className="manage-proposal-date">
            <span>Novo horário</span>
            <strong>{dateTime(proposal.new_slot.core_start_at ?? proposal.new_slot.slot_start_at)}</strong>
            {proposal.new_slot.expires_at && <small>Seleção protegida até {dateTime(proposal.new_slot.expires_at)}</small>}
          </div>

          <div className="manage-financial-grid">
            <div><span>Valor da reserva</span><strong>{money(proposal.financial.new_contract_value)}</strong></div>
            <div><span>Valor retido</span><strong>{money(proposal.financial.penalty_amount)}</strong></div>
            <div className={proposal.financial.difference_due > 0 ? 'highlight' : ''}>
              <span>Diferença a pagar</span><strong>{money(proposal.financial.difference_due)}</strong>
            </div>
          </div>

          {proposal.requires_email_verification && (
            <label>
              E-mail cadastrado
              <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
            </label>
          )}

          {proposal.requires_payment && (
            <div className="form-alert error" role="status">
              Esta remarcação tem uma diferença de {money(proposal.financial.difference_due)}. O pagamento precisa ser concluído antes da confirmação do novo horário.
            </div>
          )}

          <label className="manage-confirm">
            <input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} />
            <span>Revisei o novo horário e os valores e desejo confirmar a remarcação.</span>
          </label>
          {error && <div className="form-alert error" role="alert">{error}</div>}
          <button className="primary" type="submit" disabled={busy || !confirmed || proposal.requires_payment || (proposal.requires_email_verification && !email.trim())}>
            {proposal.requires_payment ? 'Pagamento necessário' : busy ? 'Confirmando…' : 'Confirmar novo horário'}
          </button>
        </form>
      )}

      {!proposal && error && <div className="form-alert error" role="alert">{error}</div>}
    </>
  )
}

export function ManageReservation() {
  const [{ token, scope }] = useState(actionParams)
  const [access, setAccess] = useState<ActionResolve | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    document.title = 'Gerenciar reserva | BlackSheep Estúdio Criativo'
    const robots = document.querySelector('meta[name="robots"]') ?? document.createElement('meta')
    robots.setAttribute('name', 'robots')
    robots.setAttribute('content', 'noindex,nofollow,noarchive')
    if (!robots.parentNode) document.head.appendChild(robots)
  }, [])

  useEffect(() => {
    if (!token || !scope) {
      setError('Este link não é mais válido. Entre em contato com a BlackSheep para receber ajuda.')
      return
    }
    let alive = true
    resolveAppointmentAction(token, scope)
      .then((value) => { if (alive) setAccess(value) })
      .catch((cause) => { if (alive) setError(errorMessage(cause)) })
    return () => { alive = false }
  }, [token, scope])

  return (
    <main className="manage-shell">
      <header className="manage-header">
        <span className="manage-brand">BLACKSHEEP</span>
        <p>Estúdio Criativo</p>
      </header>
      <div className="manage-card">
        <div className="manage-intro">
          <span className="manage-eyebrow">Gerenciar minha reserva</span>
          <h1>{scope === 'CANCEL' ? 'Cancelar reserva' : scope === 'RESCHEDULE' ? 'Remarcar reserva' : 'Gerenciar reserva'}</h1>
          <p>As condições, valores e horários desta página são consultados diretamente no sistema da sua reserva.</p>
        </div>

        {!access && !error && <div className="manage-loading">Validando seu link…</div>}
        {error && (
          <section className="manage-state-card error" role="alert">
            <span className="manage-state-icon">×</span>
            <h2>Não foi possível abrir este link</h2>
            <p>{error}</p>
          </section>
        )}
        {access && scope === 'CANCEL' && <CancelFlow token={token} access={access} />}
        {access && scope === 'RESCHEDULE' && <RescheduleFlow token={token} access={access} />}
      </div>
    </main>
  )
}
