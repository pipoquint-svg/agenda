import { FormEvent, useEffect, useMemo, useState } from 'react'
import {
  addEmployeeException,
  clearEmployeeWriteCalendar,
  createEmployee,
  loadEmployees,
  mapEmployeeBlockingCalendar,
  removeEmployeeException,
  replaceEmployeeServices,
  replaceWorkHours,
  setEmployeeWriteCalendar,
  unmapEmployeeBlockingCalendar,
  updateEmployee,
  type EmployeeBundle,
  type EmployeeRow,
  type EmployeeWorkRule,
} from './employeeAdminApi'
import { supabase } from './supabase'

const weekdays = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb']
type Draft = { id:string; name:string; email:string; phone:string; notes:string; is_active:boolean; service_ids:string[] }
const blank = (): Draft => ({ id:'', name:'', email:'', phone:'', notes:'', is_active:true, service_ids:[] })
const fromEmployee = (employee: EmployeeRow): Draft => ({
  id: employee.id,
  name: employee.name,
  email: employee.email ?? '',
  phone: employee.phone ?? '',
  notes: employee.notes ?? '',
  is_active: employee.is_active,
  service_ids: employee.service_assignments.filter((assignment) => assignment.is_active).map((assignment) => assignment.service_id),
})

function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  async function submit(event: FormEvent) {
    event.preventDefault()
    setError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError) setError('Não foi possível entrar.')
  }
  return <main className="admin-shell login-shell"><form className="login-card" onSubmit={submit}><h1>BlackSheep Agenda</h1><p>Gestão de funcionários</p><label><span>E-mail</span><input type="email" value={email} onChange={(event)=>setEmail(event.target.value)} /></label><label><span>Senha</span><input type="password" value={password} onChange={(event)=>setPassword(event.target.value)} /></label>{error ? <div className="form-alert error">{error}</div> : null}<button className="primary">Entrar</button></form></main>
}

export function EmployeeAdmin() {
  const [ready, setReady] = useState(false)
  const [token, setToken] = useState<string | null>(null)
  const [bundle, setBundle] = useState<EmployeeBundle | null>(null)
  const [selected, setSelected] = useState('')
  const [draft, setDraft] = useState<Draft>(blank())
  const [creating, setCreating] = useState(false)
  const [assignmentId, setAssignmentId] = useState('')
  const [rules, setRules] = useState<EmployeeWorkRule[]>([])
  const [exceptionType, setExceptionType] = useState<'BLOCK'|'OPEN'>('BLOCK')
  const [exceptionStart, setExceptionStart] = useState('')
  const [exceptionEnd, setExceptionEnd] = useState('')
  const [exceptionReason, setExceptionReason] = useState('')
  const [writeCalendarId, setWriteCalendarId] = useState('')
  const [writeScope, setWriteScope] = useState<'FULL_APPOINTMENT'|'CORE_ONLY'>('FULL_APPOINTMENT')
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setToken(data.session?.access_token ?? null); setReady(true) })
    const { data } = supabase.auth.onAuthStateChange((_event, session) => { setToken(session?.access_token ?? null); setReady(true) })
    return () => data.subscription.unsubscribe()
  }, [])

  const current = useMemo(() => bundle?.employees.find((employee) => employee.id === selected) ?? null, [bundle, selected])
  const assignment = useMemo(() => current?.service_assignments.find((item) => item.service_employee_id === assignmentId) ?? null, [current, assignmentId])

  function syncAssignment(row: EmployeeRow | null) {
    const next = row?.service_assignments.find((item) => item.is_active) ?? row?.service_assignments[0] ?? null
    setAssignmentId(next?.service_employee_id ?? '')
    setRules(next?.work_hours ?? [])
    setWriteCalendarId(next?.write_calendar?.google_calendar_id ?? '')
    setWriteScope(next?.write_calendar?.time_scope === 'CORE_ONLY' ? 'CORE_ONLY' : 'FULL_APPOINTMENT')
  }

  async function reload(preferred?: string) {
    if (!token) return
    setError('')
    try {
      const data = await loadEmployees(token)
      setBundle(data)
      const id = preferred && data.employees.some((employee) => employee.id === preferred)
        ? preferred
        : selected && data.employees.some((employee) => employee.id === selected)
          ? selected
          : data.employees[0]?.id ?? ''
      setSelected(id)
      const row = data.employees.find((employee) => employee.id === id) ?? null
      if (row) { setDraft(fromEmployee(row)); syncAssignment(row); setCreating(false) }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Falha ao carregar funcionários.')
    }
  }

  useEffect(() => { if (token) void reload() }, [token])
  useEffect(() => {
    setRules(assignment?.work_hours ?? [])
    setWriteCalendarId(assignment?.write_calendar?.google_calendar_id ?? '')
    setWriteScope(assignment?.write_calendar?.time_scope === 'CORE_ONLY' ? 'CORE_ONLY' : 'FULL_APPOINTMENT')
  }, [assignment])

  function patch(next: Partial<Draft>) { setDraft((value) => ({ ...value, ...next })) }
  function choose(row: EmployeeRow) { setSelected(row.id); setDraft(fromEmployee(row)); setCreating(false); syncAssignment(row) }

  async function saveEmployee() {
    if (!token) return
    setBusy(true); setError(''); setMessage('')
    try {
      if (creating) {
        const row = await createEmployee({ name:draft.name, email:draft.email, phone:draft.phone, notes:draft.notes }, token) as EmployeeRow
        await replaceEmployeeServices(row.id, draft.service_ids, token)
        setMessage('Funcionário criado.')
        await reload(row.id)
      } else {
        await updateEmployee({ employee_id:draft.id, name:draft.name, email:draft.email, phone:draft.phone, notes:draft.notes, is_active:draft.is_active }, token)
        await replaceEmployeeServices(draft.id, draft.service_ids, token)
        setMessage('Funcionário atualizado.')
        await reload(draft.id)
      }
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao salvar.') } finally { setBusy(false) }
  }

  async function saveRules() {
    if (!token || !assignmentId) return
    setBusy(true); setError('')
    try { await replaceWorkHours(assignmentId, rules, token); setMessage('Horários atualizados.'); await reload(draft.id) }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao salvar horários.') }
    finally { setBusy(false) }
  }

  async function addException() {
    if (!token || !assignmentId || !exceptionStart || !exceptionEnd) return
    setBusy(true); setError('')
    try {
      await addEmployeeException({ service_employee_id:assignmentId, exception_type:exceptionType, start_at:new Date(exceptionStart).toISOString(), end_at:new Date(exceptionEnd).toISOString(), reason:exceptionReason }, token)
      setExceptionStart(''); setExceptionEnd(''); setExceptionReason('')
      setMessage(exceptionType === 'BLOCK' ? 'Folga/bloqueio criado.' : 'Abertura especial criada.')
      await reload(draft.id)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao criar exceção.') }
    finally { setBusy(false) }
  }

  async function removeException(id: string) {
    if (!token) return
    setError('')
    try { await removeEmployeeException(id, token); await reload(draft.id) }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao remover exceção.') }
  }

  async function saveWriteCalendar() {
    if (!token || !assignmentId) return
    setBusy(true); setError('')
    try {
      if (writeCalendarId) await setEmployeeWriteCalendar(assignmentId, writeCalendarId, writeScope, token)
      else await clearEmployeeWriteCalendar(assignmentId, token)
      setMessage(writeCalendarId ? 'Calendário de escrita atualizado.' : 'Calendário de escrita removido.')
      await reload(draft.id)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao atualizar calendário de escrita.') }
    finally { setBusy(false) }
  }

  async function toggleBlockingCalendar(calendarId: string, checked: boolean) {
    if (!token || !current) return
    setBusy(true); setError('')
    try {
      if (checked) await mapEmployeeBlockingCalendar(current.id, calendarId, token)
      else await unmapEmployeeBlockingCalendar(current.id, calendarId, token)
      setMessage('Calendários que bloqueiam disponibilidade atualizados.')
      await reload(current.id)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Falha ao atualizar calendário de bloqueio.') }
    finally { setBusy(false) }
  }

  if (!ready) return <main className="admin-shell">Carregando…</main>
  if (!token) return <Login />

  return <main className="admin-shell settings-shell">
    <header className="admin-title-row settings-header"><div><span className="agenda-eyebrow">Equipe</span><h1>Funcionários</h1><p>Serviços, horários, folgas e calendários.</p></div><div className="agenda-header-actions"><a className="secondary agenda-link-button" href="/admin/catalogo">Catálogo</a><a className="secondary agenda-link-button" href="/admin/agenda">Agenda</a><button className="secondary" onClick={()=>void supabase.auth.signOut()}>Sair</button></div></header>
    {error ? <div className="form-alert error">{error}</div> : null}{message ? <div className="form-alert success">{message}</div> : null}
    <div className="employee-layout">
      <aside className="settings-service-list"><div className="settings-card-heading"><h2>Equipe</h2><button className="secondary" onClick={()=>{setCreating(true);setSelected('');setDraft(blank());syncAssignment(null)}}>+ Novo</button></div>{bundle?.employees.map((employee)=><button key={employee.id} className={employee.id===selected?'active':''} onClick={()=>choose(employee)}><strong>{employee.name}</strong><span>{employee.is_active?'Ativo':'Inativo'}</span></button>)}</aside>
      <div className="settings-editor">
        <section className="settings-card"><h2>Dados do funcionário</h2><div className="settings-field-grid"><label><span>Nome</span><input value={draft.name} onChange={(event)=>patch({name:event.target.value})}/></label><label><span>E-mail</span><input type="email" value={draft.email} onChange={(event)=>patch({email:event.target.value})}/></label><label><span>Telefone</span><input value={draft.phone} onChange={(event)=>patch({phone:event.target.value})}/></label><label className="settings-check"><input type="checkbox" checked={draft.is_active} onChange={(event)=>patch({is_active:event.target.checked})}/>Ativo</label><label className="settings-field-full"><span>Observação interna</span><textarea value={draft.notes} onChange={(event)=>patch({notes:event.target.value})}/></label></div><h3>Serviços que realiza</h3><div className="employee-service-grid">{bundle?.services.filter((service)=>service.is_active).map((service)=><label key={service.id}><input type="checkbox" checked={draft.service_ids.includes(service.id)} onChange={(event)=>patch({service_ids:event.target.checked?[...draft.service_ids,service.id]:draft.service_ids.filter((id)=>id!==service.id)})}/><span><strong>{service.name}</strong><small>{service.operation_scope} • {service.category_name??'Sem categoria'}</small></span></label>)}</div><div className="catalog-actions"><button className="primary" disabled={busy||!draft.name.trim()} onClick={()=>void saveEmployee()}>{busy?'Salvando…':creating?'Criar funcionário':'Salvar funcionário'}</button></div></section>

        {!creating && current ? <>
          <section className="settings-card"><div className="settings-card-heading"><div><h2>Horário de trabalho</h2><p>Configure por serviço; mais de uma faixa no mesmo dia é permitida.</p></div><select value={assignmentId} onChange={(event)=>setAssignmentId(event.target.value)}>{current.service_assignments.filter((item)=>item.is_active).map((item)=><option key={item.service_employee_id} value={item.service_employee_id}>{item.service_name}</option>)}</select></div>{assignmentId?<><div className="work-rule-list">{rules.map((rule,index)=><div key={`${rule.id??'new'}-${index}`} className="work-rule"><select value={rule.weekday} onChange={(event)=>setRules((items)=>items.map((item,n)=>n===index?{...item,weekday:Number(event.target.value)}:item))}>{weekdays.map((day,n)=><option key={day} value={n}>{day}</option>)}</select><input type="time" value={String(rule.start_local_time).slice(0,5)} onChange={(event)=>setRules((items)=>items.map((item,n)=>n===index?{...item,start_local_time:event.target.value}:item))}/><span>até</span><input type="time" value={String(rule.end_local_time).slice(0,5)} onChange={(event)=>setRules((items)=>items.map((item,n)=>n===index?{...item,end_local_time:event.target.value}:item))}/><button className="danger-text" onClick={()=>setRules((items)=>items.filter((_item,n)=>n!==index))}>Remover</button></div>)}</div><div className="catalog-actions"><button className="secondary" onClick={()=>setRules((items)=>[...items,{weekday:1,start_local_time:'09:00',end_local_time:'18:00',slot_interval_minutes:30,is_active:true}])}>+ Faixa</button><button className="primary" disabled={busy} onClick={()=>void saveRules()}>Salvar horários</button></div></>:<p>Vincule um serviço para configurar horários.</p>}</section>

          <section className="settings-card"><h2>Folgas e dias especiais</h2>{assignment?<><div className="employee-exception-form"><select value={exceptionType} onChange={(event)=>setExceptionType(event.target.value as 'BLOCK'|'OPEN')}><option value="BLOCK">Folga / bloqueio</option><option value="OPEN">Abertura especial</option></select><input type="datetime-local" value={exceptionStart} onChange={(event)=>setExceptionStart(event.target.value)}/><input type="datetime-local" value={exceptionEnd} onChange={(event)=>setExceptionEnd(event.target.value)}/><input placeholder="Motivo" value={exceptionReason} onChange={(event)=>setExceptionReason(event.target.value)}/><button className="secondary" disabled={busy||!exceptionStart||!exceptionEnd} onClick={()=>void addException()}>Adicionar</button></div><div className="employee-exception-list">{assignment.exceptions.map((item)=><div key={item.id}><span className={`agenda-badge ${item.exception_type==='BLOCK'?'agenda-badge-cancelled':'agenda-badge-confirmed'}`}>{item.exception_type==='BLOCK'?'Folga':'Abertura'}</span><strong>{new Date(item.start_at).toLocaleString('pt-BR')} → {new Date(item.end_at).toLocaleString('pt-BR')}</strong><span>{item.reason??''}</span><button className="danger-text" onClick={()=>void removeException(item.id)}>Excluir</button></div>)}</div></>:<p>Selecione um serviço.</p>}</section>

          <section className="settings-card"><h2>Google Calendar</h2><p className="settings-hint">A conta nunca é conectada automaticamente. Esta tela só trabalha com calendários já autorizados.</p><h3>Calendários que bloqueiam a disponibilidade</h3>{current.resource_id?<div className="employee-calendar-grid">{bundle?.google_calendars.map((calendar)=><label key={calendar.id}><input type="checkbox" checked={current.blocking_calendar_ids?.includes(calendar.id)??false} disabled={busy} onChange={(event)=>void toggleBlockingCalendar(calendar.id,event.target.checked)}/><span><strong>{calendar.name}</strong><small>Eventos ocupados deste calendário bloqueiam este funcionário.</small></span></label>)}</div>:<p>Este funcionário ainda não possui recurso técnico associado; o bloqueio por calendário fica indisponível até o recurso existir.</p>}
          <h3>Calendário que recebe as reservas</h3>{assignment?<div className="employee-calendar-write"><label><span>Calendário</span><select value={writeCalendarId} onChange={(event)=>setWriteCalendarId(event.target.value)}><option value="">Não escrever reserva</option>{bundle?.google_calendars.filter((calendar)=>calendar.writable).map((calendar)=><option key={calendar.id} value={calendar.id}>{calendar.name}</option>)}</select></label><label><span>Escopo de horário</span><select value={writeScope} onChange={(event)=>setWriteScope(event.target.value as 'FULL_APPOINTMENT'|'CORE_ONLY')}><option value="FULL_APPOINTMENT">Reserva + buffers</option><option value="CORE_ONLY">Só horário do cliente</option></select></label><button className="primary" disabled={busy} onClick={()=>void saveWriteCalendar()}>Salvar calendário</button></div>:<p>Selecione um serviço.</p>}</section>
        </> : null}
      </div>
    </div>
  </main>
}
