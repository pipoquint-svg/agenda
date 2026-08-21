import { BookingCheckoutSession } from './BookingCheckoutSession'
import { BookingPage } from './BookingPage'
import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'
import { TrackingConsentBanner } from './TrackingConsentBanner'
import './checkout.css'

function PublicBookingRoute({ slug }: { slug: string }) {
  return (
    <>
      <BookingPage slug={slug} />
      <BookingCheckoutSession />
      <TrackingConsentBanner />
    </>
  )
}

export function App() {
  const path = window.location.pathname.replace(/\/+$/, '') || '/'

  if (path.startsWith('/admin/demand')) {
    return <DemandCaptureAdmin />
  }

  if (path === '/agendar/sabrina') {
    return <PublicBookingRoute slug="sabrina" />
  }

  if (path === '/agendar/blacksheep') {
    return <PublicBookingRoute slug="blacksheep" />
  }

  const params = new URLSearchParams(window.location.search)
  return (
    <>
      <DemandCaptureForm
        brand={params.get('brand')?.trim() ?? ''}
        campaign={params.get('campaign')?.trim() || null}
      />
      <TrackingConsentBanner />
    </>
  )
}
