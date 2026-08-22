import { useEffect } from 'react'
import { AgendaAdmin } from './AgendaAdmin'
import { BookingCheckoutSession } from './BookingCheckoutSession'
import { BookingPageDuration } from './BookingPageDuration'
import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'
import { ServiceSettingsAdmin } from './ServiceSettingsAdmin'
import { TrackingConsentBanner } from './TrackingConsentBanner'
import { trackPublicPage } from './tracking'
import './agendaAdmin.css'
import './serviceSettingsAdmin.css'
import './checkout.css'

function PublicBookingRoute({ slug }: { slug: string }) {
  useEffect(() => {
    trackPublicPage({ pageType: 'BOOKING', brand: slug.toUpperCase(), pageSlug: slug })
  }, [slug])

  return (
    <>
      <BookingPageDuration slug={slug} />
      <BookingCheckoutSession />
      <TrackingConsentBanner />
    </>
  )
}

function PublicDemandRoute({ brand, campaign }: { brand: string; campaign: string | null }) {
  useEffect(() => {
    trackPublicPage({ pageType: 'DEMAND', brand })
  }, [brand])

  return (
    <>
      <DemandCaptureForm brand={brand} campaign={campaign} />
      <TrackingConsentBanner />
    </>
  )
}

export function App() {
  const path = window.location.pathname.replace(/\/+$/, '') || '/'

  if (path.startsWith('/admin/configuracoes')) return <ServiceSettingsAdmin />
  if (path.startsWith('/admin/agenda')) return <AgendaAdmin />
  if (path.startsWith('/admin/demand')) return <DemandCaptureAdmin />

  if (path === '/agendar/sabrina') return <PublicBookingRoute slug="sabrina" />
  if (path === '/agendar/blacksheep') return <PublicBookingRoute slug="blacksheep" />

  const params = new URLSearchParams(window.location.search)
  return (
    <PublicDemandRoute
      brand={params.get('brand')?.trim() ?? ''}
      campaign={params.get('campaign')?.trim() || null}
    />
  )
}
