import {
  adminClient,
  hasAdminPermission,
  requireAdmin,
} from "../_shared/supabase.ts";
import { recurrenceOption } from "./recurrence.ts";

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
function text(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}
function uuid(value: unknown, code: string) {
  const result = text(value);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(result)
  ) throw new Error(code);
  return result;
}
function positiveInteger(value: unknown, code: string) {
  const result = Number(value);
  if (!Number.isInteger(result) || result < 1 || result > 3650) {
    throw new Error(code);
  }
  return result;
}
function discount(value: unknown, type: string) {
  const result = Number(value);
  if (
    !Number.isFinite(result) || result <= 0 ||
    (type === "PERCENT" && result > 100)
  ) throw new Error("MARKETING_CAMPAIGN_DISCOUNT_INVALID");
  return result;
}
async function tenantForAdmin(authUserId: string) {
  const client = adminClient();
  const { data, error } = await client.from("tenant_members").select(
    "tenant_id",
  ).eq("user_id", authUserId).eq("status", "ACTIVE").limit(2);
  if (error) throw new Error("MARKETING_CAMPAIGN_TENANT_LOOKUP_FAILED");
  if (data?.length !== 1 || typeof data[0]?.tenant_id !== "string") {
    throw new Error("MARKETING_CAMPAIGN_TENANT_REQUIRED");
  }
  return data[0].tenant_id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (!["GET", "POST"].includes(req.method)) {
    return json({ error: { code: "METHOD_NOT_ALLOWED" } }, 405);
  }
  try {
    const admin = await requireAdmin(req);
    if (!(await hasAdminPermission(admin.adminId, "SERVICES_MANAGE"))) {
      throw new Error("ADMIN_PERMISSION_DENIED");
    }
    const client = adminClient();
    const tenantId = await tenantForAdmin(admin.authUserId);
    if (req.method === "GET") {
      const [campaigns, versions, services] = await Promise.all([
        client.from("marketing_campaigns").select(
          "id,campaign_key,internal_name,public_name,description,state,starts_at,ends_at,active_version_id,created_at,updated_at",
        ).eq("tenant_id", tenantId).order("created_at", { ascending: false }),
        client.from("marketing_campaign_versions").select(
          "id,campaign_id,version_number,publication_status,discount_type,discount_value,validity_basis,validity_days,recurring_after_discounted_rental,eligibility_rules,created_at,published_at",
        ).eq("tenant_id", tenantId).order("version_number", {
          ascending: false,
        }),
        client.from("services").select("id,name,slug").eq(
          "operation_scope",
          "BLACKSHEEP",
        ).eq("is_active", true).order("name"),
      ]);
      if (campaigns.error || versions.error || services.error) {
        throw new Error("MARKETING_CAMPAIGN_READ_FAILED");
      }
      return json({
        campaigns: campaigns.data ?? [],
        versions: versions.data ?? [],
        services: services.data ?? [],
        capabilities: { recurring_after_discounted_rental: true },
        delivery: {
          status: "FROZEN",
          channel: "WHATSAPP",
          reason: "S6_DRACMA_POLICY_CONTRACT_PENDING",
        },
      });
    }
    const body = await req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error("MARKETING_CAMPAIGN_PAYLOAD_INVALID");
    }
    const action = text((body as Record<string, unknown>).action).toUpperCase();
    const requestId = uuid(
      (body as Record<string, unknown>).request_id,
      "MARKETING_CAMPAIGN_REQUEST_ID_INVALID",
    );
    if (action === "CREATE") {
      const discountType = text((body as Record<string, unknown>).discount_type)
        .toUpperCase();
      if (!["PERCENT", "FIXED"].includes(discountType)) {
        throw new Error("MARKETING_CAMPAIGN_DISCOUNT_TYPE_INVALID");
      }
      const serviceIds = (body as Record<string, unknown>).service_ids;
      if (!Array.isArray(serviceIds) || serviceIds.length === 0) {
        throw new Error("MARKETING_CAMPAIGN_TARGET_SERVICES_REQUIRED");
      }
      const offer = {
        trigger_kind: "RENTAL_COMPLETED_FINANCIALLY_CLEARED",
        discount_type: discountType,
        discount_value: discount(
          (body as Record<string, unknown>).discount_value,
          discountType,
        ),
        discount_scope: "SERVICE_ONLY",
        validity_basis: text((body as Record<string, unknown>).validity_basis)
          .toUpperCase(),
        validity_days: positiveInteger(
          (body as Record<string, unknown>).validity_days,
          "MARKETING_CAMPAIGN_VALIDITY_INVALID",
        ),
        max_uses: 1,
        max_uses_per_customer: 1,
        applies_to_extras: false,
        applies_to_hour_packages: false,
        stacking_policy: "EXCLUSIVE",
        recurring_after_discounted_rental: recurrenceOption(
          (body as Record<string, unknown>).recurring_after_discounted_rental,
        ),
        eligibility_rules: {
          service_ids: serviceIds.map((id) =>
            uuid(id, "MARKETING_CAMPAIGN_TARGET_SERVICE_INVALID")
          ),
        },
        trigger_rules: {},
        message_rules: {},
      };
      if (
        !["BOOKING_CONFIRMATION", "RENTAL_START"].includes(
          String(offer.validity_basis),
        )
      ) throw new Error("MARKETING_CAMPAIGN_VALIDITY_BASIS_INVALID");
      const { data, error } = await client.rpc(
        "service_admin_create_marketing_campaign",
        {
          p_tenant_id: tenantId,
          p_campaign_key: text((body as Record<string, unknown>).campaign_key),
          p_internal_name: text(
            (body as Record<string, unknown>).internal_name,
          ),
          p_public_name: text((body as Record<string, unknown>).public_name) ||
            null,
          p_description: text((body as Record<string, unknown>).description) ||
            null,
          p_offer: offer,
          p_admin_id: admin.adminId,
          p_request_id: requestId,
        },
      );
      if (error) throw new Error(error.message);
      return json(data, 201);
    }
    if (action === "TRANSITION") {
      const state = text((body as Record<string, unknown>).state).toUpperCase();
      if (!["ACTIVE", "PAUSED", "ENDED", "ARCHIVED"].includes(state)) {
        throw new Error("MARKETING_CAMPAIGN_STATE_INVALID");
      }
      const campaignId = uuid(
        (body as Record<string, unknown>).campaign_id,
        "MARKETING_CAMPAIGN_ID_INVALID",
      );
      const { data: campaign, error: campaignError } = await client.from(
        "marketing_campaigns",
      ).select("id").eq("id", campaignId).eq("tenant_id", tenantId)
        .maybeSingle();
      if (campaignError) throw new Error("MARKETING_CAMPAIGN_READ_FAILED");
      if (!campaign) throw new Error("MARKETING_CAMPAIGN_NOT_FOUND");
      const { data, error } = await client.rpc(
        "service_admin_transition_marketing_campaign",
        {
          p_campaign_id: campaignId,
          p_state: state,
          p_publish_version_id: state === "ACTIVE"
            ? uuid(
              (body as Record<string, unknown>).publish_version_id,
              "MARKETING_CAMPAIGN_VERSION_ID_INVALID",
            )
            : null,
          p_reason: text((body as Record<string, unknown>).reason) || null,
          p_admin_id: admin.adminId,
          p_request_id: requestId,
        },
      );
      if (error) throw new Error(error.message);
      return json(data);
    }
    throw new Error("MARKETING_CAMPAIGN_ACTION_INVALID");
  } catch (error) {
    const code = error instanceof Error
      ? error.message.split(":")[0]
      : "MARKETING_CAMPAIGN_ADMIN_FAILED";
    const status =
      code.startsWith("ADMIN_AUTH_") || code === "ADMIN_ACCESS_DENIED"
        ? 401
        : code === "ADMIN_PERMISSION_DENIED"
        ? 403
        : 400;
    return json({ error: { code } }, status);
  }
});
