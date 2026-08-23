import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import {
  AdminDashboardApiError,
  getAdminDashboard,
  type AdminDashboardResponse,
  type DashboardPendingItem,
  type DashboardScope,
} from './adminDashboardApi'
import { supabase } from './supabase'
import './adminDashboard.css'

const emptyDashboard: AdminDashboardResponse = {
  range: { start_at: '', end_at: '' },
  operation_scope: null,
  metrics: {
    booking_count: 0,
    booked_minutes: 0,
    new_booking_count: 0,
    cancellations_count: 0,
    reschedules_count: 0,
  },
  by_employee: [],
  pending_items: [],
  occupancy: {
    available: false,
    reason: 'OCCUPANCY_RESOURCE_NOT_CONFIGURED',
    resource_id: null,
    capacity_minutes: null,
    total_occupied_minutes: null,
    appointment_minutes: null,
    filtered_appointment_minutes: null,
    external_block_minutes: null,
    manual_block_minutes: null,
    total_rate_percent: null,
    appointment_rate_percent: null,
    filtered_appointment_rate_percent: null,
  },
}

function saoPauloToday(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${values.year}-${values.month}-${values.day}`
}

function addDays(date: string, days: number): string {
  const value = new Date(`${date}T12:00:00-03:00`)
  value.setUTCDate(value.getUTCDate() + days)
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(value)
}

function dashboardRange(startDate: string, endDate: string): { startAt: string; endAt: string } {
  const start = new Date(`${startDate}T00:00:00-03:00`)
  const end = new Date(`${endDate}T00:00:00-03:00`)
  end.setUTCDate(end.getUTCDate() + 1)
  return { startAt: start.toISOString(), endAt: end.toISOString() }
}

function number(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function minutes(value: number | string | null | undefined): string {
  const total = Math.round(number(value))
  const hours = Math.floor(total / 60)
  const rest = total % 60
  if (!hours) return `${rest} min`
  if (!rest) return `${hours}h`
  return `${hours}h ${rest}min`
}

function percentage(value: number | string | null | undefined): string {
  return `${number(value).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`
}

function dateTime(value: string | null | undefined): string {
  if (!value) return '—'
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function pendingLabel(kind: string): string {
  const labels: Record<string, string> = {
    PRE_RESERVATION_ACTIVE: 'Pré-reserva ativa',
    APPOINTMENT_HELD: 'Reserva em hold',
    PAYMENT_AWAITING: 'Pagamento aguardando',
    RESCHEDULE_DIFFERENCE_PENDING: 'Diferença de remarcação',
    RESCHEDULE_PENALTY_PENDING: 'Multa de remarcação',
    CANCELLATION_REFUND_PENDING: 'Reembolso de cancelamento',
    INTEGRATION_DIVERGENCE: 'Divergência de agenda',
  }
  return labels[kind] ?? kind.replaceAll('_', ' ').toLowerCase()
}

function occupancyMessage(reason: string | null): string {
  const messages: Record<string, string> = {
    OCCUPANCY_RESOURCE_NOT_CONFIGURED: 'O recurso físico-base de ocupação ainda não foi configurado.',
    OCCUPANCY_AVAILABILITY_RULES_OVERLAP: 'A ocupação está indisponível porque existem regras de disponibilidade sobrepostas.',
    OCCUPANCY_HAS_AVAILABILITY_EXCEPTIONS: 'A ocupação está indisponível neste período porque há exceções de disponibilidade.',
    OCCUPANCY_CAPACITY_NOT_CONFIGURED_FOR_PERIOD: 'Não há capacidade configurada para calcular a ocupação deste período.',
  }
  return messages[reason ?? ''] ?? 'A taxa de ocupação não pode ser calculada com segurança neste período.'
}

function pendingMoment(item: DashboardPendingItem): string | null {
  return item.start_at ?? item.detected_at ?? item.expires_at ?? null
}

export function AdminDashboard() {
  const today = useMemo(saoPauloToday, [])
  const [authReady, setAuthReady] = useState(false)
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loginError, setLoginError] = useState('')
  const [startDate, setStartDate] = useState(() => addDays(today, -6))
  const [endDate, setEndDate] = useState(today)
  const [scope, setScope] = useState<DashboardScope>('')
  const [dashboard, setDashboard] = useState<AdminDashboardResponse>(emptyDashboard)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

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

  const loadDashboard = useCallback(async (token: string, start: string, end: string, operationScope: DashboardScope) => {
    setLoading(true)
    setError('')
    try {
      if (!start || !end || start > end) throw new Error('INVALID_RANGE')
      const range = dashboardRange(start, end)
      const days = Math.ceil((new Date(range.endAt).getTime() - new Date(range.startAt).getTime()) / 86_400_000)
      if (days > 31) throw new Error('RANGE_TOO_LARGE')
      setDashboard(await getAdminDashboard({ ...range, operationScope, accessToken: token }))
    } catch (requestError) {
      if (requestError instanceof AdminDashboardApiError && requestError.code === 'ADMIN_PERMISSION_DENIED') {
        setError('Sua sessão não possui acesso ao Dashboard.')
      } else if (requestError instanceof Error && requestError.message === 'RANGE_TOO_LARGE') {
        setError('O período máximo do Dashboard é de 31 dias.')
      } else if (requestError instanceof Error && requestError.message === 'INVALID_RANGE') {
        setError('Escolha um período válido.')
      } else {
        setError('Não foi possível carregar o Dashboard.')
      }
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (accessToken) void loadDashboard(accessToken, startDate, endDate, scope)
  }, [accessToken, endDate, loadDashboard, scope, startDate])

  async function login(event: FormEvent) {
    event.preventDefault()
    setLoginError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError) setLoginError('Não foi possível entrar com essas credenciais.')
  }

  function setPreset(days: number) {
    const current = saoPauloToday()
    setEndDate(current)
    setStartDate(addDays(current, -(days - 1)))
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>

  if (!accessToken) {
    return (
      <main className="admin-shell login-shell">
        <form className="login-card" onSubmit={login}>
          <h1>BlackSheep Agenda</h1>
          <p>Dashboard administrativo</p>
          <label><span>E-mail</span><input type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
          <label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
          {loginError && <div className="form-alert error" role="alert">{loginError}</div>}
          <button className="primary" type="submit">Entrar</button>
        </form>
      </main>
    )
  }

  const metrics = dashboard.metrics
  const occupancy = dashboard.occupancy

  return (
    <main className="admin-shell dashboard-shell">
      <header className="admin-title-row dashboard-header">
        <div>
          <span className="agenda-eyebrow">BlackSheep Agenda</span>
          <h1>Dashboard</h1>
          <p>Operação, pendências e ocupação com dados autoritativos do backend.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href="/admin/agenda">Agenda</a>
          <a className="secondary agenda-link-button" href="/admin/configuracoes">Configurações</a>
          <a className="secondary agenda-link-button" href="/admin/demand">Demanda</a>
          <button className="secondary" type="button" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>

      <section className="dashboard-filters" aria-label="Filtros do dashboard">
        <label><span>De</span><input type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} /></label>
        <label><span>Até</span><input type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} /></label>
        <label><span>Operação</span>
          <select value={scope} onChange={(event) => setScope(event.target.value as DashboardScope)}>
            <option value="">Todas</option>
            <option value="BLACKSHEEP">BlackSheep</option>
            <option value="SABRINA">Sabrina</option>
          </select>
        </label>
        <div className="dashboard-presets">
          <button className="secondary" type="button" onClick={() => setPreset(7)}>7 dias</button>
          <button className="secondary" type="button" onClick={() => setPreset(30)}>30 dias</button>
        </div>
      </section>

      {error && <div className="form-alert error" role="alert">{error}</div>}
      {loading ? <p role="status">Atualizando indicadores.</p> : null}

      <section className="dashboard-metrics" aria-label="Indicadores">
        <article><span>Reservas no período</span><strong>{metrics.booking_count}</strong></article>
        <article><span>Tempo contratado</span><strong>{minutes(metrics.booked_minutes)}</strong></article>
        <article><span>Novos agendamentos</span><strong>{metrics.new_booking_count}</strong></article>
        <article><span>Remarcações</span><strong>{metrics.reschedules_count}</strong></article>
        <article><span>Cancelamentos</span><strong>{metrics.cancellations_count}</strong></article>
        <article><span>Pendências visíveis</span><strong>{dashboard.pending_items.length}</strong></article>
      </section>

      <div className="dashboard-columns">
        <section className="dashboard-card">
          <div className="table-heading">
            <div><h2>Centro de Pendências</h2><span>Somente estados reais; itens financeiros dependem da sua permissão.</span></div>
          </div>
          <div className="dashboard-pending-list">
            {dashboard.pending_items.map((item) => (
              <article key={`${item.entity_type}:${item.entity_id}`}>
                <div>
                  <strong>{pendingLabel(item.kind)}</strong>
                  <span>{item.service_name ?? item.customer_name ?? 'Item operacional'}</span>
                </div>
                <div>
                  <span>{item.customer_name ?? item.status ?? '—'}</span>
                  <small>{dateTime(pendingMoment(item))}</small>
                </div>
                {item.appointment_id ? <a href={`/admin/agenda?appointment=${encodeURIComponent(item.appointment_id)}`}>Abrir reserva</a> : null}
              </article>
            ))}
            {dashboard.pending_items.length === 0 ? <p className="empty-state">Nenhuma pendência visível neste período.</p> : null}
          </div>
        </section>

        <section className="dashboard-card occupancy-card">
          <div className="table-heading"><h2>Ocupação</h2><span>Sem estimativas quando o denominador não é seguro.</span></div>
          {occupancy.available ? (
            <>
              <div className="occupancy-rate"><strong>{percentage(occupancy.total_rate_percent)}</strong><span>ocupação total</span></div>
              <dl className="occupancy-breakdown">
                <div><dt>Capacidade</dt><dd>{minutes(occupancy.capacity_minutes)}</dd></div>
                <div><dt>Reservas</dt><dd>{minutes(occupancy.appointment_minutes)}</dd></div>
                <div><dt>Bloqueios externos</dt><dd>{minutes(occupancy.external_block_minutes)}</dd></div>
                <div><dt>Bloqueios manuais</dt><dd>{minutes(occupancy.manual_block_minutes)}</dd></div>
                {dashboard.operation_scope ? <div><dt>Reservas {dashboard.operation_scope === 'SABRINA' ? 'Sabrina' : 'BlackSheep'}</dt><dd>{percentage(occupancy.filtered_appointment_rate_percent)}</dd></div> : null}
              </dl>
            </>
          ) : (
            <div className="occupancy-unavailable">
              <strong>Ocupação indisponível</strong>
              <p>{occupancyMessage(occupancy.reason)}</p>
            </div>
          )}
        </section>
      </div>

      <section className="dashboard-card">
        <div className="table-heading"><h2>Resumo por profissional</h2><span>Reservas e tempo contratado no período.</span></div>
        <div className="dashboard-employee-list">
          {dashboard.by_employee.map((employee) => (
            <article key={employee.employee_id ?? employee.employee_name ?? 'unassigned'}>
              <strong>{employee.employee_name ?? 'Sem profissional atribuído'}</strong>
              <span>{employee.booking_count} reserva(s)</span>
              <span>{minutes(employee.booked_minutes)}</span>
            </article>
          ))}
          {dashboard.by_employee.length === 0 ? <p className="empty-state">Sem reservas para resumir neste período.</p> : null}
        </div>
      </section>
    </main>
  )
}
