# HENVALT V2 native n8n Code-node snippets

**Status: candidate implementation material only.** These snippets are not imported into n8n and do not change the three active V1 workflows. They are designed for the existing three-workflow topology; do not create a fourth workflow.

## HTTP Request node contract

For Supabase RPC and V2 Edge Function HTTP Request nodes:

- Response format: JSON.
- Include full response so the Code node receives `statusCode` and `body`.
- Do not include request headers or credentials in the output item.
- Use the dedicated n8n credential for each server-side bearer; never put a token in an expression, Code node, item JSON or workflow static data.
- Disable automatic retries on provider-boundary requests.
- Route network/timeout errors to a sanitized `DEFERRED` result. Never retry the provider call from n8n.
- Use the Recovery service-role credential only on Recovery's Supabase RPC nodes. Delivery receives only the per-function delivery bearer.

The Recovery setup/claim snippets run once for all items. Delivery's per-claim validation/classification and Recovery's per-claim finish/acknowledgement snippets must be configured as **Run Once for Each Item** and return one `{ json: ... }` item (not an array).

## HENVALT_RECOVERY

### 1. Init V2 Worker

Immediately after the Schedule Trigger:

```javascript
const executionId = String($execution.id ?? "");
const workerId = `henvalt_recovery_v2:${executionId}`;

if (!/^[A-Za-z0-9._:-]{3,80}$/.test(workerId)) {
  throw new Error("v2_worker_id_invalid");
}

return [{ json: { worker_id: workerId } }];
```

### 2. Assert Stage Accepted

Place after each candidate refresh, promotion, and intervention materializer RPC. A failed stage must stop the tick before claim.

```javascript
const response = $input.first().json ?? {};
const body = response.body && typeof response.body === "object" && !Array.isArray(response.body)
  ? response.body
  : response;
const status = Number(response.statusCode ?? 200);

if (!Number.isInteger(status) || status < 200 || status >= 300 || body.accepted !== true) {
  throw new Error("v2_stage_rejected");
}

return [{ json: { accepted: true } }];
```

Do not pass the full RPC response into the next stage. Only the acceptance signal is needed.

### 3. Validate Claim Batch

After `claim_shopify_recovery_work_v2`. The database claim response must contain exactly three fields per item. This Code node adds only the worker ID and correlation ID required for the Delivery handoff.

```javascript
const response = $input.first().json ?? {};
const body = response.body && typeof response.body === "object" && !Array.isArray(response.body)
  ? response.body
  : response;
const status = Number(response.statusCode ?? 200);
const items = body.items;
const workerId = $("Init V2 Worker").first().json.worker_id;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedTypes = new Set(["CHECKOUT_INTERVENTION", "PIXEL_OPPORTUNITY"]);

if (!Number.isInteger(status) || status < 200 || status >= 300 ||
    body.accepted !== true || !Array.isArray(items) ||
    !Number.isInteger(body.claimed) || body.claimed !== items.length ||
    items.length > 25 || !/^[A-Za-z0-9._:-]{3,80}$/.test(workerId)) {
  throw new Error("v2_claim_batch_invalid");
}

const seenWork = new Set();
const seenLeases = new Set();

for (const item of items) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    throw new Error("v2_claim_item_invalid");
  }
  const keys = Object.keys(item).sort().join(",");
  if (keys !== "lease_id,work_id,work_type" ||
      !allowedTypes.has(item.work_type) ||
      !uuid.test(item.work_id ?? "") ||
      !uuid.test(item.lease_id ?? "")) {
    throw new Error("v2_claim_item_invalid");
  }
  const workKey = `${item.work_type}:${item.work_id}`;
  if (seenWork.has(workKey) || seenLeases.has(item.lease_id)) {
    throw new Error("v2_duplicate_claim_identity");
  }
  seenWork.add(workKey);
  seenLeases.add(item.lease_id);
}

return items.map(item => ({
  json: {
    work_type: item.work_type,
    work_id: item.work_id,
    lease_id: item.lease_id,
    worker_id: workerId,
    correlation_id: `v2:${item.work_id}`,
  },
}));
```

An empty claim returns zero items. Do not manufacture a placeholder item.

### 4. Execute Delivery

Use an Execute Sub-workflow node to call the existing `HENVALT_DELIVERY` synchronously for each validated item. Wait for the sub-workflow result. Pass only the five fields emitted by `Validate Claim Batch`. Recovery remains responsible for lease completion.

### 5. Validate Delivery Result and Build Finish RPC Body

After the Delivery sub-workflow returns. Configure this Code node as **Run Once for Each Item**:

```javascript
const claim = $("Validate Claim Batch").item.json;
const result = $input.item.json ?? {};
const allowedOutcomes = new Set(["HANDOFF_ACCEPTED", "TERMINAL", "DEFERRED"]);

let outcome = result.outcome;
let retryAfter = Number(result.retry_after_seconds ?? 3600);

if (result.work_type !== claim.work_type || result.work_id !== claim.work_id ||
    !allowedOutcomes.has(outcome)) {
  outcome = "DEFERRED";
  retryAfter = 3600;
} else if (outcome !== "DEFERRED") {
  retryAfter = 0;
} else if (!Number.isInteger(retryAfter) || retryAfter < 0 || retryAfter > 86400) {
  retryAfter = 3600;
}

return {
  json: {
    p_lease_id: claim.lease_id,
    p_worker_id: claim.worker_id,
    p_outcome: outcome,
    p_retry_after: `${retryAfter} seconds`,
    expected_outcome: outcome,
  },
};
```

Send only `p_lease_id`, `p_worker_id`, `p_outcome`, and `p_retry_after` to `finish_shopify_recovery_work_claim_v2`. Keep `expected_outcome` in the local execution item for the acknowledgement check; do not send it to the RPC.

### 6. Verify Finish Acknowledgement

After the finish RPC. Configure this Code node as **Run Once for Each Item**:

```javascript
const response = $input.first().json ?? {};
const body = response.body && typeof response.body === "object" && !Array.isArray(response.body)
  ? response.body
  : response;
const requested = $("Validate Delivery Result and Build Finish RPC Body").item.json;

if (body.finished !== true || body.outcome !== requested.expected_outcome) {
  throw new Error("v2_finish_ack_unconfirmed");
}

return { json: { finished: true, outcome: requested.expected_outcome } };
```

A missing or mismatched acknowledgement is not success. Alert and stop; do not immediately re-handoff the provider request. The database lease and provider-attempt reconciliation determine when work is safe to claim again.

## HENVALT_DELIVERY

### 1. Validate Opaque Claim

Configure as **Run Once for Each Item**. This rejects extra fields and prevents PII or provider data from entering the workflow.

```javascript
const input = $input.item.json ?? {};
const expected = ["correlation_id", "lease_id", "work_id", "work_type", "worker_id"];
const keys = Object.keys(input).sort();

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const types = new Set(["CHECKOUT_INTERVENTION", "PIXEL_OPPORTUNITY"]);

if (keys.length !== expected.length || keys.some((key, i) => key !== expected[i]) ||
    !types.has(input.work_type) ||
    !uuid.test(input.work_id ?? "") ||
    !uuid.test(input.lease_id ?? "") ||
    !/^[A-Za-z0-9._:-]{3,80}$/.test(input.worker_id ?? "") ||
    input.correlation_id !== `v2:${input.work_id}`) {
  throw new Error("v2_delivery_claim_invalid");
}

return {
  json: {
    work_type: input.work_type,
    work_id: input.work_id,
    lease_id: input.lease_id,
    worker_id: input.worker_id,
    correlation_id: input.correlation_id,
  },
};
```

### 2. Switch and Build Opaque Edge Request

Use a Switch on `work_type`. The two HTTP Request bodies must be separate. Configure each small Code node as **Run Once for Each Item**:

Checkout branch:

```javascript
return { json: { intervention_id: $json.work_id } };
```

Pixel branch:

```javascript
return { json: { opportunity_id: $json.work_id } };
```

Route checkout only to `/functions/v1/henvalt-shopify-contact-delivery-v2` and pixel only to `/functions/v1/henvalt-shopify-pixel-delivery-v2`. Use the corresponding server-held delivery bearer credential. Do not call MailerSend from n8n.

### 3. Classify Handoff Result

Configure as **Run Once for Each Item** after the corresponding HTTP Request. Configure the HTTP node to expose status and JSON body; its error output for network/timeout failures must produce the same deferred shape without exposing the error body.

```javascript
const response = $input.item.json ?? {};
const body = response.body && typeof response.body === "object" && !Array.isArray(response.body)
  ? response.body
  : response;
const status = Number(response.statusCode ?? 0);
const state = typeof body.status === "string" ? body.status : "";

const accepted = new Set(["submitted", "accepted", "handed_off"]);
const ambiguous = new Set([
  "ambiguous_provider_submission",
  "provider_accepted_record_pending",
  "provider_outcome_requires_reconciliation",
]);

let outcome = "DEFERRED";
let reason = "handoff_not_confirmed";
let retry = 3600;

if (status >= 200 && status < 300 && body.accepted === true && accepted.has(state)) {
  outcome = "HANDOFF_ACCEPTED";
  reason = "explicit_handoff_accepted";
  retry = 0;
} else if (status >= 200 && status < 300 && body.accepted === true && ambiguous.has(state)) {
  outcome = "HANDOFF_ACCEPTED";
  reason = "accepted_provider_reconciliation_pending";
  retry = 0;
} else if (status === 502 && body.accepted === false && body.error === "provider_submission_rejected") {
  outcome = "TERMINAL";
  reason = "provider_rejection_recorded";
  retry = 0;
} else if (status === 400 || status === 422) {
  outcome = "TERMINAL";
  reason = "permanent_request_rejection";
  retry = 0;
} else if (status === 401 || status === 403) {
  reason = "delivery_auth_incident";
} else if (status === 409) {
  reason = "delivery_preflight_or_eligibility_review";
} else if (status === 429) {
  reason = "handoff_rate_limited";
} else if (status === 404 || status === 410 || status === 408 || status >= 500) {
  reason = "edge_or_provider_unavailable";
}

const claim = $("Validate Opaque Claim").item.json;

return {
  json: {
    work_type: claim.work_type,
    work_id: claim.work_id,
    outcome,
    reason,
    retry_after_seconds: retry,
  },
};
```

A 404/410 can be a gateway-level missing/retired function route. It must defer, never terminalize the opportunity. A 202 ambiguous response means the Edge Function owns provider reconciliation; Recovery may complete the handoff lease but must not submit again.

## Mandatory node-level safeguards

- Use only the three existing workflow IDs. This document is not a fourth workflow.
- No manual test-email trigger or one-off sender branch in the V2 graph.
- No recipient, customer, store, message, access token, provider token, raw response body or webhook secret in any n8n item.
- Recovery owns lease completion; Delivery never calls the finish RPC.
- Provider submission and retry logic remain inside the trusted Edge Functions.
- Set instance-wide execution retention/redaction only after reviewing the n8n instance controls. Workflow-level settings alone do not prove that payloads are not persisted.
- Import as inactive drafts only after explicit approval. Do not publish, activate, execute, change credentials or modify the live V1 workflows under this specification.
