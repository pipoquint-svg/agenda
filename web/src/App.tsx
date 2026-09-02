import { useEffect, type ReactElement } from 'react'
import { AdminBalancesPage } from './AdminBalancesPage'
import { AdminDashboard } from './AdminDashboard'
import { AgendaAdmin } from './AgendaAdmin'
import { BalanceCollectionPage } from './BalanceCollectionPage'
import { BirthdaySettingsAdmin } from './BirthdaySettingsAdmin'
import { BookingCheckoutSession } from './BookingCheckoutSession'
import { BookingPageDuration } from './BookingPageDuration'
import { CouponAdmin } from './CouponAdmin'
import { CustomerAdmin } from './CustomerAdmin'
import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'
import { EmployeeAdmin } from './EmployeeAdmin'
import { GestaoEntry } from './GestaoEntry'
import { GestaoSettingsPage } from './GestaoSettingsPage'
import { ManageReservation } from './ManageReservation'
import { NotificationsAdmin } from './NotificationsAdmin'
import { OperationSettingsAdmin } from './OperationSettingsAdmin'
import { OpsHealthAdmin } from './OpsHealthAdmin'
import { PasswordRecoveryPage } from './PasswordRecoveryPage'
import { PreReservationPaymentPage } from './PreReservationPaymentPage'
import { ResourceAdmin } from './ResourceAdmin'
import { ServiceCatalogAdmin } from './ServiceCatalogAdmin'
import { ServiceSettingsAdmin } from './ServiceSettingsAdmin'
import { TrackingConsentBanner } from './TrackingConsentBanner'
import { trackPublicPage } from './tracking'
import './agendaAdmin.css'
import './serviceSettingsAdmin.css'
import './couponAdmin.css'
import './employeeAdmin.css'
import './checkout.css'

function PublicBookingRoute({ slug }: { slug: string }) {
  useEffect(() => { trackPublicPage({ pageType: 'BOOKING', brand: slug.toUpperCase(), pageSlug: slug }) }, [slug])
  return <><BookingPageDuration slug={slug} /><BookingCheckoutSession /><TrackingConsentBanner /></>
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

export function App() {
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
  if (path === '/agendar/sabrina' || path === '/sabrina-pierri') return <PublicBookingRoute slug="sabrina" />
  if (path === '/agendar/blacksheep' || path === '/agendamento' || path === '/agenda') return <PublicBookingRoute slug="blacksheep" />
  if (path === '/pre-reserva/confirmar' || path === '/confirmar-pre-reserva') return <PreReservationPaymentPage />
  if (path === '/reserva/gerenciar' || path === '/gerenciar-reserva') return <ManageReservation />
  if (path === '/reserva/saldo' || path === '/pagar-saldo') return <BalanceCollectionPage />
  const params = new URLSearchParams(window.location.search)
  return <PublicDemandRoute brand={params.get('brand')?.trim() ?? ''} campaign={params.get('campaign')?.trim() || null} />
}
