# Worker-to-n8n receiver hardening contract (review-only)

Status: implementation contract for the preparation branch. No live n8n workflow, Supabase schema, or Cloudflare Worker has been changed by this document. The active `HENVALT_INGEST` workflow remains the source of truth until a separately approved cutover.

## Verified current state

- Active workflow: `HENVALT_INGEST`, ID `VTpfGKNtu1CSQ4Rv`.
- Webhook: POST `/henvalt/ingest`, raw body enabled, response mode `onReceived`.
- The current first business node is `Validate & Normalize`; Shopify HMAC verification occurs later in the graph.
- The Worker branch signs exact raw bytes with HMAC-SHA256 over `timestamp.requestId.` followed by the raw request bytes.
- The Worker branch now requires two independent secrets: `HENVALT_N8N_HMAC_SECRET` and `HENVALT_N8N_INGEST_TOKEN`. Neither is configured by this branch change.
- The receiver currently does not validate the new internal HMAC headers or claim request IDs. Do not deploy the Worker branch until the receiver cutover and secrets are completed.

## Required receiver order

The following nodes must be inserted immediately after `Event Webhook`, before `Validate & Normalize`, `Engine Config`, tenant resolution, Shopify HMAC RPCs, and every other side effect:

1. **Webhook-level Header Auth** — configure the existing `Event Webhook` trigger with n8n Header Auth. Credential header name: `x-henvalt-ingest-auth`. Credential value: the same random secret configured as Worker binding `HENVALT_N8N_INGEST_TOKEN`. This rejects requests before an execution is created. Do not use a query-string token.
2. **Prepare Internal HMAC Message** — Code node, Run Once for Each Item. Read only the raw binary body and the three internal headers. Construct the signed byte sequence as UTF-8 `<timestamp>.<request-id>.` concatenated with the exact original body bytes. Do not parse and re-serialize JSON for signing.
3. **Verify Internal HMAC** — native n8n Crypto node, action HMAC, type `SHA256`, binary input enabled, binary property `internalAuthMessage`, output property `computed_internal_signature`, encoding `BASE64`, and a Crypto credential whose HMAC Secret equals Worker binding `HENVALT_N8N_HMAC_SECRET`. Do not place the secret in node parameters or Code-node JSON.
4. **Compare Signature and Timestamp** — Code node. Require a 10-digit Unix-seconds timestamp, UUIDv4 request ID, strict 44-character Base64 SHA-256 signature, and a timestamp within ±300 seconds. Compare the two fixed-length Base64 strings in a full-length XOR loop; fail closed if any value is missing, malformed, or wrong. This avoids requiring Node.js module imports, which are not available in n8n Cloud Code nodes.
5. **Internal HMAC Valid?** — IF node. False path must terminate without reaching any existing processing node. Do not treat a missing header as an internal event.
6. **Claim Internal Request ID** — use a Postgres Execute Query node with the existing `Postgres account` credential already used by this workflow. Query: `SELECT henvalt.claim_internal_ingress_request($1::uuid, $2::timestamptz) AS claimed`. Bind query parameters as `[request_id, signed_at]`. The function atomically inserts the UUID and returns true only for the first claim.
7. **Request ID Claimed?** — IF node checking `{{$json.claimed === true}}`. False path terminates without side effects. True path continues to the existing `Validate & Normalize` node.

The static Header Auth gate and the body-bound HMAC are separate controls. The static token limits who can start an execution; HMAC proves that the body and request metadata were signed by the Worker. Do not replace Shopify's existing raw-body HMAC verification: both trust boundaries are required.

## Code node: prepare exact signed bytes

Configure this node as JavaScript, Run Once for Each Item:

```javascript
const item = $input.item;
const headers = item.json?.headers || {};
const timestamp = String(headers["x-henvalt-internal-timestamp"] || "");
const requestId = String(headers["x-henvalt-internal-request-id"] || "");
const suppliedSignature = String(headers["x-henvalt-internal-signature"] || "");
const rawBodyBase64 = item.binary?.data?.data || "";

const metadataValid =
  /^[0-9]{10}$/.test(timestamp) &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId) &&
  /^[A-Za-z0-9+/]{43}=$/.test(suppliedSignature) &&
  rawBodyBase64.length > 0 &&
  Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp)) <= 300;

const rawBody = rawBodyBase64 ? Buffer.from(rawBodyBase64, "base64") : Buffer.alloc(0);
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

## Code node: compare the Crypto node result

Configure the Crypto node with `action: hmac`, `type: SHA256`, `binaryData: true`, `binaryPropertyName: internalAuthMessage`, `dataPropertyName: computed_internal_signature`, and `encoding: base64`. Attach a Crypto credential containing the HMAC Secret. Then use this Code node (no `require()` or `$env` access):

```javascript
const item = $input.item;
const metadata = item.json?.__henvalt_internal_auth || {};
const expected = String(item.json?.computed_internal_signature || "");
const supplied = String(metadata.supplied_signature || "");

// Both values must be canonical 44-character Base64 SHA-256 HMACs.
// Iterate the entire fixed-length value rather than returning on first mismatch.
let signatureValid = false;
if (metadata.metadata_valid === true &&
    /^[A-Za-z0-9+/]{43}=$/.test(expected) &&
    /^[A-Za-z0-9+/]{43}=$/.test(supplied)) {
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
  binary: item.binary,
};
```

The Code node must not read the HMAC secret from `$env` or from workflow JSON. The secret belongs only in the n8n Crypto credential. The fixed-length XOR comparison avoids an early-exit string comparison but is not a formal constant-time primitive; the static Header Auth gate is also required.

## Replay-claim RPC contract

The review-only SQL companion file defines a private table with a UUID primary key and an atomic `claim_internal_ingress_request` function. The RPC:

- accepts only a UUID and signed timestamp;
- independently enforces the ±300-second timestamp window;
- inserts with `ON CONFLICT DO NOTHING`;
- returns true only when exactly one row was inserted;
- prunes a bounded batch of records older than seven days;
- is SECURITY DEFINER with a fixed search path;
- revokes execution from PUBLIC, anon, and authenticated; grants execution only to service_role;
- does not expose the table through the Data API.

Call this RPC only after HMAC verification. Its result must be checked before the original workflow graph continues. The existing workflow already has a `Postgres account` credential on its uninstall branch; reuse that credential for the replay claim instead of adding a new credential or putting database credentials in Code nodes.

## Response behavior and acknowledgement

The current webhook uses `responseMode: onReceived`. This means the Worker receives the early acknowledgement before in-workflow HMAC and replay checks finish. The static Header Auth gate still rejects unauthenticated callers before workflow execution, and invalid HMAC/replay requests must be stopped before every side effect. Do not silently change response mode during the security cutover: changing to a wait-for-completion response can increase Shopify webhook latency and must be separately load-tested. The Worker must not interpret the early 200 as proof that the business event was processed; the Supabase event/idempotency ledger remains the processing source of truth.

## Cutover acceptance tests

- Missing or wrong `x-henvalt-ingest-auth`: rejected by Webhook trigger before workflow execution.
- Missing timestamp, request ID, or signature: no processing node runs.
- Stale/future timestamp beyond 300 seconds: no processing node runs.
- One-byte body change: HMAC fails.
- Wrong HMAC secret: HMAC fails.
- Exact same signed request ID replayed twice: first claim true, second claim false.
- Different request IDs for a Shopify retry: existing Shopify webhook/event idempotency prevents duplicate business effects.
- Original raw Shopify body and Shopify headers remain intact for the existing Shopify HMAC verifier.
- A caller cannot set `source=internal` or forge tenant/shop identity to bypass Shopify verification.
- The static token and HMAC secret are different random values and stored only in Cloudflare secrets and n8n credentials.

## References

- n8n Webhook node supports Header Auth and raw-body mode: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/
- n8n Crypto node supports HMAC over binary data and stores the HMAC secret in Crypto credentials: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.crypto/
- n8n Crypto credentials: https://docs.n8n.io/integrations/builtin/credentials/crypto/
- n8n Cloud Code nodes do not support importing Node.js modules: https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.code/common-issues/
- Supabase security guidance: keep private tables out of public Data API access and restrict SECURITY DEFINER function EXECUTE grants.
