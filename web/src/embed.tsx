import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BookingPageDuration } from './BookingPageDuration'
import { BookingCheckoutSession } from './BookingCheckoutSession'
import './embed-base.css'
import './checkout.css'

function mountAgenda(target: HTMLElement) {
  if (target.dataset.bsAgendaMounted === 'true') return
  target.dataset.bsAgendaMounted = 'true'
  const slug = target.dataset.bsAgendaSlug?.trim() || 'sabrina'

  createRoot(target).render(
    <StrictMode>
      <div className="bs-agenda-embed">
        <BookingPageDuration slug={slug} />
        <BookingCheckoutSession />
      </div>
    </StrictMode>,
  )
}

function mountAll() {
  document.querySelectorAll<HTMLElement>('[data-bs-agenda-embed]').forEach(mountAgenda)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mountAll, { once: true })
} else {
  mountAll()
}

const observer = new MutationObserver(mountAll)
observer.observe(document.documentElement, { childList: true, subtree: true })

export { mountAgenda }
