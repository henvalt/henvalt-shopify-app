const SHOPIFY_API_VERSION = "2026-10";
const CLAIM_RPC = "control_plane_claim_billing_usage";
const TOKEN_RPC = "get_shopify_access_token_for_control_plane";
const EGRESS_AUTH_RPC = "control_plane_authorize_billing_usage_egress";
const RESULT_RPC = "control_plane_record_billing_usage_result";

const BILLING_MUTATION = `mutation HenvaltCreateUsageRecord(
  $description: String!,
  $price: MoneyInput!,
  $subscriptionLineItemId: ID!,
  $idempotencyKey: String
) {
  appUsageRecordCreate(
    description: $description,
    price: $price,
    subscriptionLineItemId: $subscriptionLineItemId,
    idempotencyKey: $idempotencyKey
  ) {
    appUsageRecord { id }
    userErrors { field message code }
  }
}`;

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function safeEqual(a, b) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function validShop(value) {
  return typeof value === "string" &&
    /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(value.trim().toLowerCase());
}

function validMoney(value) {
  const amount = String(value ?? "");
  return /^(?:0|[1-9]\d{0,13})(?:\.\d{1,4})?$/.test(amount) && Number(amount) > 0;
}

function ambiguous(reason, attempt) {
  return json(202, {
    claimed: true,
    state: "PENDING",
    retryable: Number(attempt) < 5,
    requiresOperatorReview: Number(attempt) >= 5,
    reason,
  });
}

export function createShopifyUsageBillingHandler({
  env,
  fetchImpl = fetch,
  logger = console,
}) {
  async function rpc(name, args) {
    const url = env.SUPABASE_URL;
    const key = env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) throw new Error("DATABASE_NOT_CONFIGURED");
    const response = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      redirect: "error",
      headers: {
        apikey: key,
        authorization: `Bearer ${key}`,
        "content-type": "application/json",
        "accept-profile": "henvalt",
        "content-profile": "henvalt",
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(10000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`DATABASE_RPC_${response.status}`);
    return text ? JSON.parse(text) : null;
  }

  async function ambiguousOutcome(shop, chargeId, reason, attempt) {
    if (Number(attempt) < 5) return ambiguous(reason, attempt);
    try {
      const recorded = await rpc("control_plane_mark_billing_reconciliation_required", {
        p_shop_domain: shop,
        p_charge_id: chargeId,
        p_reason: reason,
      });
      if (recorded?.updated !== true || recorded?.status !== "REQUIRED") {
        throw new Error("BILLING_RECONCILIATION_STATE_NOT_RECORDED");
      }
      return json(202, {
        claimed: true,
        state: "PENDING",
        retryable: false,
        requiresOperatorReview: true,
        reconciliationStatus: "REQUIRED",
        reason,
      });
    } catch (error) {
      logger.error("Exhausted billing outcome could not be persisted for reconciliation", error instanceof Error ? error.message : "unknown");
      return json(503, {
        claimed: true,
        state: "PENDING",
        retryable: false,
        requiresOperatorReview: true,
        reconciliationPersisted: false,
        reason: "RECONCILIATION_STATE_PERSIST_FAILED",
      });
    }
  }

  async function exhaustedDeterministicFailure(shop, chargeId, attempt) {
    if (Number(attempt) < 5) return null;
    try {
      const recorded = await rpc("control_plane_mark_billing_reconciliation_required", {
        p_shop_domain: shop,
        p_charge_id: chargeId,
        p_reason: "SHOPIFY_USAGE_DETERMINISTIC_REJECTION",
      });
      if (recorded?.updated !== true || recorded?.status !== "REQUIRED") {
        throw new Error("BILLING_RECONCILIATION_STATE_NOT_RECORDED");
      }
      return json(202, {
        claimed: true,
        state: "FAILED",
        retryable: false,
        requiresOperatorReview: true,
        reconciliationStatus: "REQUIRED",
        reason: "SHOPIFY_USAGE_DETERMINISTIC_REJECTION",
      });
    } catch (error) {
      logger.error("Exhausted deterministic billing rejection could not be persisted for reconciliation", error instanceof Error ? error.message : "unknown");
      return json(503, {
        claimed: true,
        state: "FAILED",
        retryable: false,
        requiresOperatorReview: true,
        reconciliationPersisted: false,
        reason: "RECONCILIATION_STATE_PERSIST_FAILED",
      });
    }
  }

  async function recordResult(shop, chargeId, success, providerId, errorCode, errorMessage) {
    return await rpc(RESULT_RPC, {
      p_shop_domain: shop,
      p_charge_id: chargeId,
      p_success: success,
      p_provider_usage_record_id: providerId,
      p_error_code: errorCode,
      p_error_message: errorMessage,
    });
  }

  return async function handle(req) {
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
    const expected = env.HENVALT_BILLING_WORKER_TOKEN ?? "";
    const authorization = req.headers.get("authorization") ?? "";
    const supplied = authorization.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? "";
    if (!expected || !supplied || !safeEqual(supplied, expected)) {
      return json(401, { error: "unauthorized" });
    }

    let body;
    try {
      const raw = await req.text();
      if (raw.length > 2048) return json(413, { error: "body_too_large" });
      body = JSON.parse(raw || "{}");
    } catch {
      return json(400, { error: "invalid_json" });
    }
    const shop = validShop(body?.shop) ? body.shop.trim().toLowerCase() : "";
    if (!shop) return json(400, { error: "valid_shop_required" });

    // Shopify app-usage creation is a separate external egress boundary from email delivery.
    // Default-deny it unless an operator explicitly enables billing submission.
    if (env.HENVALT_SHOPIFY_BILLING_EGRESS_ENABLED !== "true") {
      return json(409, { error: "billing_egress_disabled", retryable: false });
    }

    if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
      return json(503, { error: "billing_worker_not_configured" });
    }

    let claim;
    try {
      claim = await rpc(CLAIM_RPC, { p_shop_domain: shop });
    } catch (error) {
      logger.error("Billing usage claim failed", error instanceof Error ? error.message : "unknown");
      return json(503, { error: "billing_claim_unavailable", retryable: true });
    }
    if (claim?.available !== true) {
      return json(200, {
        claimed: false,
        reason: typeof claim?.reason === "string" ? claim.reason : "NO_PENDING_USAGE_CHARGE",
      });
    }

    // Fail closed if the database does not explicitly attest that this is a test subscription.
    // This protects against accidentally deploying the candidate worker against an older/live schema.
    if (claim.testMode !== true) {
      logger.error("Billing worker refused a non-test or unverified subscription claim");
      return json(409, { error: "test_mode_required", retryable: false });
    }

    const chargeId = typeof claim.chargeId === "string" ? claim.chargeId : "";
    const lineItem = typeof claim.subscriptionLineItemId === "string" ? claim.subscriptionLineItemId : "";
    const idempotencyKey = typeof claim.idempotencyKey === "string" ? claim.idempotencyKey : "";
    const currency = typeof claim.currency === "string" ? claim.currency.trim().toUpperCase() : "";
    const amount = claim.amount;
    const attempt = Number(claim.attempt);
    if (!Number.isInteger(attempt) || attempt < 1 || attempt > 5 || !/^[0-9a-f-]{36}$/i.test(chargeId) ||
        !/^gid:\/\/shopify\/AppSubscriptionLineItem\/[A-Za-z0-9?=&_-]+$/.test(lineItem) ||
        !idempotencyKey || idempotencyKey.length > 255 ||
        !/^[A-Z]{3}$/.test(currency) || !validMoney(amount)) {
      logger.error("Billing claim returned an invalid charge envelope");
      return json(503, { error: "invalid_billing_claim", retryable: false });
    }

    let accessToken;
    try {
      const tokenResult = await rpc(TOKEN_RPC, { p_shop_domain: shop });
      accessToken = typeof tokenResult === "string"
        ? tokenResult
        : (typeof tokenResult?.access_token === "string" ? tokenResult.access_token : "");
    } catch (error) {
      logger.error("Billing worker could not obtain Shopify token", error instanceof Error ? error.message : "unknown");
      return json(503, { error: "shopify_token_unavailable", retryable: true });
    }
    if (accessToken.length < 20) return json(503, { error: "shopify_token_unavailable", retryable: true });

    // Recheck subscription, shop, line item and attempt after token retrieval and
    // immediately before external egress. A stale/cancelled claim never reaches Shopify.
    let egressAuthorization;
    try {
      egressAuthorization = await rpc(EGRESS_AUTH_RPC, {
        p_shop_domain: shop,
        p_charge_id: chargeId,
        p_idempotency_key: idempotencyKey,
        p_subscription_line_item_id: lineItem,
        p_amount: String(amount),
        p_currency: currency,
        p_attempt: attempt,
      });
    } catch (error) {
      logger.error("Billing egress authorization failed", error instanceof Error ? error.message : "unknown");
      return json(503, { error: "billing_egress_authorization_unavailable", retryable: true });
    }
    if (egressAuthorization?.authorized !== true) {
      return json(409, {
        claimed: true,
        state: "PENDING",
        retryable: false,
        reason: typeof egressAuthorization?.reason === "string"
          ? egressAuthorization.reason
          : "BILLING_EGRESS_NOT_AUTHORIZED",
      });
    }

    let upstream;
    try {
      upstream = await fetchImpl(`https://${shop}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`, {
        method: "POST",
        redirect: "error",
        headers: {
          "content-type": "application/json",
          "accept": "application/json",
          "x-shopify-access-token": accessToken,
        },
        body: JSON.stringify({
          query: BILLING_MUTATION,
          variables: {
            description: "HENVALT confirmed recovered revenue",
            price: { amount: String(amount), currencyCode: currency },
            subscriptionLineItemId: lineItem,
            idempotencyKey,
          },
        }),
        signal: AbortSignal.timeout(15000),
      });
    } catch (error) {
      // The provider may have accepted the charge before the connection failed.
      // Keep the durable charge PENDING and retry with the same Shopify idempotency key.
      logger.error("Shopify usage outcome is ambiguous", error instanceof Error ? error.message : "unknown");
      return await ambiguousOutcome(shop, chargeId, "SHOPIFY_TRANSPORT_OUTCOME_UNKNOWN", attempt);
    }

    // A timeout or early-data retry response can arrive after the upstream has begun processing.
    // Treat these statuses as ambiguous; only explicit non-transient 4xx rejections are deterministic.
    if (upstream.status === 408 || upstream.status === 425 || upstream.status === 429 || upstream.status >= 500) {
      return await ambiguousOutcome(shop, chargeId, "SHOPIFY_TRANSIENT_HTTP", attempt);
    }
    if (!upstream.ok) {
      try {
        const recorded = await recordResult(shop, chargeId, false, null, "SHOPIFY_HTTP_" + upstream.status, "Shopify rejected the usage request");
        if (recorded?.updated !== true) throw new Error("BILLING_RESULT_NOT_RECORDED");
      } catch (error) {
        logger.error("Deterministic Shopify rejection could not be recorded", error instanceof Error ? error.message : "unknown");
        return json(503, { error: "billing_result_record_failed", retryable: true });
      }
      const escalated = await exhaustedDeterministicFailure(shop, chargeId, attempt);
      if (escalated) return escalated;
      return json(422, { claimed: true, state: "FAILED", reason: "SHOPIFY_HTTP_REJECTION" });
    }

    let payload;
    try {
      payload = await upstream.json();
    } catch {
      return await ambiguousOutcome(shop, chargeId, "SHOPIFY_RESPONSE_NOT_JSON", attempt);
    }
    if (Array.isArray(payload?.errors) && payload.errors.length > 0) {
      // Top-level GraphQL errors do not prove whether the mutation committed.
      return await ambiguousOutcome(shop, chargeId, "SHOPIFY_GRAPHQL_OUTCOME_UNKNOWN", attempt);
    }

    const result = payload?.data?.appUsageRecordCreate;
    const providerId = typeof result?.appUsageRecord?.id === "string"
      ? result.appUsageRecord.id
      : "";
    const userErrors = Array.isArray(result?.userErrors) ? result.userErrors : [];
    if (providerId && userErrors.length === 0) {
      try {
        const recorded = await recordResult(shop, chargeId, true, providerId, null, null);
        if (recorded?.updated !== true || recorded?.status !== "SUBMITTED") {
          throw new Error("BILLING_RESULT_NOT_RECORDED");
        }
      } catch (error) {
        // Retrying the same mutation is safe: Shopify receives the same key and parameters.
        logger.error("Accepted Shopify usage record could not be committed locally", error instanceof Error ? error.message : "unknown");
        if (attempt >= 5) return await ambiguousOutcome(shop, chargeId, "LOCAL_RESULT_COMMIT_UNKNOWN", attempt);
        return json(503, { claimed: true, state: "PENDING", retryable: true, reason: "LOCAL_RESULT_COMMIT_UNKNOWN" });
      }
      return json(200, { claimed: true, state: "SUBMITTED", providerUsageRecordId: providerId });
    }

    const concurrent = userErrors.some((item) =>
      String(item?.code ?? "").toUpperCase() === "IDEMPOTENCY_CONCURRENT_REQUEST" ||
      /same idempotency key is being processed|currently in progress/i.test(String(item?.message ?? ""))
    );
    if (concurrent) return await ambiguousOutcome(shop, chargeId, "SHOPIFY_IDEMPOTENCY_REQUEST_IN_PROGRESS", attempt);

    if (userErrors.length > 0) {
      const message = userErrors.map((item) => String(item?.message ?? "Shopify user error")).join("; ").slice(0, 900);
      try {
        const recorded = await recordResult(shop, chargeId, false, null, "SHOPIFY_USAGE_USER_ERROR", message);
        if (recorded?.updated !== true) throw new Error("BILLING_RESULT_NOT_RECORDED");
      } catch (error) {
        logger.error("Shopify usage rejection could not be recorded", error instanceof Error ? error.message : "unknown");
        return json(503, { error: "billing_result_record_failed", retryable: true });
      }
      const escalated = await exhaustedDeterministicFailure(shop, chargeId, attempt);
      if (escalated) return escalated;
      return json(422, { claimed: true, state: "FAILED", reason: "SHOPIFY_USAGE_REJECTED" });
    }

    return await ambiguousOutcome(shop, chargeId, "SHOPIFY_USAGE_RESPONSE_INCOMPLETE", attempt);
  };
}
