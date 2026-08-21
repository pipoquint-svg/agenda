export type TrackingConsent = 'unknown' | 'granted' | 'denied'

export type AttributionSnapshot = {
  visitor_id: string
  session_id: string
  landing_path: string
  referrer: string | null
  utm_source: string | null
  utm_medium: string | null
  utm_campaign: string | null
  utm_content: string | null
  utm_term: string | null
  fbclid: string | null
  gclid: string | null
}

type TrackingParams = Record<string, string | number | boolean | null | undefined>
type QueuedEvent = () => void

const CONSENT_KEY = 'bs_tracking_consent_v1'
const VISITOR_KEY = 'bs_tracking_visitor_v1'
const SESSION_KEY = 'bs_tracking_session_v1'
const ATTRIBUTION_KEY = 'bs_tracking_attribution_v1'
const SENT_KEY = 'bs_tracking_sent_v1'
const MAX_SENT_IDS = 250

const gaMeasurementId = import.meta.env.VITE_GA_MEASUREMENT_ID?.trim() ?? ''
const metaPixelId = import.meta.env.VITE_META_PIXEL_ID?.trim() ?? ''

let initialized = false
let queue: QueuedEvent[] = []

function storage(): Storage | null {
  try { return window.localStorage } catch { return null }
}

function sessionStorageSafe(): Storage | null {
  try { return window.sessionStorage } catch { return null }
}

function safeText(value: string | null | undefined, max = 180): string | null {
  const next = value?.trim()
  return next ? next.slice(0, max) : null
}

function getOrCreate(key: string, store: Storage | null): string {
  const existing = store?.getItem(key)
  if (existing) return existing
  const created = crypto.randomUUID()
  try { store?.setItem(key, created) } catch { /* storage is best effort */ }
  return created
}

export function getTrackingConsent(): TrackingConsent {
  const value = storage()?.getItem(CONSENT_KEY)
  return value === 'granted' || value === 'denied' ? value : 'unknown'
}

export function setTrackingConsent(value: Exclude<TrackingConsent, 'unknown'>): void {
  try { storage()?.setItem(CONSENT_KEY, value) } catch { /* best effort */ }
  if (value === 'granted') {
    initTracking()
    const pending = queue
    queue = []
    pending.forEach((send) => send())
  } else {
    queue = []
  }
  window.dispatchEvent(new CustomEvent('bs-tracking-consent', { detail: value }))
}

function currentAttributionFromUrl(): AttributionSnapshot {
  const params = new URLSearchParams(window.location.search)
  return {
    visitor_id: getOrCreate(VISITOR_KEY, storage()),
    session_id: getOrCreate(SESSION_KEY, sessionStorageSafe()),
    landing_path: `${window.location.pathname}${window.location.search}`.slice(0, 500),
    referrer: safeText(document.referrer, 500),
    utm_source: safeText(params.get('utm_source')),
    utm_medium: safeText(params.get('utm_medium')),
    utm_campaign: safeText(params.get('utm_campaign')),
    utm_content: safeText(params.get('utm_content')),
    utm_term: safeText(params.get('utm_term')),
    fbclid: safeText(params.get('fbclid'), 300),
    gclid: safeText(params.get('gclid'), 300),
  }
}

export function captureAttribution(): AttributionSnapshot {
  const store = sessionStorageSafe()
  const existingRaw = store?.getItem(ATTRIBUTION_KEY)
  if (existingRaw) {
    try { return JSON.parse(existingRaw) as AttributionSnapshot } catch { /* refresh invalid snapshot */ }
  }
  const snapshot = currentAttributionFromUrl()
  try { store?.setItem(ATTRIBUTION_KEY, JSON.stringify(snapshot)) } catch { /* best effort */ }
  return snapshot
}

export function attributionForBackend(): AttributionSnapshot | null {
  if (getTrackingConsent() !== 'granted') return null
  return captureAttribution()
}

function ensureDataLayer() {
  window.dataLayer = window.dataLayer || []
  window.gtag = window.gtag || function gtag(...args: unknown[]) { window.dataLayer?.push(args) }
}

function loadGa() {
  if (!gaMeasurementId || document.querySelector(`script[data-bs-ga="${gaMeasurementId}"]`)) return
  ensureDataLayer()
  const script = document.createElement('script')
  script.async = true
  script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(gaMeasurementId)}`
  script.dataset.bsGa = gaMeasurementId
  document.head.appendChild(script)
  window.gtag?.('js', new Date())
  window.gtag?.('config', gaMeasurementId, { send_page_view: false, allow_google_signals: true })
}

function loadMeta() {
  if (!metaPixelId || window.fbq) return
  const fbq = function (...args: unknown[]) {
    if (fbq.callMethod) fbq.callMethod(...args)
    else fbq.queue.push(args)
  } as Window['fbq'] & { queue: unknown[][]; callMethod?: (...args: unknown[]) => void; loaded?: boolean; version?: string }
  fbq.queue = []
  fbq.loaded = true
  fbq.version = '2.0'
  window.fbq = fbq
  const script = document.createElement('script')
  script.async = true
  script.src = 'https://connect.facebook.net/en_US/fbevents.js'
  script.dataset.bsMeta = metaPixelId
  document.head.appendChild(script)
  window.fbq?.('init', metaPixelId)
}

export function initTracking(): void {
  if (initialized || getTrackingConsent() !== 'granted') return
  initialized = true
  captureAttribution()
  loadGa()
  loadMeta()
}

function dispatch(send: QueuedEvent): void {
  const consent = getTrackingConsent()
  if (consent === 'denied') return
  if (consent !== 'granted') {
    queue.push(send)
    return
  }
  initTracking()
  send()
}

function clean(params: TrackingParams): Record<string, string | number | boolean> {
  return Object.fromEntries(Object.entries(params).filter(([, value]) => value !== null && value !== undefined)) as Record<string, string | number | boolean>
}

function once(eventId: string): boolean {
  const store = storage()
  if (!store) return true
  let ids: string[] = []
  try { ids = JSON.parse(store.getItem(SENT_KEY) ?? '[]') as string[] } catch { ids = [] }
  if (ids.includes(eventId)) return false
  ids.push(eventId)
  if (ids.length > MAX_SENT_IDS) ids = ids.slice(ids.length - MAX_SENT_IDS)
  try { store.setItem(SENT_KEY, JSON.stringify(ids)) } catch { /* best effort */ }
  return true
}

function ga(name: string, params: TrackingParams): void {
  if (!gaMeasurementId) return
  window.gtag?.('event', name, clean(params))
}

function meta(name: string, params: TrackingParams, eventId?: string, custom = false): void {
  if (!metaPixelId) return
  const command = custom ? 'trackCustom' : 'track'
  if (eventId) window.fbq?.(command, name, clean(params), { eventID: eventId })
  else window.fbq?.(command, name, clean(params))
}

export function trackPublicPage(input: { pageType: 'BOOKING' | 'DEMAND'; brand: string; pageSlug?: string }): void {
  const eventId = `page:${input.pageType}:${input.pageSlug ?? input.brand}:${window.location.pathname}`
  dispatch(() => {
    ga('page_view', {
      page_title: document.title,
      page_location: window.location.href,
      page_path: window.location.pathname,
      bs_page_type: input.pageType,
      bs_brand: input.brand,
      bs_page_slug: input.pageSlug,
    })
    meta('PageView', {}, eventId)
  })
}

export function trackServiceSelected(input: { brand: string; serviceId: string; serviceName: string; value: number }): void {
  dispatch(() => {
    ga('view_item', {
      currency: 'BRL', value: input.value,
      items: [{ item_id: input.serviceId, item_name: input.serviceName, item_brand: input.brand, price: input.value, quantity: 1 }],
    } as unknown as TrackingParams)
    meta('ViewContent', { content_ids: input.serviceId, content_name: input.serviceName, content_type: 'service', value: input.value, currency: 'BRL' })
  })
}

export function trackFunnelStep(name: string, params: TrackingParams = {}): void {
  dispatch(() => {
    ga(name, params)
    meta(name, params, undefined, true)
  })
}

export function trackHoldCreated(input: { holdId: string; brand: string; serviceId: string; serviceName: string; value: number; people: number }): void {
  const eventId = `hold:${input.holdId}:checkout`
  if (!once(eventId)) return
  dispatch(() => {
    ga('begin_checkout', {
      currency: 'BRL', value: input.value, bs_brand: input.brand, bs_people_count: input.people,
      items: [{ item_id: input.serviceId, item_name: input.serviceName, item_brand: input.brand, price: input.value, quantity: 1 }],
    } as unknown as TrackingParams)
    meta('InitiateCheckout', { content_ids: input.serviceId, content_name: input.serviceName, content_type: 'service', value: input.value, currency: 'BRL', num_items: 1 }, eventId)
  })
}

export function trackCustomerDetailsCompleted(input: { holdId: string; brand: string; serviceId: string; value: number }): void {
  const eventId = `hold:${input.holdId}:customer`
  if (!once(eventId)) return
  trackFunnelStep('customer_details_completed', { bs_brand: input.brand, service_id: input.serviceId, currency: 'BRL', value: input.value })
}

export function trackAppointmentCreated(input: { appointmentId: string; publicCode: string; serviceName: string; value: number; status: string; packageReserved: boolean }): void {
  const eventId = `appointment:${input.appointmentId}:created`
  if (!once(eventId)) return
  trackFunnelStep('booking_created', {
    transaction_id: input.appointmentId,
    public_code: input.publicCode,
    service_name: input.serviceName,
    currency: 'BRL', value: input.value,
    appointment_status: input.status,
    package_reserved: input.packageReserved,
  })
}

export function trackPaymentInfo(input: { appointmentId: string; method: 'PIX' | 'CARD'; value: number; paymentKind: 'MINIMUM' | 'FULL' }): void {
  const eventId = `appointment:${input.appointmentId}:payment:${input.method}:${input.paymentKind}`
  dispatch(() => {
    ga('add_payment_info', { currency: 'BRL', value: input.value, payment_type: input.method, payment_kind: input.paymentKind })
    meta('AddPaymentInfo', { currency: 'BRL', value: input.value, payment_method: input.method }, eventId)
  })
}

export function trackAppointmentConfirmed(input: {
  appointmentId: string
  publicCode: string
  serviceName: string
  commercialValue: number
  paymentMethod: string
  cashCollected?: number
}): void {
  const purchaseId = `appointment:${input.appointmentId}:purchase`
  if (!once(purchaseId)) return
  dispatch(() => {
    ga('purchase', {
      transaction_id: input.appointmentId,
      currency: 'BRL', value: input.commercialValue,
      payment_type: input.paymentMethod,
      cash_collected: input.cashCollected ?? 0,
      items: [{ item_id: input.appointmentId, item_name: input.serviceName, price: input.commercialValue, quantity: 1 }],
    } as unknown as TrackingParams)
    meta('Schedule', { content_name: input.serviceName, currency: 'BRL', value: input.commercialValue }, `appointment:${input.appointmentId}:schedule`)
    meta('Purchase', { content_name: input.serviceName, currency: 'BRL', value: input.commercialValue }, purchaseId)
  })
}

export function trackDemandLead(input: { brand: string; serviceId: string; campaign: string | null }): void {
  const eventId = `lead:${input.brand}:${input.serviceId}:${crypto.randomUUID()}`
  dispatch(() => {
    ga('generate_lead', { bs_brand: input.brand, service_id: input.serviceId, campaign: input.campaign ?? undefined })
    meta('Lead', { content_category: input.brand, content_name: input.serviceId }, eventId)
  })
}

declare global {
  interface Window {
    dataLayer?: unknown[][]
    gtag?: (...args: unknown[]) => void
    fbq?: ((...args: unknown[]) => void) & {
      queue?: unknown[][]
      callMethod?: (...args: unknown[]) => void
      loaded?: boolean
      version?: string
    }
  }
}
