import { adminClient, requireAdminPermission } from "../_shared/supabase.ts"
import { DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT, signAgendaMessagingHandoff } from "../_shared/dracma-messaging-handoff.ts"

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "content-type, authorization, apikey, x-client-info",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-max-age": "7200",
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } })
}

function env(name: string) {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`CONFIG_${name}_MISSING`)
  return value
}

function safeCode(error: unknown) {
  const code = error instanceof Error ? error.message : "DRACMA_MESSAGING_STATUS_FAILED"
  return /^[A-Z][A-Z0-9_]{2,95}$/.test(code) ? code : "DRACMA_MESSAGING_STATUS_FAILED"
}

async function tenantForAdmin(authUserId: string) {
  const { data, error } = await adminClient().from("tenant_members")
    .select("tenant_id")
    .eq("user_id", authUserId)
    .eq("status", "ACTIVE")
    .limit(2)
  if (error) throw new Error("DRACMA_MESSAGING_TENANT_LOOKUP_FAILED")
  return data?.length === 1 && typeof data[0]?.tenant_id === "string" ? data[0].tenant_id : null
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== "GET" && req.method !== "POST") return json({ error: { code: "METHOD_NOT_ALLOWED" } }, 405)
  try {
    const actor = await requireAdminPermission(req, req.method === "POST" ? "INTEGRATIONS_MANAGE" : "INTEGRATIONS_VIEW")
    const tenantId = await tenantForAdmin(actor.authUserId)
    if (!tenantId) return json({ status: "SETUP_REQUIRED", signup_available: false })

    const handoff = {
      contract: DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT as typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
      request_id: crypto.randomUUID(),
      agenda_tenant_id: tenantId,
      agenda_admin_id: actor.adminId,
      operation: req.method === "POST" ? "START_SESSION" as const : "STATUS" as const,
      issued_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 60_000).toISOString(),
    }
    const signature = await signAgendaMessagingHandoff(env("DRACMA_MESSAGING_HANDOFF_SECRET"), handoff)
    const response = await fetch(env("DRACMA_MESSAGING_GATEWAY_URL"), {
      method: "POST",
      headers: { "content-type": "application/json", "x-agenda-messaging-signature": signature },
      body: JSON.stringify({ handoff }),
      signal: AbortSignal.timeout(8_000),
    })
    if (!response.ok) throw new Error("DRACMA_MESSAGING_GATEWAY_UNAVAILABLE")
    const payload = await response.json().catch(() => null) as { status?: unknown; signup_available?: unknown } | null
    if (req.method === "GET") {
      if (payload?.status !== "READY" || payload.signup_available !== false) throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID")
      return json({ status: "READY", signup_available: false })
    }
    const started = payload?.status === "STARTED" && typeof (payload as Record<string, unknown>).session_id === "string"
      && typeof (payload as Record<string, unknown>).expires_at === "string"
      && typeof (payload as Record<string, unknown>).app_id === "string"
      && typeof (payload as Record<string, unknown>).configuration_id === "string"
    if (!started) throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID")
    return json(payload)
  } catch (error) {
    const code = safeCode(error)
    if (code.startsWith("CONFIG_")) return json({ status: "SETUP_REQUIRED", signup_available: false })
    const status = code === "ADMIN_PERMISSION_DENIED" ? 403
      : code.startsWith("ADMIN_") ? 401 : 502
    return json({ error: { code } }, status)
  }
})
