import { useEffect, useMemo, useState } from 'react'
import {
  addResourceException,
  loadResources,
  removeResourceException,
  replaceResourceAvailability,
  type ResourceAvailabilityRule,
  type ResourceRow,
} from './resourceAdminApi'
import { supabase } from './supabase'

const weekdays = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb']

function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError) setError('Não foi possível entrar.')
  }

  return <main className="admin-shell login-shell"><form className="login-card" onSubmit={submit}>
    <h1>BlackSheep Agenda</h1><p>Gestão de recursos e locais</p>
    <label><span>E-mail</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
    <label><span>Senha</span><input type="password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
    {error ? <div className="form-alert error">{error}</div> : null}
    <button className="primary">Entrar</button>
  </form></main>
}

export function ResourceAdmin() {
  const [ready, setReady] = useState(false)
  const [token, setToken] = useState<string | null>(null)
  const [resources, setResources] = useState<ResourceRow[]>([])
  const [selectedId, setSelectedId] = useState('')
  const [rules, setRules] = useState<ResourceAvailabilityRule[]>([])
  const [exceptionType, setExceptionType] = useState<'BLOCK' | 'OPEN'>('BLOCK')
  const [exceptionStart, setExceptionStart] = useState('')
  const [exceptionEnd, setExceptionEnd] = useState('')
  const [exceptionReason, setExceptionReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setToken(data.session?.access_token ?? null); setReady(true) })
    const { data } = supabase.auth.onAuthStateChange((_event, session) => { setToken(session?.access_token ?? null); setReady(true) })
    return () => data.subscription.unsubscribe()
  }, [])

  const current = useMemo(() => resources.find((resource) => resource.id === selectedId) ?? null, [resources, selectedId])

  async function reload(preferred?: string) {
    if (!token) return
    setError('')
    try {
      const data = await loadResources(token)
      setResources(data)
      const nextId = preferred && data.some((resource) => resource.id === preferred)
        ? preferred
        : selectedId && data.some((resource) => resource.id === selectedId)
          ? selectedId
          : data[0]?.id ?? ''
      setSelectedId(nextId)
      setRules(data.find((resource) => resource.id === nextId)?.availability_rules ?? [])
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Falha ao carregar recursos.')
    }
  }

  useEffect(() => { if (token) void reload() }, [token])
  useEffect(() => { setRules(current?.availability_rules ?? []) }, [current?.id])

  function choose(resource: ResourceRow) {
    setSelectedId(resource.id)
    setRules(resource.availability_rules)
    setError('')
    setMessage('')
  }

  async function saveRules() {
    if (!token || !current) return
    setBusy(true); setError(''); setMessage('')
    try {
      await replaceResourceAvailability(current.id, rules, token)
      setMessage('Disponibilidade semanal atualizada.')
      await reload(current.id)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Falha ao salvar disponibilidade.')
    } finally { setBusy(false) }
  }

  async function addException() {
    if (!token || !current || !exceptionStart || !exceptionEnd) return
    setBusy(true); setError(''); setMessage('')
    try {
      await addResourceException({
        resource_id: current.id,
        exception_type: exceptionType,
        start_at: new Date(exceptionStart).toISOString(),
        end_at: new Date(exceptionEnd).toISOString(),
        reason: exceptionReason,
      }, token)
      setExceptionStart(''); setExceptionEnd(''); setExceptionReason('')
      setMessage(exceptionType === 'BLOCK' ? 'Bloqueio criado.' : 'Abertura especial criada.')
      await reload(current.id)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Falha ao criar exceção.')
    } finally { setBusy(false) }
  }

  async function deleteException(exceptionId: string) {
    if (!token || !current) return
    setBusy(true); setError(''); setMessage('')
    try {
      await removeResourceException(exceptionId, token)
      setMessage('Exceção removida.')
      await reload(current.id)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Falha ao remover exceção.')
    } finally { setBusy(false) }
  }

  if (!ready) return <main className="admin-shell">Carregando…</main>
  if (!token) return <Login />

  return <main className="admin-shell settings-shell">
    <header className="admin-title-row settings-header">
      <div><span className="agenda-eyebrow">Operação</span><h1>Recursos e locais</h1><p>Disponibilidade semanal e exceções explícitas de abertura ou bloqueio.</p></div>
      <div className="agenda-header-actions"><a className="secondary agenda-link-button" href="/gestao/profissionais">Profissionais</a><a className="secondary agenda-link-button" href="/gestao">Gestão</a><button className="secondary" onClick={() => void supabase.auth.signOut()}>Sair</button></div>
    </header>

    {error ? <div className="form-alert error">{error}</div> : null}
    {message ? <div className="form-alert success">{message}</div> : null}

    <div className="employee-layout">
      <aside className="settings-service-list">
        <div className="settings-card-heading"><h2>Recursos</h2></div>
        {resources.map((resource) => <button key={resource.id} className={resource.id === selectedId ? 'active' : ''} onClick={() => choose(resource)}>
          <strong>{resource.name}</strong><span>{resource.is_active ? resource.resource_type : 'Inativo'}</span>
        </button>)}
      </aside>

      <div className="settings-editor">
        {current ? <>
          <section className="settings-card">
            <div className="settings-card-heading"><div><h2>Disponibilidade semanal</h2><p>Mais de uma faixa por dia é permitida.</p></div><span className="agenda-badge agenda-badge-confirmed">{current.resource_type}</span></div>
            <div className="work-rule-list">
              {rules.map((rule, index) => <div key={`${rule.id ?? 'new'}-${index}`} className="work-rule">
                <select value={rule.weekday} onChange={(event) => setRules((items) => items.map((item, n) => n === index ? { ...item, weekday: Number(event.target.value) } : item))}>{weekdays.map((day, n) => <option key={day} value={n}>{day}</option>)}</select>
                <input type="time" value={String(rule.start_local_time).slice(0, 5)} onChange={(event) => setRules((items) => items.map((item, n) => n === index ? { ...item, start_local_time: event.target.value } : item))} />
                <span>até</span>
                <input type="time" value={String(rule.end_local_time).slice(0, 5)} onChange={(event) => setRules((items) => items.map((item, n) => n === index ? { ...item, end_local_time: event.target.value } : item))} />
                <button className="danger-text" onClick={() => setRules((items) => items.filter((_item, n) => n !== index))}>Remover</button>
              </div>)}
            </div>
            <div className="catalog-actions"><button className="secondary" onClick={() => setRules((items) => [...items, { weekday: 1, start_local_time: '09:00', end_local_time: '18:00', is_active: true }])}>+ Faixa</button><button className="primary" disabled={busy} onClick={() => void saveRules()}>{busy ? 'Salvando…' : 'Salvar horários'}</button></div>
          </section>

          <section className="settings-card">
            <h2>Exceções</h2><p className="settings-hint">Use BLOCK para indisponibilidade e OPEN para abrir um período fora da rotina.</p>
            <div className="employee-exception-form">
              <select value={exceptionType} onChange={(event) => setExceptionType(event.target.value as 'BLOCK' | 'OPEN')}><option value="BLOCK">Bloqueio</option><option value="OPEN">Abertura especial</option></select>
              <input type="datetime-local" value={exceptionStart} onChange={(event) => setExceptionStart(event.target.value)} />
              <input type="datetime-local" value={exceptionEnd} onChange={(event) => setExceptionEnd(event.target.value)} />
              <input placeholder="Motivo" value={exceptionReason} onChange={(event) => setExceptionReason(event.target.value)} />
              <button className="secondary" disabled={busy || !exceptionStart || !exceptionEnd} onClick={() => void addException()}>Adicionar</button>
            </div>
            <div className="employee-exception-list">
              {current.exceptions.map((item) => <div key={item.id}><span className={`agenda-badge ${item.exception_type === 'BLOCK' ? 'agenda-badge-cancelled' : 'agenda-badge-confirmed'}`}>{item.exception_type === 'BLOCK' ? 'Bloqueio' : 'Abertura'}</span><strong>{new Date(item.start_at).toLocaleString('pt-BR')} → {new Date(item.end_at).toLocaleString('pt-BR')}</strong><span>{item.reason ?? ''}</span><button className="danger-text" disabled={busy} onClick={() => void deleteException(item.id)}>Excluir</button></div>)}
            </div>
          </section>

          <section className="settings-card"><h2>Serviços vinculados</h2><div className="employee-service-grid">{current.service_bindings.length ? current.service_bindings.map((binding) => <div key={binding.service_id}><span><strong>{binding.service_name}</strong><small>{binding.operation_scope ?? 'Sem operação'}{binding.is_required ? ' • obrigatório' : ''}</small></span></div>) : <p>Nenhum serviço vinculado.</p>}</div></section>
        </> : <section className="settings-card"><h2>Nenhum recurso disponível</h2><p>Cadastre recursos operacionais antes de configurar disponibilidade.</p></section>}
      </div>
    </div>
  </main>
}
