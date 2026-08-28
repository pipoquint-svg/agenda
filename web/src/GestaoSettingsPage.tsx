function basePath(): string {
  return import.meta.env.BASE_URL.replace(/\/+$/, '')
}

const items = [
  ['Operação', '/gestao/configuracoes/operacao', 'Dados públicos, prazos e parâmetros gerais da operação.'],
  ['Catálogo', '/gestao/catalogo', 'Serviços, categorias, preços e estrutura comercial.'],
  ['Profissionais', '/gestao/profissionais', 'Equipe, serviços atendidos, horários e exceções.'],
  ['Recursos', '/gestao/recursos', 'Espaços, disponibilidade, bloqueios e vínculos com serviços.'],
  ['Configurações avançadas', '/gestao/configuracoes-avancadas', 'Regras avançadas de duração, disponibilidade e serviços.'],
  ['Notificações', '/gestao/notificacoes', 'Templates e regras de comunicação.'],
  ['Aniversários', '/gestao/aniversarios', 'Automação de aniversário e cupons.'],
  ['Saúde da operação', '/gestao/saude', 'Estado operacional e integrações.'],
] as const

export function GestaoSettingsPage() {
  const base = basePath()
  return (
    <main className="admin-shell dashboard-shell">
      <header className="admin-title-row dashboard-header">
        <div>
          <span className="agenda-eyebrow">BlackSheep Agenda</span>
          <h1>Configurações</h1>
          <p>Central de configuração administrativa da Agenda.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href={`${base}/gestao/dashboard`}>Dashboard</a>
          <a className="secondary agenda-link-button" href={`${base}/gestao/agenda`}>Agenda</a>
        </div>
      </header>

      <section className="dashboard-metrics" aria-label="Seções de configuração">
        {items.map(([title, path, description]) => (
          <article key={path}>
            <strong>{title}</strong>
            <span>{description}</span>
            <a href={`${base}${path}`}>Abrir</a>
          </article>
        ))}
      </section>
    </main>
  )
}
