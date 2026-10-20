export type MessagingOperation =
  | "START_SESSION"
  | "COMPLETE_SESSION"
  | "CANCEL_SESSION"
  | "CONNECT_OWNED_NUMBER";

const OPERATIONS = new Set<MessagingOperation>([
  "START_SESSION",
  "COMPLETE_SESSION",
  "CANCEL_SESSION",
  "CONNECT_OWNED_NUMBER",
]);

export function operationFor(
  method: string,
  body: unknown,
): MessagingOperation {
  if (method !== "POST") return "START_SESSION";
  const requested = body && typeof body === "object" && !Array.isArray(body)
    ? String((body as Record<string, unknown>).operation ?? "START_SESSION")
      .trim().toUpperCase()
    : "START_SESSION";
  if (OPERATIONS.has(requested as MessagingOperation)) {
    return requested as MessagingOperation;
  }
  throw new Error("DRACMA_MESSAGING_OPERATION_INVALID");
}

/** Only the embedded-signup completion and cancellation carry a payload. */
export function clientPayload(operation: MessagingOperation, body: unknown) {
  if (operation === "START_SESSION" || operation === "CONNECT_OWNED_NUMBER") {
    return undefined;
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("DRACMA_MESSAGING_PAYLOAD_INVALID");
  }
  const payload = (body as Record<string, unknown>).payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("DRACMA_MESSAGING_PAYLOAD_INVALID");
  }
  return payload;
}

export type DracmaMessagingStatus = {
  status: "READY";
  signup_available: boolean;
  owned_number_available: boolean;
};

export function messagingStatus(payload: unknown): DracmaMessagingStatus {
  const data = payload && typeof payload === "object" && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : null;
  if (data?.status !== "READY" || typeof data.signup_available !== "boolean") {
    throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
  }
  return {
    status: "READY",
    signup_available: data.signup_available,
    owned_number_available: data.owned_number_available === true,
  };
}

export type OwnedNumberConnection = {
  waba_id: string;
  phone_number_id: string;
  display_name: string;
  masked_phone: string;
};

const PROVIDER_ID = /^[0-9]{5,40}$/;

/** Validates Dracma's server-to-server result before Agenda stores it. */
export function ownedNumberConnection(payload: unknown): OwnedNumberConnection {
  const data = payload && typeof payload === "object" && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : null;
  const wabaId = typeof data?.waba_id === "string" ? data.waba_id : "";
  const phoneNumberId = typeof data?.phone_number_id === "string"
    ? data.phone_number_id
    : "";
  const displayName = typeof data?.display_name === "string"
    ? data.display_name.trim()
    : "";
  const maskedPhone = typeof data?.masked_phone === "string"
    ? data.masked_phone.trim()
    : "";
  if (
    data?.status !== "CONNECTED" || !PROVIDER_ID.test(wabaId) ||
    !PROVIDER_ID.test(phoneNumberId) || !displayName ||
    displayName.length > 120 || !/^[*•]{3,}\s?[0-9]{2,4}$/.test(maskedPhone)
  ) {
    throw new Error("DRACMA_MESSAGING_GATEWAY_INVALID");
  }
  return {
    waba_id: wabaId,
    phone_number_id: phoneNumberId,
    display_name: displayName,
    masked_phone: maskedPhone,
  };
}

/** The browser learns only that the number is connected and how it is shown. */
export function ownedNumberBrowserResult(
  connection: OwnedNumberConnection,
  projected: boolean,
) {
  return {
    status: "CONNECTED" as const,
    display_name: connection.display_name,
    masked_phone: connection.masked_phone,
    projection: projected ? "SAVED" as const : "PENDING" as const,
  };
}
