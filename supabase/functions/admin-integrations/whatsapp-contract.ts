export type WhatsAppIntegrationRow = {
  status?: unknown
  updated_at?: unknown
  embedded_signup_completed_at?: unknown
  [key: string]: unknown
}

export type WhatsAppIntegrationSummary = {
  key: "whatsapp"
  label: "WhatsApp"
  status: "CONNECTED" | "PENDING" | "BACKEND_ONLY"
  last_sync_at: string | null
  detail: {
    tenant_bound: boolean
    signup_available: false
    connection_ready: boolean
  }
}

function isoOrNull(value: unknown): string | null {
  if (typeof value !== "string" || Number.isNaN(Date.parse(value))) return null
  return value
}

/**
 * Browser-safe projection of the tenant's WhatsApp connection. Provider IDs,
 * credential state and raw provider errors intentionally never cross this API.
 */
export function summarizeWhatsAppIntegration(
  tenantBound: boolean,
  rows: WhatsAppIntegrationRow[],
): WhatsAppIntegrationSummary {
  const latest = [...rows]
    .sort((left, right) => Date.parse(String(right.updated_at ?? "")) - Date.parse(String(left.updated_at ?? "")))[0]
  const connected = latest?.status === "CONNECTED"
  const connectionReady = latest?.status === "PENDING_CONNECTION"

  return {
    key: "whatsapp",
    label: "WhatsApp",
    status: connected ? "CONNECTED" : connectionReady ? "BACKEND_ONLY" : "PENDING",
    last_sync_at: isoOrNull(latest?.embedded_signup_completed_at) ?? isoOrNull(latest?.updated_at),
    detail: {
      tenant_bound: tenantBound,
      // The cross-project handoff is deliberately unavailable until its signed
      // gateway and explicit Dracma binding are deployed and verified.
      signup_available: false,
      connection_ready: connectionReady,
    },
  }
}
