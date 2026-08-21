import { DemandCaptureAdmin } from './DemandCaptureAdmin'
import { DemandCaptureForm } from './DemandCaptureForm'

export function App() {
  if (window.location.pathname.startsWith('/admin/demand')) {
    return <DemandCaptureAdmin />
  }

  const params = new URLSearchParams(window.location.search)
  return (
    <DemandCaptureForm
      brand={params.get('brand')?.trim() ?? ''}
      campaign={params.get('campaign')?.trim() || null}
    />
  )
}
