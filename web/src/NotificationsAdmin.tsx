import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { functionsBaseUrl, publicApiKey, supabase } from './supabase'

type Template = {
  id: string; event_key: string; channel: string; audience: string; operation_scope: string | null;
  category_id: string | null; title_template: string; body_template: string; is_active: boolean;
  variable_schema: string[]; reminder_offset_minutes: number | null; service_ids: string[]; version_count: number;
}
type Option = { id: string; name: string; operation_scope?: string; category_id?: string | null; operation_code?: string; is_active?: boolean }
type Payload = {
  templates: Template[]; services: Option[]; categories: Option[];
  options: { events: string[]; channels: string[]; audiences: string[]; variables: string[] }
}

const samples: Record<string, string> = {
  'appointment.public_code': 'BS-TESTE-2026', 'appointment.start_at': '29/08/2026 14:00', 'appointment.end_at': '29/08/2026 15:00',
  'customer.name': 'Cliente de Teste', 'customer.email': 'teste@example.com', 'employee.name': 'Profissional de Teste',
  'service.name': 'Serviço de Teste', 'service.description': 'Descrição sintética do serviço', 'operation.name': 'BlackSheep',
  'operation.email': 'teste@example.com', 'operation.phone': '(48) 0000-0000', 'operation.address': 'Endereço de teste',
  'operation.site_url': 'https://example.com', 'payment.total': 'R$ 180,00', 'payment.status': 'APROVADO',
  'extras.summary': 'Extra de teste', 'coupon.code': 'TESTE10', 'coupon.discount': 'R$ 18,00',
}
function renderPreview(text: string) {
  return text.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, key) => samples[String(key).trim()] ?? `{{${key}}}`)
}
async function api<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${functionsBaseUrl}/admin-notifications${path}`, {
    ...init,
    headers: { apikey: publicApiKey, authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init?.headers ?? {}) },
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(body?.error?.code ?? `HTTP_${response.status}`)
  return body as T
}

export function NotificationsAdmin() {
  const [token, setToken] = useState<string | null>(null)
  const [data, setData] = useState<Payload | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [form, setForm] = useState({ event_key: 'APPOINTMENT_APPROVED', channel: 'EMAIL', audience: 'CUSTOMER', operation_scope: 'BLACKSHEEP', category_id: '', title_template: '', body_template: '', is_active: false, reminder_offset_minutes: '', service_ids: [] as string[], variable_schema: [] as string[] })
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

  const load = useCallback(async (accessToken: string) => {
    const next = await api<Payload>(accessToken, '')
    setData(next)
  }, [])
  useEffect(() => {
    supabase.auth.getSession().then(({ data: auth }) => {
      const accessToken = auth.session?.access_token ?? null
      setToken(accessToken)
      if (accessToken) void load(accessToken).catch((e) => setError(e instanceof Error ? e.message : 'LOAD_FAILED'))
    })
  }, [load])

  const filteredCategories = useMemo(() => (data?.categories ?? []).filter((item) => !form.operation_scope || item.operation_code === form.operation_scope), [data, form.operation_scope])
  const filteredServices = useMemo(() => (data?.services ?? []).filter((item) => !form.operation_scope || item.operation_scope === form.operation_scope).filter((item) => !form.category_id || item.category_id === form.category_id), [data, form.operation_scope, form.category_id])

  function edit(template: Template) {
    setSelectedId(template.id)
    setForm({
      event_key: template.event_key, channel: template.channel, audience: template.audience, operation_scope: template.operation_scope ?? '',
      category_id: template.category_id ?? '', title_template: template.title_template, body_template: template.body_template,
      is_active: template.is_active, reminder_offset_minutes: template.reminder_offset_minutes == null ? '' : String(template.reminder_offset_minutes),
      service_ids: template.service_ids ?? [], variable_schema: template.variable_schema ?? [],
    })
    setMessage(''); setError('')
  }
  function fresh() {
    setSelectedId(null)
    setForm({ event_key: 'APPOINTMENT_APPROVED', channel: 'EMAIL', audience: 'CUSTOMER', operation_scope: 'BLACKSHEEP', category_id: '', title_template: '', body_template: '', is_active: false, reminder_offset_minutes: '', service_ids: [], variable_schema: [] })
  }
  function toggle(list: string[], value: string) { return list.includes(value) ? list.filter((item) => item !== value) : [...list, value] }

  async function submit(event: FormEvent) {
    event.preventDefault(); if (!token) return
    setError(''); setMessage('')
    try {
      await api(token, '', {
        method: selectedId ? 'PUT' : 'POST',
        body: JSON.stringify({ ...form, template_id: selectedId, operation_scope: form.operation_scope || null, category_id: form.category_id || null, reminder_offset_minutes: form.reminder_offset_minutes === '' ? null : Number(form.reminder_offset_minutes) }),
      })
      await load(token); setMessage('Template salvo e versionado.'); if (!selectedId) fresh()
    } catch (e) { setError(e instanceof Error ? e.message : 'SAVE_FAILED') }
  }

  if (!token) return <main className="admin-shell"><h1>Notificações</h1><p>Entre pela Gestão para acessar esta área.</p></main>
  if (!data) return <main className="admin-shell"><h1>Notificações</h1><p>{error || 'Carregando…'}</p></main>

  return <main className="admin-shell" style={{ maxWidth: 1180, margin: '0 auto', padding: 24 }}>
    <header className="admin-title-row"><div><span className="agenda-eyebrow">BlackSheep Agenda</span><h1>Notificações e templates</h1><p>Configure e-mails e textos de calendário por evento e serviço. O preview usa somente dados sintéticos.</p></div><div className="agenda-header-actions"><a className="secondary agenda-link-button" href="/admin/configuracoes">Configurações</a><button className="primary" type="button" onClick={fresh}>Novo template</button></div></header>
    {error && <div className="form-alert error">{error}</div>}{message && <div className="form-alert success">{message}</div>}
    <section style={{ display: 'grid', gridTemplateColumns: 'minmax(280px, 0.8fr) minmax(420px, 1.4fr)', gap: 20, alignItems: 'start' }}>
      <div className="settings-card"><h2>Templates</h2>{data.templates.length === 0 ? <p>Nenhum template cadastrado.</p> : data.templates.map((item) => <button type="button" key={item.id} onClick={() => edit(item)} style={{ width: '100%', textAlign: 'left', marginBottom: 8, padding: 12 }}><strong>{item.event_key}</strong><br/><small>{item.channel} · {item.audience} · {item.operation_scope ?? 'GLOBAL'} · v{item.version_count} · {item.is_active ? 'Ativo' : 'Desligado'}</small></button>)}</div>
      <form className="settings-card" onSubmit={submit}><h2>{selectedId ? 'Editar template' : 'Novo template'}</h2>
        <div className="settings-grid">
          <label><span>Evento</span><select value={form.event_key} onChange={(e) => setForm((f) => ({ ...f, event_key: e.target.value }))}>{data.options.events.map((v) => <option key={v}>{v}</option>)}</select></label>
          <label><span>Canal</span><select value={form.channel} onChange={(e) => setForm((f) => ({ ...f, channel: e.target.value }))}>{data.options.channels.map((v) => <option key={v}>{v}</option>)}</select></label>
          <label><span>Destinatário</span><select value={form.audience} onChange={(e) => setForm((f) => ({ ...f, audience: e.target.value }))}>{data.options.audiences.map((v) => <option key={v}>{v}</option>)}</select></label>
          <label><span>Operação</span><select value={form.operation_scope} onChange={(e) => setForm((f) => ({ ...f, operation_scope: e.target.value, category_id: '', service_ids: [] }))}><option value="">Global</option><option value="SABRINA">Sabrina</option><option value="BLACKSHEEP">BlackSheep</option></select></label>
          <label><span>Categoria</span><select value={form.category_id} onChange={(e) => setForm((f) => ({ ...f, category_id: e.target.value, service_ids: [] }))}><option value="">Todas</option>{filteredCategories.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
          <label><span>Lembrete (min antes)</span><input type="number" min="0" value={form.reminder_offset_minutes} onChange={(e) => setForm((f) => ({ ...f, reminder_offset_minutes: e.target.value }))}/></label>
        </div>
        <label><span>Título / assunto</span><input required value={form.title_template} onChange={(e) => setForm((f) => ({ ...f, title_template: e.target.value }))}/></label>
        <label><span>Corpo / descrição</span><textarea rows={8} value={form.body_template} onChange={(e) => setForm((f) => ({ ...f, body_template: e.target.value }))}/></label>
        <fieldset><legend>Serviços</legend>{filteredServices.map((v) => <label key={v.id} style={{ display: 'block' }}><input type="checkbox" checked={form.service_ids.includes(v.id)} onChange={() => setForm((f) => ({ ...f, service_ids: toggle(f.service_ids, v.id) }))}/> {v.name}</label>)}</fieldset>
        <fieldset><legend>Variáveis liberadas</legend>{data.options.variables.map((v) => <label key={v} style={{ display: 'inline-block', margin: '0 12px 8px 0' }}><input type="checkbox" checked={form.variable_schema.includes(v)} onChange={() => setForm((f) => ({ ...f, variable_schema: toggle(f.variable_schema, v) }))}/> {v}</label>)}</fieldset>
        <label><input type="checkbox" checked={form.is_active} onChange={(e) => setForm((f) => ({ ...f, is_active: e.target.checked }))}/> Ativar template</label>
        <section className="settings-card" style={{ marginTop: 16 }}><h3>Preview sintético</h3><strong>{renderPreview(form.title_template || 'Título do template')}</strong><p style={{ whiteSpace: 'pre-wrap' }}>{renderPreview(form.body_template || 'Corpo do template')}</p></section>
        <div className="settings-actions"><button className="primary" type="submit">Salvar template</button></div>
      </form>
    </section>
  </main>
}
