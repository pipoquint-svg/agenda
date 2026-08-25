import { useEffect } from 'react'
import { AdminBalancesPage } from './AdminBalancesPage'
import { AdminDashboard } from './AdminDashboard'
import { AgendaAdmin } from './AgendaAdmin'
import { BalanceCollectionPage } from './BalanceCollectionPage'
import { BookingCheckoutSession } from './BookingCheckoutSession'
import { BookingPageDuration } from './BookingPageDuration'
import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'
import { EmployeeAdmin } from './EmployeeAdmin'
import { ManageReservation } from './ManageReservation'
import { ServiceCatalogAdmin } from './ServiceCatalogAdmin'
import { ServiceSettingsAdmin } from './ServiceSettingsAdmin'
import { TrackingConsentBanner } from './TrackingConsentBanner'
import { trackPublicPage } from './tracking'
import './agendaAdmin.css'
import './serviceSettingsAdmin.css'
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

function applicationPath(): string {
  const base = import.meta.env.BASE_URL.replace(/\/+$/, '')
  let path = window.location.pathname.replace(/\/+$/, '') || '/'
  if (base && base !== '/' && (path === base || path.startsWith(`${base}/`))) path = path.slice(base.length) || '/'
  return path
}

export function App() {
  const path = applicationPath()
  if (path.startsWith('/admin/pagamentos')) return <AdminBalancesPage />
  if (path.startsWith('/admin/funcionarios')) return <EmployeeAdmin />
  if (path === '/admin' || path.startsWith('/admin/dashboard')) return <AdminDashboard />
  if (path.startsWith('/admin/configuracoes-avancadas')) return <ServiceSettingsAdmin />
  if (path.startsWith('/admin/configuracoes') || path.startsWith('/admin/catalogo')) return <ServiceCatalogAdmin />
  if (path.startsWith('/admin/agenda')) return <AgendaAdmin />
  if (path.startsWith('/admin/demand')) return <DemandCaptureAdmin />
  if (path === '/agendar/sabrina') return <PublicBookingRoute slug="sabrina" />
  if (path === '/agendar/blacksheep') return <PublicBookingRoute slug="blacksheep" />
  if (path === '/reserva/gerenciar' || path === '/gerenciar-reserva') return <ManageReservation />
  if (path === '/reserva/saldo' || path === '/pagar-saldo') return <BalanceCollectionPage />
  const params = new URLSearchParams(window.location.search)
  return <PublicDemandRoute brand={params.get('brand')?.trim() ?? ''} campaign={params.get('campaign')?.trim() || null} />
}
