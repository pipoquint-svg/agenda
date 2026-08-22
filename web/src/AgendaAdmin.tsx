import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import {
  AdminAgendaApiError,
  getAdminAgenda,
  getAdminAppointment,
  getAmeliaHistory,
  type AdminAgendaResponse,
  type AdminAppointment,
  type AmeliaHistoryRecord,
  type AppointmentDetailResponse,
} from './adminAgendaApi'
import { AppointmentChangePreview } from './AppointmentChangePreview'
import { supabase } from './supabase'

type Tab = 'AGENDA' | 'AMELIA'

const emptyAgenda: AdminAgendaResponse = {
  range: { start_at: '', end_at: '' },
  appointments: [],
  external_blocks: [],
}

function saoPauloDate(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

function localRange(date: string): { start: string; end: string } {
  const start = new Date(`${date}T00:00:00-03:00`)
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000)
  return { start: start.toISOString(), end: end.toISOString() }
}

function historyRange(date: string): { start: string; end: string } {
  const center = new Date(`${date}T00:00:00-03:00`)
  const start = new Date(center.getTime() - 180 * 24 * 60 * 60 * 1000)
  const end = new Date(center.getTime() + 186 * 24 * 60 * 60 * 1000)
  return { start: start.toISOString(), end: end.toISOString() }
}

function time(value: string | null | undefined): string {
  if (!value) return '—'
  return new Intl.DateTimeFormat('pt-BR', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function dateTime(value: string | null | undefined): string {
  if (!value) return '—'
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function money(value: number | string | null | undefined): string {
  const numeric = Number(value ?? 0)
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number.isFinite(numeric) ? numeric : 0)
}

function minutesLabel(value: number | null | undefined): string {
  if (!value) return '—'
  const hours = Math.floor(value / 60)
  const minutes = value % 60
  if (!hours) return `${minutes} min`
  if (!minutes) return `${hours}h`
  return `${hours}h${String(minutes).padStart(2, '0')}`
}

function appointmentOccupancyEnd(appointment: AdminAppointment): string {
  const resourceEnd = appointment.resources
    .map((resource) => resource.occupied_end_at ?? resource.end_at)
    .filter((value): value is string => Boolean(value))
    .sort()
    .at(-1)
  return resourceEnd ?? appointment.end_at
}

function statusClass(status: string): string {
  const normalized = status.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  return `agenda-badge agenda-badge-${normalized}`
}

function DetailPanel({ detail, accessToken, onClose }: { detail: AppointmentDetailResponse; accessToken: string; onClose: () => void }) {
  const appointment = detail.appointment
  const customer = detail.customer ?? {}
  return (
    <aside className="agenda-detail" aria-label="Detalhes da reserva">
      <div className="agenda-detail-header">
        <div>
          <span className="agenda-eyebrow">Reserva {String(appointment.public_code ?? '')}</span>
          <h2>{String(appointment.service_name ?? 'Reserva')}</h2>
        </div>
        <button className="secondary" type="button" onClick={onClose}>Fechar</button>
      </div>

      <div className="agenda-detail-grid">
        <section>
          <h3>Cliente</h3>
          <p><strong>{String(customer.name ?? '—')}</strong></p>
          <p>{String(customer.phone ?? '')}</p>
          <p>{String(customer.email ?? '')}</p>
          {customer.cpf_cnpj ? <p>CPF/CNPJ: {String(customer.cpf_cnpj)}</p> : null}
        </section>
        <section>
          <h3>Horário</h3>
          <p>Cliente: <strong>{time(String(appointment.start_at))}–{time(String(appointment.end_at))}</strong></p>
          <p>Contratado: {minutesLabel(Number(appointment.contracted_minutes ?? appointment.duration_minutes))}</p>
          {appointment.duration_blocks ? <p>Blocos: {String(appointment.duration_blocks)} × 30 min</p> : null}
          <p>Buffer depois: {minutesLabel(Number(appointment.buffer_after_minutes ?? 0))}</p>
        </section>
        <section>
          <h3>Financeiro</h3>
          <p>Valor contratado: <strong>{money(appointment.commercial_value as number)}</strong></p>
          <p>Status: {String(appointment.financial_status ?? '—')}</p>
          <p>{detail.payments.length} lançamento(s) de pagamento</p>
        </section>
      </div>

      <AppointmentChangePreview appointmentId={appointment.id} accessToken={accessToken} appointmentStatus={appointment.status} />

      <section className="agenda-detail-section">
        <h3>Recursos ocupados</h3>
        <div className="agenda-resource-list">
          {detail.resources.map((resource) => (
            <div key={String(resource.allocation_id ?? resource.resource_id ?? resource.id)}>
              <strong>{resource.resource_name ?? resource.name ?? 'Recurso'}</strong>
              <span>{time(resource.start_at ?? resource.occupied_start_at)}–{time(resource.end_at ?? resource.occupied_end_at)}</span>
            </div>
          ))}
        </div>
      </section>

      {detail.extras.length > 0 && (
        <section className="agenda-detail-section">
          <h3>Extras</h3>
          <ul>{detail.extras.map((extra, index) => <li key={String(extra.id ?? index)}>{String(extra.name ?? 'Extra')} × {String(extra.quantity ?? 1)} — {money(extra.total_price as number)}</li>)}</ul>
        </section>
      )}

      {detail.answers.length > 0 && (
        <section className="agenda-detail-section">
          <h3>Informações do serviço</h3>
          <dl>{detail.answers.map((answer, index) => <div key={String(answer.id ?? index)}><dt>{String(answer.label ?? answer.field_key ?? '')}</dt><dd>{typeof answer.value === 'string' ? answer.value : JSON.stringify(answer.value)}</dd></div>)}</dl>
        </section>
      )}

      {detail.package_usage && (
        <section className="agenda-detail-section">
          <h3>Pacote de horas</h3>
          <p>{String(detail.package_usage.package_name ?? 'Pacote')}</p>
          <p>Consumo contratado: {minutesLabel(Math.round(Number(detail.package_usage.required_seconds ?? 0) / 60))}</p>
        </section>
      )}
    </aside>
  )
}

export function AgendaAdmin() {
  const [authReady, setAuthReady] = useState(false)
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loginError, setLoginError] = useState('')
  const [tab, setTab] = useState<Tab>('AGENDA')
  const [selectedDate, setSelectedDate] = useState(saoPauloDate)
  const [agenda, setAgenda] = useState<AdminAgendaResponse>(emptyAgenda)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [detail, setDetail] = useState<AppointmentDetailResponse | null>(null)
  const [ameliaSearch, setAmeliaSearch] = useState('')
  const [ameliaRecords, setAmeliaRecords] = useState<AmeliaHistoryRecord[]>([])

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setAccessToken(data.session?.access_token ?? null)
      setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setAccessToken(session?.access_token ?? null)
      setAuthReady(true)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  const loadAgenda = useCallback(async (token: string, date: string) => {
    setLoading(true)
    setError('')
    try {
      const range = localRange(date)
      setAgenda(await getAdminAgenda(range.start, range.end, token))
    } catch (requestError) {
      setError(requestError instanceof AdminAgendaApiError && requestError.code.startsWith('ADMIN_')
        ? 'Sua sessão não tem acesso à agenda administrativa.'
        : 'Não foi possível carregar a agenda.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (accessToken && tab === 'AGENDA') void loadAgenda(accessToken, selectedDate)
  }, [accessToken, loadAgenda, selectedDate, tab])

  const orderedAppointments = useMemo(
    () => [...agenda.appointments].sort((a, b) => a.start_at.localeCompare(b.start_at)),
    [agenda.appointments],
  )

  async function login(event: FormEvent) {
    event.preventDefault()
    setLoginError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError) setLoginError('Não foi possível entrar com essas credenciais.')
  }

  async function openAppointment(id: string) {
    if (!accessToken) return
    setError('')
    try {
      setDetail(await getAdminAppointment(id, accessToken))
    } catch {
      setError('Não foi possível abrir os detalhes da reserva.')
    }
  }

  async function searchAmelia(event?: FormEvent) {
    event?.preventDefault()
    if (!accessToken) return
    setLoading(true)
    setError('')
    try {
      const range = historyRange(selectedDate)
      const data = await getAmeliaHistory(range.start, range.end, ameliaSearch, accessToken)
      setAmeliaRecords(data.records)
    } catch {
      setError('Não foi possível consultar o histórico Amelia.')
    } finally {
      setLoading(false)
    }
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>

  if (!accessToken) {
    return (
      <main className="admin-shell login-shell">
        <form className="login-card" onSubmit={login}>
          <h1>BlackSheep Agenda</h1>
          <p>Área administrativa</p>
          <label><span>E-mail</span><input type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
          <label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
          {loginError && <div className="form-alert error" role="alert">{loginError}</div>}
          <button className="primary" type="submit">Entrar</button>
        </form>
      </main>
    )
  }

  return (
    <main className="admin-shell agenda-admin-shell">
      <header className="admin-title-row agenda-admin-header">
        <div>
          <span className="agenda-eyebrow">BlackSheep Agenda</span>
          <h1>Operação</h1>
          <p>Reservas nativas, ocupação real dos recursos e histórico legado.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href="/admin/configuracoes">Configurações</a>
          <a className="secondary agenda-link-button" href="/admin/demand">Demanda</a>
          <button className="secondary" type="button" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>

      <nav className="agenda-tabs" aria-label="Seções administrativas">
        <button type="button" className={tab === 'AGENDA' ? 'active' : ''} onClick={() => setTab('AGENDA')}>Agenda</button>
        <button type="button" className={tab === 'AMELIA' ? 'active' : ''} onClick={() => setTab('AMELIA')}>Histórico Amelia</button>
      </nav>

      {error && <div className="form-alert error" role="alert">{error}</div>}

      {tab === 'AGENDA' ? (
        <>
          <section className="agenda-toolbar">
            <label><span>Dia</span><input type="date" value={selectedDate} onChange={(event) => setSelectedDate(event.target.value)} /></label>
            <button className="secondary" type="button" onClick={() => setSelectedDate(saoPauloDate())}>Hoje</button>
            <div className="agenda-kpis">
              <div><strong>{agenda.appointments.length}</strong><span>reservas</span></div>
              <div><strong>{agenda.external_blocks.length}</strong><span>bloqueios externos</span></div>
            </div>
          </section>

          {loading ? <p role="status">Carregando agenda.</p> : (
            <div className="agenda-columns">
              <section className="agenda-day-card">
                <div className="table-heading"><h2>Reservas</h2><span>Horário do cliente ≠ ocupação técnica</span></div>
                <div className="agenda-booking-list">
                  {orderedAppointments.map((appointment) => (
                    <button className="agenda-booking-row" type="button" key={appointment.id} onClick={() => void openAppointment(appointment.id)}>
                      <div className="agenda-time-block"><strong>{time(appointment.start_at)}</strong><span>{time(appointment.end_at)}</span></div>
                      <div className="agenda-booking-main">
                        <div className="agenda-booking-title"><strong>{appointment.service_name}</strong><span className={statusClass(appointment.status)}>{appointment.status}</span></div>
                        <span>{appointment.customer?.name ?? 'Cliente não identificado'}{appointment.employee_name ? ` • ${appointment.employee_name}` : ''}</span>
                        <span>Contratado: {minutesLabel(appointment.contracted_minutes ?? appointment.duration_minutes)}{appointment.duration_blocks ? ` • ${appointment.duration_blocks} blocos` : ''}</span>
                        <span className="agenda-occupancy">Recurso ocupado até {time(appointmentOccupancyEnd(appointment))}{appointment.buffer_after_minutes ? ` • buffer +${appointment.buffer_after_minutes} min` : ''}</span>
                      </div>
                      <div className="agenda-booking-money"><strong>{money(appointment.commercial_value)}</strong><span>{appointment.financial_status}</span></div>
                    </button>
                  ))}
                  {orderedAppointments.length === 0 && <p className="empty-state">Nenhuma reserva nativa neste dia.</p>}
                </div>
              </section>

              <section className="agenda-day-card agenda-blocks-card">
                <div className="table-heading"><h2>Bloqueios Google</h2><span>Recursos indisponíveis</span></div>
                <div className="agenda-block-list">
                  {agenda.external_blocks.map((block) => (
                    <article key={block.allocation_id}>
                      <div><strong>{time(block.start_at)}–{time(block.end_at)}</strong><span>{block.resource_name}</span></div>
                      <p>{block.event_summary || block.reason || 'Compromisso externo'}</p>
                      <small>{block.calendar_name || block.source}</small>
                    </article>
                  ))}
                  {agenda.external_blocks.length === 0 && <p className="empty-state">Nenhum bloqueio externo neste dia.</p>}
                </div>
              </section>
            </div>
          )}
        </>
      ) : (
        <section className="agenda-day-card">
          <div className="table-heading"><div><h2>Histórico Amelia</h2><span>Consulta somente leitura — não altera a agenda atual.</span></div></div>
          <form className="agenda-history-search" onSubmit={(event) => void searchAmelia(event)}>
            <label><span>Buscar</span><input placeholder="Cliente, telefone, serviço ou ID Amelia" value={ameliaSearch} onChange={(event) => setAmeliaSearch(event.target.value)} /></label>
            <button className="primary" type="submit">Consultar</button>
          </form>
          {loading ? <p role="status">Consultando histórico.</p> : (
            <div className="table-scroll">
              <table className="agenda-history-table">
                <thead><tr><th>Data</th><th>Cliente</th><th>Serviço</th><th>Profissional</th><th>Status Amelia</th><th>Pagamento</th><th>ID</th></tr></thead>
                <tbody>
                  {ameliaRecords.map((record) => (
                    <tr key={record.id}>
                      <td>{dateTime(record.start_at)}</td>
                      <td><strong>{record.customer_name ?? '—'}</strong><br />{record.customer_phone ?? ''}</td>
                      <td>{record.service_name ?? '—'}</td>
                      <td>{record.employee_name ?? '—'}</td>
                      <td>{record.status_raw ?? '—'}</td>
                      <td>{record.payment_status_raw ?? '—'}</td>
                      <td>{record.amelia_booking_id}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {ameliaRecords.length === 0 && <p className="empty-state">Faça uma busca para consultar o legado Amelia.</p>}
            </div>
          )}
        </section>
      )}

      {detail && <DetailPanel detail={detail} accessToken={accessToken} onClose={() => setDetail(null)} />}
    </main>
  )
}
