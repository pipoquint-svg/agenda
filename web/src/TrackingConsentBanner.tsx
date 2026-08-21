import { useEffect, useState } from 'react'
import { getTrackingConsent, initTracking, setTrackingConsent, type TrackingConsent } from './tracking'

export function TrackingConsentBanner() {
  const [consent, setConsent] = useState<TrackingConsent>(() => getTrackingConsent())

  useEffect(() => {
    if (consent === 'granted') initTracking()
    const listener = (event: Event) => {
      const value = (event as CustomEvent<TrackingConsent>).detail
      if (value) setConsent(value)
    }
    window.addEventListener('bs-tracking-consent', listener)
    return () => window.removeEventListener('bs-tracking-consent', listener)
  }, [consent])

  if (consent !== 'unknown') return null

  return (
    <aside className="tracking-consent" role="dialog" aria-label="Preferências de medição">
      <div>
        <strong>Podemos medir sua jornada?</strong>
        <p>Usamos Google Analytics e Meta Pixel para entender o desempenho da agenda e das campanhas. Não enviamos nome, telefone, e-mail ou CPF para essas plataformas.</p>
      </div>
      <div className="tracking-consent-actions">
        <button type="button" className="secondary" onClick={() => setTrackingConsent('denied')}>Agora não</button>
        <button type="button" className="primary" onClick={() => setTrackingConsent('granted')}>Permitir medição</button>
      </div>
    </aside>
  )
}
