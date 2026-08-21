import { FormEvent, useCallback, useEffect, useState } from 'react'
import {
  ApiError,
  downloadDemandCsv,
  getDemandAdmin,
  updateDemandStatus,
  type DemandFilters,
  type DemandRecord,
  type DemandSummary,
} from './api'
import { supabase } from './supabase'

type AdminData = {
  records: DemandRecord[]
  pagination: { page: number; page_size: number; total: number }
  summary: DemandSummary
}

const emptyData: AdminData = {
  records: [],
  pagination: { page: 1, page_size: 100, total: 0 },
  summary: { total: 0, by_date: [], by_period: [], by_service: [] },
}

const statuses: DemandRecord['status'][] = ['NEW', 'CONTACTED', 'CONVERTED', 'DISCARDED']

function dateTime(value: string): string {
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(new Date(value))
}

function dateOnly(value: string | null): string {
  if (!value) return ''
  const [year, month, day] = value.split('-')
  return `${day}/${month}/${year}`
}

function statusLabel(value: DemandRecord['status']): string {
  return ({ NEW: 'Novo', CONTACTED: 'Contatado', CONVERTED: 'Convertido', DISCARDED: 'Descartado' })[value]
}

function periodLabel(value: string | null): string {
  if (!value) return ''
  return ({ MANHA: 'Manhã', TARDE: 'Tarde', NOITE: 'Noite', INDIFERENTE: 'Indiferente' } as Record<string, string>)[value] ?? value
}

export function DemandCaptureAdmin() {
  const [authReady, setAuthReady] = useState(false)
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loginError, setLoginError] = useState('')
  const [filters, setFilters] = useState<DemandFilters>({})
  const [draftFilters, setDraftFilters] = useState<DemandFilters>({})
  const [data, setData] = useState<AdminData>(emptyData)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    supabase.auth.getSession().then(({ data: sessionData }) => {
      setAccessToken(sessionData.session?.access_token ?? null)
      setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setAccessToken(session?.access_token ?? null)
      setAuthReady(true)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  const load = useCallback(async (token: string, activeFilters: DemandFilters) => {
    setLoading(true)
    setError('')
    try {
      setData(await getDemandAdmin(activeFilters, token))
    } catch (requestError) {
      setError(requestError instanceof ApiError && requestError.code.startsWith('ADMIN_')
        ? 'Sua sessão não tem acesso a este painel.'
        : 'Não foi possível carregar os registros.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (accessToken) void load(accessToken, filters)
  }, [accessToken, filters, load])

  async function login(event: FormEvent) {
    event.preventDefault()
    setLoginError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError) setLoginError('Não foi possível entrar com essas credenciais.')
  }

  async function changeStatus(record: DemandRecord, status: DemandRecord['status']) {
    if (!accessToken || status === record.status) return
    try {
      await updateDemandStatus(record.id, status, accessToken)
      setData((current) => ({
        ...current,
        records: current.records.map((item) => item.id === record.id ? { ...item, status } : item),
      }))
    } catch {
      setError('Não foi possível alterar o status deste registro.')
    }
  }

  async function exportCsv() {
    if (!accessToken) return
    try {
      await downloadDemandCsv(filters, accessToken)
    } catch {
      setError('Não foi possível exportar o CSV.')
    }
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>

  if (!accessToken) {
    return (
      <main className="admin-shell login-shell">
        <form className="login-card" onSubmit={login}>
          <h1>Captura de Demanda</h1>
          <label><span>E-mail administrativo</span><input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
          {loginError && <div className="form-alert error" role="alert">{loginError}</div>}
          <button className="primary" type="submit">Entrar</button>
        </form>
      </main>
    )
  }

  return (
    <main className="admin-shell">
      <header className="admin-title-row">
        <div>
          <h1>Captura de Demanda</h1>
          <p>Intenção registrada quando o cliente não encontrou um horário adequado.</p>
        </div>
        <button type="button" className="secondary" onClick={() => supabase.auth.signOut()}>Sair</button>
      </header>

      <section className="filter-card" aria-label="Filtros">
        <label><span>Marca</span><input value={draftFilters.brand ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, brand: e.target.value }))} /></label>
        <label><span>Campanha</span><input value={draftFilters.campaign ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, campaign: e.target.value }))} /></label>
        <label><span>Serviço</span><input value={draftFilters.service ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, service: e.target.value }))} /></label>
        <label><span>Registro de</span><input type="date" value={draftFilters.created_from ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, created_from: e.target.value }))} /></label>
        <label><span>Registro até</span><input type="date" value={draftFilters.created_to ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, created_to: e.target.value }))} /></label>
        <label><span>Data pretendida de</span><input type="date" value={draftFilters.desired_from ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, desired_from: e.target.value }))} /></label>
        <label><span>Data pretendida até</span><input type="date" value={draftFilters.desired_to ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, desired_to: e.target.value }))} /></label>
        <label>
          <span>Status</span>
          <select value={draftFilters.status ?? ''} onChange={(e) => setDraftFilters((f) => ({ ...f, status: e.target.value }))}>
            <option value="">Todos</option>
            {statuses.map((status) => <option key={status} value={status}>{statusLabel(status)}</option>)}
          </select>
        </label>
        <div className="filter-actions">
          <button className="primary" type="button" onClick={() => setFilters({ ...draftFilters })}>Aplicar filtros</button>
          <button className="secondary" type="button" onClick={() => { setDraftFilters({}); setFilters({}) }}>Limpar</button>
          <button className="secondary" type="button" onClick={exportCsv}>Exportar CSV</button>
        </div>
      </section>

      {error && <div className="form-alert error" role="alert">{error}</div>}

      <section className="summary-grid" aria-label="Resumo da demanda">
        <article className="summary-card total"><strong>{data.summary.total}</strong><span>Registros</span></article>
        <article className="summary-card">
          <h2>Datas mais procuradas</h2>
          <ol>{data.summary.by_date.map((item) => <li key={item.date}><span>{dateOnly(item.date)}</span><strong>{item.count}</strong></li>)}</ol>
        </article>
        <article className="summary-card">
          <h2>Períodos</h2>
          <ol>{data.summary.by_period.map((item) => <li key={item.period}><span>{periodLabel(item.period)}</span><strong>{item.count}</strong></li>)}</ol>
        </article>
        <article className="summary-card">
          <h2>Serviços</h2>
          <ol>{data.summary.by_service.map((item) => <li key={item.service}><span>{item.service}</span><strong>{item.count}</strong></li>)}</ol>
        </article>
      </section>

      <section className="table-card">
        <div className="table-heading">
          <h2>Registros</h2>
          <span>{data.pagination.total} no filtro atual</span>
        </div>
        {loading ? <p role="status">Carregando registros.</p> : (
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Registro</th><th>Nome</th><th>WhatsApp</th><th>E-mail</th><th>Marca</th><th>Serviço</th><th>Data pretendida</th><th>Período</th><th>Campanha</th><th>Status</th>
                </tr>
              </thead>
              <tbody>
                {data.records.map((record) => (
                  <tr key={record.id}>
                    <td>{dateTime(record.created_at)}</td>
                    <td>{record.name}</td>
                    <td>{record.whatsapp}</td>
                    <td>{record.email}</td>
                    <td>{record.brand}</td>
                    <td>{record.service_label}</td>
                    <td>{dateOnly(record.desired_date)}</td>
                    <td>{periodLabel(record.desired_period)}</td>
                    <td>{record.campaign ?? ''}</td>
                    <td>
                      <select aria-label={`Status de ${record.name}`} value={record.status} onChange={(e) => void changeStatus(record, e.target.value as DemandRecord['status'])}>
                        {statuses.map((status) => <option key={status} value={status}>{statusLabel(status)}</option>)}
                      </select>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {data.records.length === 0 && <p className="empty-state">Nenhum registro encontrado para os filtros atuais.</p>}
          </div>
        )}
      </section>
    </main>
  )
}
