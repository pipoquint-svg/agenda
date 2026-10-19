export const DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT =
  "DRACMA_AGENDA_MESSAGING_HANDOFF_V1";

export type AgendaMessagingOperation =
  | "PROVISION"
  | "STATUS"
  | "START_SESSION"
  | "COMPLETE_SESSION"
  | "CANCEL_SESSION"
  | "CONNECT_OWNED_NUMBER";

export type AgendaMessagingHandoff = {
  contract: typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT;
  request_id: string;
  agenda_tenant_id: string;
  agenda_admin_id: string;
  agenda_tenant_name: string;
  operation: AgendaMessagingOperation;
  issued_at: string;
  expires_at: string;
};

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const OPERATIONS = new Set<AgendaMessagingOperation>([
  "PROVISION",
  "STATUS",
  "START_SESSION",
  "COMPLETE_SESSION",
  "CANCEL_SESSION",
  "CONNECT_OWNED_NUMBER",
]);

function uuid(value: string, code: string) {
  if (!UUID.test(value)) throw new Error(code);
  return value.toLowerCase();
}

function canonical(value: AgendaMessagingHandoff) {
  return [
    value.contract,
    uuid(value.request_id, "AGENDA_MESSAGING_REQUEST_ID_INVALID"),
    uuid(value.agenda_tenant_id, "AGENDA_MESSAGING_TENANT_ID_INVALID"),
    uuid(value.agenda_admin_id, "AGENDA_MESSAGING_ADMIN_ID_INVALID"),
    tenantName(value.agenda_tenant_name),
    value.operation,
    value.issued_at,
    value.expires_at,
  ].join("\n");
}

function tenantName(value: string) {
  const text = value.trim();
  if (!text || text.length > 160) {
    throw new Error("AGENDA_MESSAGING_TENANT_NAME_INVALID");
  }
  return text;
}

async function hmac(secret: string, content: string) {
  if (new TextEncoder().encode(secret).byteLength < 32) {
    throw new Error("AGENDA_MESSAGING_SHARED_SECRET_WEAK");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(content)),
  );
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export async function signAgendaMessagingHandoff(
  secret: string,
  handoff: AgendaMessagingHandoff,
) {
  if (
    handoff.contract !== DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT ||
    !OPERATIONS.has(handoff.operation)
  ) {
    throw new Error("AGENDA_MESSAGING_HANDOFF_INVALID");
  }
  const issuedAt = Date.parse(handoff.issued_at);
  const expiresAt = Date.parse(handoff.expires_at);
  if (
    !Number.isFinite(issuedAt) || !Number.isFinite(expiresAt) ||
    expiresAt <= issuedAt || expiresAt - issuedAt > 120_000
  ) {
    throw new Error("AGENDA_MESSAGING_HANDOFF_TTL_INVALID");
  }
  return hmac(secret, canonical(handoff));
}
