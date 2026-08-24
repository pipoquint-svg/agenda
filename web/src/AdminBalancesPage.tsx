import { FormEvent, useEffect, useState } from 'react'
import { AdminBalancesPanel } from './AdminBalancesPanel'
import { supabase } from './supabase'

export function AdminBalancesPage(){
  const [ready,setReady]=useState(false)
  const [accessToken,setAccessToken]=useState<string|null>(null)
  const [email,setEmail]=useState('')
  const [password,setPassword]=useState('')
  const [loginError,setLoginError]=useState('')
  const [scope,setScope]=useState<''|'BLACKSHEEP'|'SABRINA'>('BLACKSHEEP')

  useEffect(()=>{
    supabase.auth.getSession().then(({data})=>{setAccessToken(data.session?.access_token??null);setReady(true)})
    const {data:listener}=supabase.auth.onAuthStateChange((_event,session)=>{setAccessToken(session?.access_token??null);setReady(true)})
    return()=>listener.subscription.unsubscribe()
  },[])

  async function login(event:FormEvent){
    event.preventDefault();setLoginError('')
    const {error}=await supabase.auth.signInWithPassword({email,password})
    if(error)setLoginError('Não foi possível entrar com essas credenciais.')
  }

  if(!ready)return <main className="admin-shell"><p>Carregando acesso.</p></main>
  if(!accessToken)return <main className="admin-shell login-shell"><form className="login-card" onSubmit={login}><h1>BlackSheep Agenda</h1><p>Controle financeiro</p><label><span>E-mail</span><input type="email" autoComplete="username" value={email} onChange={e=>setEmail(e.target.value)}/></label><label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)}/></label>{loginError?<div className="form-alert error">{loginError}</div>:null}<button className="primary" type="submit">Entrar</button></form></main>

  return <main className="admin-shell dashboard-shell">
    <header className="admin-title-row dashboard-header"><div><span className="agenda-eyebrow">BlackSheep Agenda</span><h1>Pagamentos</h1><p>Controle de saldos, cobranças e inadimplência.</p></div><div className="agenda-header-actions"><a className="secondary agenda-link-button" href="/admin/dashboard">Dashboard</a><a className="secondary agenda-link-button" href="/admin/agenda">Agenda</a><button className="secondary" type="button" onClick={()=>supabase.auth.signOut()}>Sair</button></div></header>
    <section className="dashboard-filters"><label><span>Operação</span><select value={scope} onChange={e=>setScope(e.target.value as ''|'BLACKSHEEP'|'SABRINA')}><option value="BLACKSHEEP">BlackSheep</option><option value="SABRINA">Sabrina</option><option value="">Todas</option></select></label></section>
    <AdminBalancesPanel accessToken={accessToken} operationScope={scope}/>
  </main>
}
