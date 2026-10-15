import { adminClient, requireAdminPermission } from "../_shared/supabase.ts";
import {
  DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
  signAgendaMessagingHandoff,
} from "../_shared/dracma-messaging-handoff.ts";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "content-type, authorization, apikey, x-client-info",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-max-age": "7200",
};

type SignupOperation = "START_SESSION" | "COMPLETE_SESSION" | "CANCEL_SESSION";

function operationFor(req: Request, body: unknown): SignupOperation {
  if (req.method !== "POST") return "START_SESSION";
  const requested = body && typeof body === "object" && !Array.isArray(body)
    ? String((body as Record<string, unknown>).operation ?? "START_SESSION")
      .trim().toUpperCase()
    : "START_SESSION";
  if (
    requested === "START_SESSION" || requested === "COMPLETE_SESSION" ||
    requested === "CANCEL_SESSION"
  ) {
    return requested;
  }
  throw new Error("DRACMA_MESSAGING_OPERATION_INVALID");
}

function clientPayload(operation: SignupOperation, body: unknown) {
  if (operation === "START_SESSION") return undefined;
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("DRACMA_MESSAGING_PAYLOAD_INVALID");
  }
  const payload = (body as Record<string, unknown>).payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("DRACMA_MESSAGING_PAYLOAD_INVALID");
  }
  return payload;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function env(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`CONFIG_${name}_MISSING`);
  return value;
}

function safeCode(error: unknown) {
  const code = error instanceof Error
    ? error.message
    : "DRACMA_MESSAGING_STATUS_FAILED";
  return /^[A-Z][A-Z0-9_]{2,95}$/.test(code)
    ? code
    : "DRACMA_MESSAGING_STATUS_FAILED";
}

async function tenantForAdmin(authUserId: string) {
  const { data, error } = await adminClient().from("tenant_members")
    .select("tenant_id")
    .eq("user_id", authUserId)
    .eq("status", "ACTIVE")
    .limit(2);
  if (error) throw new Error("DRACMA_MESSAGING_TENANT_LOOKUP_FAILED");
  return data?.length === 1 && typeof data[0]?.tenant_id === "string"
    ? data[0].tenant_id
    : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "GET" && req.method !== "POST") {
    return json({ error: { code: "METHOD_NOT_ALLOWED" } }, 405);
  }
  try {
    const requestBody = req.method === "POST"
      ? await req.json().catch(() => ({}))
      : undefined;
    const operation = operationFor(req, requestBody);
    const actor = await requireAdminPermission(
      req,
      req.method === "POST" ? "INTEGRATIONS_MANAGE" : "INTEGRATIONS_VIEW",
    );
    const tenantId = await tenantForAdmin(actor.authUserId);
    if (!tenantId) {
      return json({ status: "SETUP_REQUIRED", signup_available: false });
    }

    const handoff = {
      contract:
        DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT as typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
      request_id: crypto.randomUUID(),
      agenda_tenant_id: tenantId,
      agenda_admin_id: actor.adminId,
      operation: req.method === "POST" ? operation : "STATUS" as const,
      issued_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 60_000).toISOString(),
    };
    const signature = await signAgendaMessagingHandoff(
      env("DRACMA_MESSAGING_HANDOFF_SECRET"),
      handoff,
    );
    const response = await fetch(env("DRACMA_MESSAGING_GATEWAY_URL"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-agenda-messaging-signature": signature,
      },
      body: JSON.stringify({
        handoff,
        payload: clientPayload(operation, requestBody),
      }),
      signal: AbortSignal.timeout(8_000),
    });
    const payload = await response.json().catch(() => null) as {
      status?: unknown;
      signup_available?: unknown;
      data?: unknown;
    } | null;
    if (req.method === "GET") {
      if (
        payload?.status !== "READY" ||
        typeof payload.signup_available !== "boolean"
      ) {
        throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
      }
      return json({
        status: "READY",
        signup_available: payload.signup_available,
      });
    }
    if (operation === "COMPLETE_SESSION" || operation === "CANCEL_SESSION") {
      const data = payload?.data;
      if (!response.ok) {
        return json(
          data ??
            { error: { code: "DRACMA_MESSAGING_GATEWAY_UNAVAILABLE" } },
          response.status,
        );
      }
      if (!data || typeof data !== "object") {
        throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
      }
      return json(data);
    }
    if (!response.ok) throw new Error("DRACMA_MESSAGING_GATEWAY_UNAVAILABLE");
    const started = payload?.status === "STARTED" &&
      typeof (payload as Record<string, unknown>).session_id === "string" &&
      typeof (payload as Record<string, unknown>).expires_at === "string" &&
      typeof (payload as Record<string, unknown>).app_id === "string" &&
      typeof (payload as Record<string, unknown>).configuration_id === "string";
    if (!started) throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
    return json(payload);
  } catch (error) {
    const code = safeCode(error);
    if (code.startsWith("CONFIG_")) {
      return json({ status: "SETUP_REQUIRED", signup_available: false });
    }
    const status = code === "ADMIN_PERMISSION_DENIED"
      ? 403
      : code.startsWith("ADMIN_")
      ? 401
      : 502;
    return json({ error: { code } }, status);
  }
});
