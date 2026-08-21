import { BookingPage } from './BookingPage'
import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'

export function App() {
  const path = window.location.pathname.replace(/\/+$/, '') || '/'

  if (path.startsWith('/admin/demand')) {
    return <DemandCaptureAdmin />
  }

  if (path === '/agendar/sabrina') {
    return <BookingPage slug="sabrina" />
  }

  if (path === '/agendar/blacksheep') {
    return <BookingPage slug="blacksheep" />
  }

  const params = new URLSearchParams(window.location.search)
  return (
    <DemandCaptureForm
      brand={params.get('brand')?.trim() ?? ''}
      campaign={params.get('campaign')?.trim() || null}
    />
  )
}
