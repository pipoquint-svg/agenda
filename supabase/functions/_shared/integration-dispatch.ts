declare const EdgeRuntime: {
  waitUntil(promise: Promise<unknown>): void
} | undefined

const IMMEDIATE_WORKER_TIMEOUT_MS = 60_000

function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

async function dispatchAppointmentIntegrationsNow(appointmentId: string, source: string): Promise<void> {
  if (!validUuid(appointmentId)) return

  const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '') ?? ''
  const internalSecret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
  if (!base || !internalSecret) {
    console.error('[OPERATION_ALERT] IMMEDIATE_INTEGRATION_RUNTIME_MISSING', { source })
    return
  }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), IMMEDIATE_WORKER_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/integration-worker`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': internalSecret,
      },
      body: JSON.stringify({
        priority_entity_type: 'APPOINTMENT',
        priority_entity_id: appointmentId,
        source,
      }),
      signal: controller.signal,
    })

    if (!response.ok) {
      console.error('[OPERATION_ALERT] IMMEDIATE_INTEGRATION_DISPATCH_FAILED', {
        source,
        status: response.status,
      })
    }
  } catch (error) {
    console.error('[OPERATION_ALERT] IMMEDIATE_INTEGRATION_DISPATCH_FAILED', {
      source,
      code: error instanceof DOMException && error.name === 'AbortError'
        ? 'IMMEDIATE_INTEGRATION_TIMEOUT'
        : error instanceof Error
          ? error.message.split(':')[0]
          : 'UNKNOWN',
    })
  } finally {
    clearTimeout(timer)
  }
}

export function scheduleImmediateAppointmentIntegrations(appointmentId: string, source: string): void {
  if (!validUuid(appointmentId)) return
  const task = dispatchAppointmentIntegrationsNow(appointmentId, source)

  try {
    if (typeof EdgeRuntime !== 'undefined' && typeof EdgeRuntime.waitUntil === 'function') {
      EdgeRuntime.waitUntil(task)
      return
    }
  } catch {
    // Local/unit runtimes may not expose EdgeRuntime. Fire-and-forget still keeps
    // the production path non-blocking, while the durable outbox remains fallback.
  }

  void task
}
