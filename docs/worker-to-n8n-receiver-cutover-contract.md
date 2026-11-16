# Worker-to-n8n receiver hardening contract (review-only)

Status: implementation contract for the preparation branch. No live n8n workflow, Supabase schema, or Cloudflare Worker has been changed by this document. The active `HENVALT_INGEST` workflow remains the source of truth until a separately approved cutover.

## Verified live state

- Active workflow: `HENVALT_INGEST`, ID `VTpfGKNtu1CSQ4Rv`, 51 nodes.
- Active version: `6368d539-708f-494a-8be8-b9601d0e8607`.
- Webhook: Webhook v2.1, POST `/henvalt/ingest`, raw body enabled, response mode `onReceived`.
- The live graph still connects `Event Webhook` directly to `Validate & Normalize`; no internal-auth gate is installed.
- The existing validator reads the original `binary.data.data` payload for the later Shopify HMAC check.
- The Worker preparation branch signs exact body bytes with HMAC-SHA256 over UTF-8 `timestamp.requestId.` followed by the raw request bytes. It requires separate `HENVALT_N8N_HMAC_SECRET` and `HENVALT_N8N_INGEST_TOKEN` bindings; neither is configured by this branch change.
- The receiver does not yet validate these internal headers or claim request IDs. Do not deploy the Worker branch until receiver cutover and both secret configurations are complete.

## Credential prerequisites (manual cutover only)

Create dedicated credentials in the existing n8n workspace. Do not paste secret values into workflow JSON, GitHub, SQL, or chat.

1. Header Auth credential named `HENVALT Worker Ingress Auth`: header name `x-henvalt-ingest-auth`, with a new random token. Attach it to the existing `Event Webhook`. Configure the same value as Worker secret binding `HENVALT_N8N_INGEST_TOKEN`.
2. Crypto credential named `HENVALT Worker HMAC`: set its HMAC Secret to a different new random secret. Attach it to the Crypto node. Configure the same value as Worker secret binding `HENVALT_N8N_HMAC_SECRET`.

The active workflow has an existing `Postgres account` credential used by another node. Reuse it for the replay-claim query only after its effective database role and grants have been verified. Do not repurpose either existing generic Header Auth credential: neither is attached to the active webhook and their purpose is unknown. The current credential inventory contains no Crypto credential.

## Required receiver graph

Insert the gate immediately after the webhook and before `Validate & Normalize`, tenant resolution, Shopify HMAC RPCs, or any business side effect:

```text
Event Webhook (Header Auth)
  → Prepare Internal HMAC Message
      ├─ branch A → Merge input 1 (preserve original binary)
      └─ branch B → Verify Internal HMAC (Crypto v2)
                     → Compare Signature and Timestamp
                     → Internal HMAC Valid?
                         true → Claim Internal Request ID
                                  → Request ID Claimed?
                                      true → Merge input 2
                                      false → stop
                         false → stop

Merge (v3, combine, combineByPosition, 2 inputs)
  → Strip Internal Auth Binary/Metadata
  → Validate & Normalize (existing graph)
```

The false outputs must remain unconnected to the Merge and every business node. The replay claim is deliberately placed after valid HMAC and before Merge: an invalid or replayed request cannot restore the original branch into the processing path. The Merge waits for both connected inputs and combines matching item positions. Confirm one-item-per-webhook behavior in the test harness before cutover.

## Prepare Internal HMAC Message (Code v2)

Mode: Run Once for Each Item. Read raw bytes through n8n's binary helper; do not depend on inline `binary.data.data`, and do not copy the full raw body into JSON execution data.

```javascript
const item = $input.item;
const headers = item.json?.headers || {};
const timestamp = String(headers["x-henvalt-internal-timestamp"] || "");
const requestId = String(headers["x-henvalt-internal-request-id"] || "");
const suppliedSignature = String(headers["x-henvalt-internal-signature"] || "");

const metadataValid =
  /^[0-9]{10}$/.test(timestamp) &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId) &&
  /^[A-Za-z0-9+/]{43}=$/.test(suppliedSignature) &&
  !!item.binary?.data &&
  Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp)) <= 300;

if (!item.binary?.data) {
  throw new Error("Missing original Shopify raw request body");
}

const rawBody = await this.helpers.getBinaryDataBuffer($itemIndex, "data");
const prefix = Buffer.from(timestamp + "." + requestId + ".", "utf8");
const signedBytes = Buffer.concat([prefix, rawBody]);

return {
  json: {
    ...item.json,
    __henvalt_internal_auth: {
      timestamp,
      request_id: requestId,
      supplied_signature: suppliedSignature,
      metadata_valid: metadataValid,
    },
  },
  binary: {
    ...(item.binary || {}),
    internalAuthMessage: {
      data: signedBytes.toString("base64"),
      mimeType: "application/octet-stream",
      fileName: "henvalt-internal-auth-message.bin",
    },
  },
};
```

This node fans its single output to both Merge input 1 and the Crypto node. Branch A must retain the original `binary.data`; branch B is only for HMAC calculation.

## Verify Internal HMAC (Crypto v2)

Configure the native Crypto node with:

- `action: hmac`
- `type: SHA256`
- `binaryData: true`
- `binaryPropertyName: internalAuthMessage`
- `dataPropertyName: computed_internal_signature`
- `encoding: base64`
- Dedicated Crypto credential `HENVALT Worker HMAC`

The official Crypto v2 implementation reads the binary bytes and calculates HMAC-SHA256. **It intentionally does not copy the input binary properties to its output.** Do not expect `binary.data` or `binary.internalAuthMessage` to survive this node. The separate Merge input-1 branch is the source of the original raw body.

The installed type registry exposes the Merge v3 configuration below, but the live Crypto HMAC execution has not been tested on this n8n Cloud instance because no dedicated Crypto credential exists.

## Compare Signature and Timestamp (Code v2)

This node runs after Crypto. It returns JSON only; the original binary remains safely on Merge input 1.

```javascript
const item = $input.item;
const metadata = item.json?.__henvalt_internal_auth || {};
const expected = String(item.json?.computed_internal_signature || "");
const supplied = String(metadata.supplied_signature || "");

let signatureValid = false;
if (
  metadata.metadata_valid === true &&
  /^[A-Za-z0-9+/]{43}=$/.test(expected) &&
  /^[A-Za-z0-9+/]{43}=$/.test(supplied)
) {
  let difference = 0;
  for (let i = 0; i < 44; i++) {
    difference |= expected.charCodeAt(i) ^ supplied.charCodeAt(i);
  }
  signatureValid = difference === 0;
}

return {
  json: {
    ...item.json,
    __henvalt_internal_auth: {
      ...metadata,
      valid: signatureValid,
      signed_at: /^[0-9]{10}$/.test(String(metadata.timestamp || ""))
        ? new Date(Number(metadata.timestamp) * 1000).toISOString()
        : null,
    },
  },
};
```

The fixed-length XOR loop avoids early-exit comparison but is not a formal constant-time primitive. The independent Header Auth gate remains mandatory. No Code node may read the HMAC secret from `$env`, workflow JSON, or request data.

## Replay claim

Only the true output of `Internal HMAC Valid?` reaches the Postgres claim node. Use the existing `Postgres account` credential after its role/grants are verified.

Query:

```sql
SELECT
  $1::uuid AS request_id,
  $2::timestamptz AS signed_at,
  henvalt.claim_internal_ingress_request(
    $1::uuid,
    $2::timestamptz
  ) AS claimed;
```

Bind query replacements in this order:

1. `request_id` = `__henvalt_internal_auth.request_id`
2. `signed_at` = `__henvalt_internal_auth.signed_at`

The returned row deliberately includes `request_id` and `signed_at` so the next Merge input receives a stable item while preserving the claim result. Configure `Request ID Claimed?` to continue only when `{{$json.claimed === true}}`. Its false output must terminate.

The companion SQL file is review-only and has not been applied. Before any migration, verify function ownership, schema USAGE, effective grants, service-role execution, first claim=true, duplicate=false, stale/future=false, and denial for unauthorized roles.

## Merge and raw-body restoration

Use installed Merge node v3 with:

- `mode: combine`
- `combineBy: combineByPosition`
- `numberInputs: 2`

Wire the prepared original item to input 1. Wire only the true output of `Request ID Claimed?` to input 2. Merge waits for both connected inputs and combines items by position. Input 1 carries the original `binary.data`; the Crypto branch is not used for binary restoration.

After Merge, add `Strip Internal Auth Binary/Metadata` (Code v2, Run Once for Each Item):

```javascript
const item = $input.item;
const {
  __henvalt_internal_auth,
  computed_internal_signature,
  ...json
} = item.json || {};

const originalBody = item.binary?.data;
if (!originalBody) {
  throw new Error("Original Shopify raw body missing after authenticated merge");
}

const headers = { ...(json.headers || {}) };
delete headers["x-henvalt-internal-timestamp"];
delete headers["x-henvalt-internal-request-id"];
delete headers["x-henvalt-internal-signature"];
delete headers["x-henvalt-ingest-auth"];

return {
  json: { ...json, headers },
  binary: { data: originalBody },
};
```

This strips the temporary HMAC message and internal-auth metadata while preserving the exact original Shopify binary under `binary.data`. Only this node connects to the existing `Validate & Normalize`.

## Response and acknowledgement semantics

Keep the current webhook `responseMode: onReceived` for the initial security cutover. It acknowledges receipt before in-workflow HMAC/replay validation completes. The Worker must not treat the early HTTP 200 as proof that the event was accepted or processed; downstream Supabase event/idempotency state remains the processing source of truth. Any switch to wait-for-completion response mode requires separate latency and Shopify webhook retry testing.

## Acceptance tests required before cutover

- Missing/wrong `x-henvalt-ingest-auth`: rejected by Webhook trigger before workflow execution.
- Missing/malformed timestamp, UUIDv4 request ID, or signature: no processing node runs.
- Timestamp outside ±300 seconds: no processing node runs.
- One-byte body mutation or wrong HMAC secret: HMAC check fails.
- First request-ID claim succeeds; exact replay claim fails.
- Invalid signature and duplicate request ID cannot reach Merge input 2 or `Validate & Normalize`.
- Original `binary.data` bytes and Shopify headers are unchanged after Merge/Strip.
- Multiple-item input is either explicitly rejected or proven to pair safely; do not assume position pairing is safe for differing branch item counts.
- Different request IDs on Shopify retries remain protected by existing Shopify event idempotency.
- Static token and HMAC secret are different random values and exist only in Cloudflare secrets and n8n credentials.

## Verification boundary

Verified by read-only inspection:
- Active webhook v2.1 has raw body enabled and no authentication configured.
- Active workflow currently connects webhook directly to normalization.
- Installed Merge v3 definition supports `combineByPosition`, two inputs, and waits for all connected inputs.
- Existing validator consumes the raw binary body.
- Credential inventory has no dedicated Crypto credential; generic Header Auth credentials are not attached to the webhook.

Verified from official n8n source/docs:
- Code node binary helper: `this.helpers.getBinaryDataBuffer($itemIndex, "data")`.
- Crypto v2 HMAC field contract and credential field `hmacSecret`.
- Crypto v2 intentionally drops binary output after processing binary input.
- Previous-node binary references expose metadata without the underlying `data` payload.

Not yet verified:
- Actual Crypto HMAC execution on this n8n Cloud instance.
- Merge's real execution behavior for this exact graph and binary object.
- Postgres credential effective role/grants and successful replay RPC call.
- Full n8n Cloud receiver execution with valid, invalid, and replay fixtures.

No temporary workflow or Crypto credential has been created. No production workflow, Supabase SQL, Worker, Shopify app, or release has been changed.

## References

- n8n Webhook node: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/
- n8n Crypto node: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.crypto/
- n8n Crypto credentials: https://docs.n8n.io/integrations/builtin/credentials/crypto/
- n8n Code node binary helper: https://docs.n8n.io/code/cookbook/binary-data/
- n8n Code node limitations: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.code/common-issues/
- n8n Merge node: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.merge/
- n8n workflow data proxy source: https://github.com/n8n-io/n8n/blob/master/packages/workflow/src/workflow-data-proxy.ts
- n8n Crypto v2 source: https://github.com/n8n-io/n8n/blob/master/packages/nodes-base/nodes/Crypto/v2/CryptoV2.node.ts
