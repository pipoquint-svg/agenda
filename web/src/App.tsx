import { Suspense, lazy, useEffect, type ReactElement } from 'react'
import { TrackingConsentBanner } from './TrackingConsentBanner'
import { trackPublicPage } from './tracking'

// Route-level components are lazy-loaded so a visitor to any single page (public
// booking or one admin screen) only downloads that page's code, not every other
// page + admin panel + the Mercado Pago SDK in the same bundle.
const AdminBalancesPage = lazy(() => import('./AdminBalancesPage').then((m) => ({ default: m.AdminBalancesPage })))
const AdminDashboard = lazy(() => import('./AdminDashboard').then((m) => ({ default: m.AdminDashboard })))
const AgendaAdmin = lazy(() => import('./AgendaAdmin').then((m) => ({ default: m.AgendaAdmin })))
const BalanceCollectionPage = lazy(() => import('./BalanceCollectionPage').then((m) => ({ default: m.BalanceCollectionPage })))
const BirthdaySettingsAdmin = lazy(() => import('./BirthdaySettingsAdmin').then((m) => ({ default: m.BirthdaySettingsAdmin })))
const BookingCheckoutSession = lazy(() => import('./BookingCheckoutSession').then((m) => ({ default: m.BookingCheckoutSession })))
const BookingPageDuration = lazy(() => import('./BookingPageDuration').then((m) => ({ default: m.BookingPageDuration })))
const CouponAdmin = lazy(() => import('./CouponAdmin').then((m) => ({ default: m.CouponAdmin })))
const CustomerAdmin = lazy(() => import('./CustomerAdmin').then((m) => ({ default: m.CustomerAdmin })))
const DemandCaptureAdmin = lazy(() => import('./DemandCaptureAdmin').then((m) => ({ default: m.DemandCaptureAdmin })))
const DemandCaptureForm = lazy(() => import('./DemandCaptureForm').then((m) => ({ default: m.DemandCaptureForm })))
const EmployeeAdmin = lazy(() => import('./EmployeeAdmin').then((m) => ({ default: m.EmployeeAdmin })))
const GestaoEntry = lazy(() => import('./GestaoEntry').then((m) => ({ default: m.GestaoEntry })))
const GestaoSettingsPage = lazy(() => import('./GestaoSettingsPage').then((m) => ({ default: m.GestaoSettingsPage })))
const ManageReservation = lazy(() => import('./ManageReservation').then((m) => ({ default: m.ManageReservation })))
const NotificationsAdmin = lazy(() => import('./NotificationsAdmin').then((m) => ({ default: m.NotificationsAdmin })))
const OperationSettingsAdmin = lazy(() => import('./OperationSettingsAdmin').then((m) => ({ default: m.OperationSettingsAdmin })))
const OpsHealthAdmin = lazy(() => import('./OpsHealthAdmin').then((m) => ({ default: m.OpsHealthAdmin })))
const PasswordRecoveryPage = lazy(() => import('./PasswordRecoveryPage').then((m) => ({ default: m.PasswordRecoveryPage })))
const PreReservationPaymentPage = lazy(() => import('./PreReservationPaymentPage').then((m) => ({ default: m.PreReservationPaymentPage })))
const ResourceAdmin = lazy(() => import('./ResourceAdmin').then((m) => ({ default: m.ResourceAdmin })))
const SabrinaBookingJourney = lazy(() => import('./SabrinaBookingJourney').then((m) => ({ default: m.SabrinaBookingJourney })))
const ServiceCatalogAdmin = lazy(() => import('./ServiceCatalogAdmin').then((m) => ({ default: m.ServiceCatalogAdmin })))
const ServiceSettingsAdmin = lazy(() => import('./ServiceSettingsAdmin').then((m) => ({ default: m.ServiceSettingsAdmin })))
const WaitlistPrivateInvitePage = lazy(() => import('./WaitlistPrivateInvitePage').then((m) => ({ default: m.WaitlistPrivateInvitePage })))

function RouteLoadingFallback() {
  return (
    <div role="status" aria-live="polite" style={{ padding: '48px 20px', textAlign: 'center', color: '#666' }}>
      Carregando…
    </div>
  )
}

function BlackSheepVisitCallout() {
  const base = import.meta.env.BASE_URL.replace(/\/+$/, '')
  return (
    <aside style={{ maxWidth: 1040, margin: '24px auto -8px', padding: '0 20px' }}>
      <div style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 20,
        flexWrap: 'wrap',
        padding: '20px 22px',
        border: '1px solid rgba(17,17,17,.12)',
        borderRadius: 20,
        background: '#fff',
        boxShadow: '0 10px 30px rgba(0,0,0,.04)',
      }}>
        <div style={{ maxWidth: 680 }}>
          <small style={{ fontWeight: 700, letterSpacing: '.08em', textTransform: 'uppercase' }}>Quer conhecer antes de reservar?</small>
          <h2 style={{ margin: '6px 0 6px', fontSize: 'clamp(1.25rem, 3vw, 1.65rem)' }}>Conhecer o estúdio sem compromisso</h2>
          <p style={{ margin: 0, lineHeight: 1.5 }}>Agende uma visita gratuita de 30 minutos. O horário fica reservado para você e não há nenhum pagamento.</p>
        </div>
        <a
          href={`${base}/agendar/blacksheep/visita`}
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            minHeight: 46,
            padding: '0 18px',
            borderRadius: 12,
            background: '#171717',
            color: '#fff',
            fontWeight: 700,
            textDecoration: 'none',
            whiteSpace: 'nowrap',
          }}
        >
          Agendar visita gratuita
        </a>
      </div>
    </aside>
  )
}

function PublicBookingRoute({ slug }: { slug: string }) {
  useEffect(() => { trackPublicPage({ pageType: 'BOOKING', brand: slug.toUpperCase(), pageSlug: slug }) }, [slug])
  return <>{slug === 'blacksheep' ? <BlackSheepVisitCallout /> : null}<BookingPageDuration slug={slug} /><BookingCheckoutSession /><TrackingConsentBanner /></>
}

function PublicSabrinaBookingRoute({ slug }: { slug: string }) {
  useEffect(() => { trackPublicPage({ pageType: 'BOOKING', brand: 'SABRINA', pageSlug: slug }) }, [slug])
  return <><SabrinaBookingJourney slug={slug} /><TrackingConsentBanner /></>
}

function PublicPrivateInviteRoute({ accessToken }: { accessToken: string }) {
  // The access token lives in the URL path. Do not initialize analytics or
  // attribution on this route, otherwise page_location/landing_path could copy
  // the bearer secret into third-party or attribution telemetry.
  return <WaitlistPrivateInvitePage accessToken={accessToken} />
}

function PublicDemandRoute({ brand, campaign }: { brand: string; campaign: string | null }) {
  useEffect(() => { trackPublicPage({ pageType: 'DEMAND', brand }) }, [brand])
  return <><DemandCaptureForm brand={brand} campaign={campaign} /><TrackingConsentBanner /></>
}

function EnvironmentBanner() {
  const environment = String(import.meta.env.VITE_APP_ENV ?? 'production').trim().toLowerCase()
  if (!environment || environment === 'production') return null
  return (
    <div
      data-environment-banner={environment}
      role="status"
      style={{
        position: 'fixed',
        top: 8,
        right: 8,
        zIndex: 10000,
        padding: '6px 10px',
        borderRadius: 999,
        background: '#111',
        color: '#fff',
        fontSize: 12,
        fontWeight: 700,
        letterSpacing: '.04em',
        boxShadow: '0 2px 8px rgba(0,0,0,.2)',
      }}
    >
      AMBIENTE {environment.toUpperCase()} — DADOS DE TESTE
    </div>
  )
}

function applicationPath(): string {
  const base = import.meta.env.BASE_URL.replace(/\/+$/, '')
  let path = window.location.pathname.replace(/\/+$/, '') || '/'
  if (base && base !== '/' && (path === base || path.startsWith(`${base}/`))) path = path.slice(base.length) || '/'
  return path
}

function AppRoutes() {
  const path = applicationPath()
  const adminPage = (content: ReactElement) => <><EnvironmentBanner />{content}</>

  if (path.startsWith('/gestao/recuperar-senha')) return adminPage(<PasswordRecoveryPage />)
  if (path.startsWith('/gestao/recursos')) return adminPage(<ResourceAdmin />)
  if (path.startsWith('/gestao/profissionais')) return adminPage(<EmployeeAdmin />)
  if (path.startsWith('/gestao/configuracoes-avancadas')) return adminPage(<ServiceSettingsAdmin />)
  if (path.startsWith('/gestao/configuracoes/operacao')) return adminPage(<OperationSettingsAdmin />)
  if (path === '/gestao/configuracoes') return adminPage(<GestaoSettingsPage />)
  if (path.startsWith('/gestao/catalogo')) return adminPage(<ServiceCatalogAdmin />)
  if (path.startsWith('/gestao/agenda')) return adminPage(<AgendaAdmin />)
  if (path.startsWith('/gestao/clientes')) return adminPage(<CustomerAdmin />)
  if (path.startsWith('/gestao/pagamentos')) return adminPage(<AdminBalancesPage />)
  if (path.startsWith('/gestao/cupons')) return adminPage(<CouponAdmin />)
  if (path.startsWith('/gestao/notificacoes')) return adminPage(<NotificationsAdmin />)
  if (path.startsWith('/gestao/aniversarios')) return adminPage(<BirthdaySettingsAdmin />)
  if (path.startsWith('/gestao/saude')) return adminPage(<OpsHealthAdmin />)
  if (path.startsWith('/gestao/demand')) return adminPage(<DemandCaptureAdmin />)
  if (path === '/gestao' || path.startsWith('/gestao/dashboard')) return adminPage(<GestaoEntry />)

  if (path.startsWith('/admin/pagamentos')) return adminPage(<AdminBalancesPage />)
  if (path.startsWith('/admin/cupons')) return adminPage(<CouponAdmin />)
  if (path.startsWith('/admin/clientes')) return adminPage(<CustomerAdmin />)
  if (path.startsWith('/admin/funcionarios')) return adminPage(<EmployeeAdmin />)
  if (path.startsWith('/admin/notificacoes')) return adminPage(<NotificationsAdmin />)
  if (path.startsWith('/admin/aniversarios')) return adminPage(<BirthdaySettingsAdmin />)
  if (path.startsWith('/admin/saude')) return adminPage(<OpsHealthAdmin />)
  if (path === '/admin' || path.startsWith('/admin/dashboard')) return adminPage(<AdminDashboard />)
  if (path.startsWith('/admin/configuracoes-avancadas')) return adminPage(<ServiceSettingsAdmin />)
  if (path.startsWith('/admin/configuracoes')) return adminPage(<OperationSettingsAdmin />)
  if (path.startsWith('/admin/catalogo')) return adminPage(<ServiceCatalogAdmin />)
  if (path.startsWith('/admin/agenda')) return adminPage(<AgendaAdmin />)
  if (path.startsWith('/admin/demand')) return adminPage(<DemandCaptureAdmin />)

  if (path === '/agendar/sabrina/essencial' || path === '/sabrina-pierri/essencial') {
    return <PublicSabrinaBookingRoute slug="sabrina-essencial" />
  }
  if (path === '/agendar/sabrina/signature' || path === '/sabrina-pierri/signature') {
    return <PublicSabrinaBookingRoute slug="sabrina-signature" />
  }
  if (path === '/agendar/sabrina' || path === '/sabrina-pierri') return <PublicSabrinaBookingRoute slug="sabrina" />
  if (path === '/agendar/blacksheep/visita' || path === '/conhecer-o-estudio') return <PublicBookingRoute slug="blacksheep-visita" />
  if (path === '/agendar/blacksheep' || path === '/agendamento' || path === '/agenda') return <PublicBookingRoute slug="blacksheep" />

  const inviteMatch = path.match(/^\/convite-natal\/([A-Za-z0-9_-]{32,})$/)
  if (inviteMatch) return <PublicPrivateInviteRoute accessToken={inviteMatch[1]} />
  if (path === '/pre-reserva/confirmar' || path === '/confirmar-pre-reserva') return <PreReservationPaymentPage />
  if (path === '/reserva/gerenciar' || path === '/gerenciar-reserva') return <ManageReservation />
  if (path === '/reserva/saldo' || path === '/pagar-saldo') return <BalanceCollectionPage />
  const params = new URLSearchParams(window.location.search)
  return <PublicDemandRoute brand={params.get('brand')?.trim() ?? ''} campaign={params.get('campaign')?.trim() || null} />
}

export function App() {
  return (
    <Suspense fallback={<RouteLoadingFallback />}>
      <AppRoutes />
    </Suspense>
  )
}
