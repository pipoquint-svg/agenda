import { adminClient } from "./supabase.ts";
import {
  type AgendaMessagingOperation,
  DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
  signAgendaMessagingHandoff,
} from "./dracma-messaging-handoff.ts";

export type AgendaTenant = { id: string; name: string };

/** The admin's single active tenant; never guessed when there are several. */
export async function tenantForAdmin(
  authUserId: string,
): Promise<AgendaTenant | null> {
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
  const { data: tenant, error: tenantError } = await adminClient()
    .from("tenants")
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

function env(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`CONFIG_${name}_MISSING`);
  return value;
}

/**
 * Calls the Dracma messaging gateway with a short-lived signed handoff.
 * Returns Dracma's JSON body; a non-2xx answer throws its error code.
 */
export async function callDracmaGateway(input: {
  operation: AgendaMessagingOperation;
  tenant: AgendaTenant;
  adminId: string;
  payload?: unknown;
  timeoutMs?: number;
}): Promise<Record<string, unknown>> {
  const handoff = {
    contract:
      DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT as typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
    request_id: crypto.randomUUID(),
    agenda_tenant_id: input.tenant.id,
    agenda_admin_id: input.adminId,
    agenda_tenant_name: input.tenant.name,
    operation: input.operation,
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
    body: JSON.stringify({ handoff, payload: input.payload }),
    signal: AbortSignal.timeout(input.timeoutMs ?? 20_000),
  });
  const body = await response.json().catch(() => null) as
    | Record<string, unknown>
    | null;
  if (!response.ok) {
    const code = (body?.error as { code?: unknown } | undefined)?.code;
    throw new Error(
      typeof code === "string" && /^[A-Z][A-Z0-9_]{2,95}$/.test(code)
        ? code
        : "DRACMA_MESSAGING_GATEWAY_UNAVAILABLE",
    );
  }
  if (!body || typeof body !== "object") {
    throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
  }
  return body;
}
