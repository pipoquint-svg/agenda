import { adminClient, requireAdminPermission } from "../_shared/supabase.ts";
import {
  DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
  signAgendaMessagingHandoff,
} from "../_shared/dracma-messaging-handoff.ts";
import {
  clientPayload,
  messagingStatus,
  operationFor,
  ownedNumberBrowserResult,
  type OwnedNumberConnection,
  ownedNumberConnection,
} from "./contract.ts";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "content-type, authorization, apikey, x-client-info",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-max-age": "7200",
};

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

/**
 * Mirrors the connected owned number into Agenda's tenant read model so the
 * Integrations screen can report it. Failure here never undoes the Dracma
 * connection; the caller reports the projection as pending.
 */
async function projectOwnedNumber(
  tenantId: string,
  connection: OwnedNumberConnection,
) {
  const client = adminClient();
  const now = new Date().toISOString();
  const { data: existing, error: readError } = await client
    .from("whatsapp_tenant_integrations")
    .select("id")
    .eq("tenant_id", tenantId)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (readError) throw new Error("WHATSAPP_PROJECTION_FAILED");
  const fields = {
    waba_id: connection.waba_id,
    status: "CONNECTED",
    embedded_signup_completed_at: now,
    last_provider_error_code: null,
    last_provider_error_at: null,
    updated_at: now,
  };
  const integration = existing?.id
    ? await client.from("whatsapp_tenant_integrations").update(fields)
      .eq("id", existing.id).eq("tenant_id", tenantId).select("id").single()
    : await client.from("whatsapp_tenant_integrations")
      .insert({ tenant_id: tenantId, ...fields }).select("id").single();
  if (integration.error || !integration.data?.id) {
    throw new Error("WHATSAPP_PROJECTION_FAILED");
  }
  const phoneFields = {
    integration_id: integration.data.id,
    phone_number_id: connection.phone_number_id,
    display_phone_number: connection.masked_phone,
    status: "CONNECTED",
    updated_at: now,
  };
  const { data: phone, error: phoneReadError } = await client
    .from("whatsapp_tenant_phone_numbers")
    .select("id,integration_id")
    .eq("phone_number_id", connection.phone_number_id)
    .maybeSingle();
  if (
    phoneReadError || (phone && phone.integration_id !== integration.data.id)
  ) {
    throw new Error("WHATSAPP_PROJECTION_FAILED");
  }
  const saved = phone?.id
    ? await client.from("whatsapp_tenant_phone_numbers").update(phoneFields)
      .eq("id", phone.id)
    : await client.from("whatsapp_tenant_phone_numbers").insert(phoneFields);
  if (saved.error) throw new Error("WHATSAPP_PROJECTION_FAILED");
}

async function tenantForAdmin(authUserId: string) {
  const { data, error } = await adminClient().from("tenant_members")
    .select("tenant_id")
    .eq("user_id", authUserId)
    .eq("status", "ACTIVE")
    .limit(2);
  if (error) throw new Error("DRACMA_MESSAGING_TENANT_LOOKUP_FAILED");
  const tenantId = data?.length === 1 && typeof data[0]?.tenant_id === "string"
    ? data[0].tenant_id
    : null;
  if (!tenantId) return null;
  const { data: tenant, error: tenantError } = await adminClient().from(
    "tenants",
  )
    .select("id,name")
    .eq("id", tenantId)
    .eq("status", "ACTIVE")
    .maybeSingle();
  if (tenantError) throw new Error("DRACMA_MESSAGING_TENANT_LOOKUP_FAILED");
  return tenant && typeof tenant.id === "string" &&
      typeof tenant.name === "string" && tenant.name.trim()
    ? { id: tenant.id, name: tenant.name.trim() }
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
    const operation = operationFor(req.method, requestBody);
    const actor = await requireAdminPermission(
      req,
      "INTEGRATIONS_MANAGE",
    );
    const tenantId = await tenantForAdmin(actor.authUserId);
    if (!tenantId) {
      return json({
        status: "SETUP_REQUIRED",
        signup_available: false,
        owned_number_available: false,
      });
    }

    const handoff = {
      contract:
        DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT as typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
      request_id: crypto.randomUUID(),
      agenda_tenant_id: tenantId.id,
      agenda_admin_id: actor.adminId,
      agenda_tenant_name: tenantId.name,
      // The GET read-model establishes only Dracma's technical projection.
      // It never opens Meta or grants Messaging entitlement/capabilities.
      operation: req.method === "POST" ? operation : "PROVISION" as const,
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
      // Connecting an owned number makes several Meta and runtime calls.
      signal: AbortSignal.timeout(
        operation === "CONNECT_OWNED_NUMBER" && req.method === "POST"
          ? 45_000
          : 8_000,
      ),
    });
    const payload = await response.json().catch(() => null) as {
      status?: unknown;
      signup_available?: unknown;
      data?: unknown;
    } | null;
    if (req.method === "GET") return json(messagingStatus(payload));
    if (operation === "CONNECT_OWNED_NUMBER") {
      if (!response.ok) {
        const code = (payload as { error?: { code?: unknown } } | null)?.error
          ?.code;
        return json({
          error: {
            code:
              typeof code === "string" && /^[A-Z][A-Z0-9_]{2,95}$/.test(code)
                ? code
                : "DRACMA_MESSAGING_GATEWAY_UNAVAILABLE",
          },
        }, response.status >= 400 && response.status < 500 ? 409 : 502);
      }
      const connection = ownedNumberConnection(payload);
      let projected = true;
      try {
        await projectOwnedNumber(tenantId.id, connection);
      } catch {
        projected = false;
        console.error("admin-dracma-messaging", "WHATSAPP_PROJECTION_FAILED");
      }
      return json(ownedNumberBrowserResult(connection, projected));
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
      return json({
        status: "SETUP_REQUIRED",
        signup_available: false,
        owned_number_available: false,
      });
    }
    const status = code === "ADMIN_PERMISSION_DENIED"
      ? 403
      : code.startsWith("ADMIN_")
      ? 401
      : 502;
    return json({ error: { code } }, status);
  }
});
