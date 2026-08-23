import { useCallback, useEffect, useState } from 'react'
import {
  AdminAgendaApiError,
  downloadAppointmentTimeline,
  getAppointmentTimeline,
  unlockAppointmentTokenVerification,
  type AppointmentTimeline,
  type AppointmentTimelineEvent,
} from './adminAgendaApi'
import './appointmentAudit.css'

function dateTime(value: string): string {
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'medium',
    timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function originLabel(origin: string): string {
  const labels: Record<string, string> = {
    ADMIN_UI: 'Administração',
    CLIENT_TOKEN: 'Link do cliente',
    SYSTEM_JOB: 'Sistema',
    PROVIDER_WEBHOOK: 'Provedor externo',
  }
  return labels[origin] ?? origin
}

function EventDetails({ event }: { event: AppointmentTimelineEvent }) {
  const hasTechnical = Boolean(event.request_id || event.ip_address || event.user_agent || event.actor_permissions?.length)
  const hasChanges = Boolean(event.before || event.after)
  if (!hasTechnical && !hasChanges) return null

  return (
    <details className="audit-event-details">
      <summary>Ver evidência</summary>
      <dl>
        {event.request_id ? <><dt>Request ID</dt><dd>{event.request_id}</dd></> : null}
        {event.ip_address ? <><dt>IP</dt><dd>{event.ip_address}</dd></> : null}
        {event.user_agent ? <><dt>User-Agent</dt><dd>{event.user_agent}</dd></> : null}
        {event.actor_permissions?.length ? <><dt>Permissões</dt><dd>{event.actor_permissions.join(', ')}</dd></> : null}
        {event.token_scope ? <><dt>Escopo do link</dt><dd>{event.token_scope}</dd></> : null}
        {event.destination_masked ? <><dt>Destino mascarado</dt><dd>{event.destination_masked}</dd></> : null}
      </dl>
      {event.before ? <div className="audit-json"><strong>Antes</strong><pre>{JSON.stringify(event.before, null, 2)}</pre></div> : null}
      {event.after ? <div className="audit-json"><strong>Depois</strong><pre>{JSON.stringify(event.after, null, 2)}</pre></div> : null}
    </details>
  )
}

export function AppointmentAuditPanel({ appointmentId, accessToken }: { appointmentId: string; accessToken: string }) {
  const [timeline, setTimeline] = useState<AppointmentTimeline | null>(null)
  const [loading, setLoading] = useState(true)
  const [forbidden, setForbidden] = useState(false)
  const [error, setError] = useState('')
  const [unlockReason, setUnlockReason] = useState('')
  const [unlocking, setUnlocking] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      setTimeline(await getAppointmentTimeline(appointmentId, accessToken))
      setForbidden(false)
    } catch (cause) {
      if (cause instanceof AdminAgendaApiError && cause.code === 'ADMIN_PERMISSION_DENIED') {
        setForbidden(true)
        return
      }
      setError('Não foi possível carregar a trilha de autoria.')
    } finally {
      setLoading(false)
    }
  }, [accessToken, appointmentId])

  useEffect(() => { void load() }, [load])

  async function exportTimeline() {
    setError('')
    try {
      await downloadAppointmentTimeline(appointmentId, accessToken)
    } catch {
      setError('Não foi possível exportar a trilha de autoria.')
    }
  }

  async function unlock() {
    if (!unlockReason.trim()) return
    setUnlocking(true)
    setError('')
    try {
      await unlockAppointmentTokenVerification(appointmentId, unlockReason.trim(), accessToken)
      setUnlockReason('')
      await load()
    } catch {
      setError('Não foi possível liberar as tentativas do link.')
    } finally {
      setUnlocking(false)
    }
  }

  if (forbidden) return null

  return (
    <section className="agenda-detail-section appointment-audit" aria-label="Trilha de autoria da reserva">
      <div className="audit-heading">
        <div>
          <h3>Trilha de autoria</h3>
          <p>Histórico cronológico de mudanças, acessos por link e evidências técnicas autorizadas.</p>
        </div>
        <button className="secondary" type="button" disabled={!timeline} onClick={() => void exportTimeline()}>Exportar CSV</button>
      </div>

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
      {loading ? <p role="status">Carregando trilha…</p> : null}

      {timeline?.security.locked ? (
        <div className="audit-lockout">
          <div>
            <strong>Verificação do link bloqueada</strong>
            <p>{timeline.security.appointment_attempt_count} tentativa(s) na reserva; {timeline.security.locked_origin_count} origem(ns) bloqueada(s).</p>
            <small>Liberar tentativas não reativa link expirado, consumido ou revogado.</small>
          </div>
          <label>
            <span>Motivo da liberação</span>
            <input value={unlockReason} maxLength={500} onChange={(event) => setUnlockReason(event.target.value)} placeholder="Registre o motivo operacional" />
          </label>
          <button className="secondary" type="button" disabled={unlocking || !unlockReason.trim()} onClick={() => void unlock()}>
            {unlocking ? 'Liberando…' : 'Liberar tentativas'}
          </button>
        </div>
      ) : null}

      {timeline && timeline.events.length === 0 ? <p className="empty-state">Ainda não há eventos de autoria para esta reserva.</p> : null}
      {timeline ? (
        <ol className="audit-timeline">
          {timeline.events.map((event) => (
            <li key={`${event.source}:${event.id}`}>
              <div className="audit-event-time">{dateTime(event.occurred_at)}</div>
              <div className="audit-event-card">
                <div className="audit-event-title">
                  <strong>{event.summary}</strong>
                  <span>{originLabel(event.origin)}</span>
                </div>
                {event.actor_name ? <p>Responsável: <strong>{event.actor_name}</strong>{event.actor_role ? ` · ${event.actor_role}` : ''}</p> : null}
                {event.reason ? <p>Motivo: {event.reason}</p> : null}
                <EventDetails event={event} />
              </div>
            </li>
          ))}
        </ol>
      ) : null}
    </section>
  )
}
