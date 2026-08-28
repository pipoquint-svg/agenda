import { FormEvent, useEffect, useState } from 'react'
import { AdminDashboard } from './AdminDashboard'
import { supabase } from './supabase'

function basePath(): string {
  return import.meta.env.BASE_URL.replace(/\/+$/, '')
}

export function GestaoEntry() {
  const [ready, setReady] = useState(false)
  const [authenticated, setAuthenticated] = useState(false)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      setAuthenticated(Boolean(data.session))
      setReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!active) return
      setAuthenticated(Boolean(session))
      setReady(true)
    })
    return () => {
      active = false
      listener.subscription.unsubscribe()
    }
  }, [])

  async function login(event: FormEvent) {
    event.preventDefault()
    setError('')
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim().toLowerCase(), password })
    if (signInError) setError('Não foi possível entrar com essas credenciais.')
  }

  if (!ready) return <main className="admin-shell"><p>Carregando acesso.</p></main>

  if (!authenticated) {
    return (
      <main className="admin-shell login-shell">
        <form className="login-card" onSubmit={login}>
          <h1>BlackSheep Agenda</h1>
          <p>Gestão administrativa</p>
          <label><span>E-mail</span><input type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
          <label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
          {error && <div className="form-alert error" role="alert">{error}</div>}
          <button className="primary" type="submit">Entrar</button>
          <a href={`${basePath()}/gestao/recuperar-senha`}>Esqueci minha senha</a>
        </form>
      </main>
    )
  }

  return (
    <>
      <nav className="admin-shell" aria-label="Atalhos da gestão">
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href={`${basePath()}/gestao/dashboard`}>Dashboard</a>
          <a className="secondary agenda-link-button" href={`${basePath()}/gestao/agenda`}>Agenda</a>
          <a className="secondary agenda-link-button" href={`${basePath()}/gestao/configuracoes`}>Configurações</a>
        </div>
      </nav>
      <AdminDashboard />
    </>
  )
}
