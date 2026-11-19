# HENVALT V2 runtime cutover boundary — n8n

**Status:** read-only architecture checkpoint, refreshed 19 November 2026. The three production workflows were inspected but not executed, edited, unpublished or republished. No production Supabase or Shopify changes were made.

## 1. Current active workflow inventory

The connected n8n instance currently has exactly three active HENVALT workflows:

| Workflow | ID | Active version | Nodes |
|---|---|---|---:|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 51 |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 46 |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 62 |

The workflow count is already three. V2 cutover must evolve these three workflows; it must not create a parallel fourth production workflow.

## 2. Verified legacy runtime dependencies

### HENVALT_INGEST

The active graph still calls the legacy tenant-oriented pipeline, including:
- `ingest_raw_webhook_v2`
- `upsert_canonical_event`
- `resolve_identity`
- `upsert_customer` and `upsert_checkout`
- `create_opportunity_idempotent`
- `evaluate_eligibility` and `apply_eligibility`
- `create_recovery_sequence` and `create_intervention_and_enqueue`
- `project_order_from_event` and `evaluate_order_attribution`
- `post_recovery_to_ledger_and_measure_billing`

It also contains a Shopify webhook/HMAC path. The new V2 Shopify webhook path is separate: Cloudflare Worker → protected Supabase ingress/projection functions → exact-store V2 order and pixel records. Do not route the same Shopify webhook into both paths and allow dual writes.

### HENVALT_RECOVERY

The active worker still claims and processes legacy jobs/interventions using:
- `claim_next_job`
- `claim_intervention_for_send`
- `get_recovery_worker_context`
- `create_delivery_request`
- `process_browse_abandonment_candidates`
- `process_abandoned_cart_candidates`
- `process_abandoned_checkout_candidates`

The V2 opportunity, pixel-candidate, permit and attempt tables are separate. A legacy claim or delivery request is not proof that a V2 opportunity has been claimed or authorized.

### HENVALT_DELIVERY

The active delivery path still uses:
- `authorize_delivery_request`
- `henvalt-mailersend-delivery`
- `record_delivery_result`
- `process_mailersend_webhook_event`
- `verify_mailersend_webhook_signature_api`
- `schedule_next_recovery_intervention`

The V2 path instead has exact-store checkout permits and a separate pixel permit/context/provider-submission lifecycle, with provider-event reconciliation and cost reservation in the V2 database boundary. Calling the legacy authorization RPC does not consume a V2 permit.

## 3. Required V2 responsibility split — preserve three workflows

1. **HENVALT_INGEST — verified event intake and routing.** Shopify raw webhook verification and durable receipt remain on the V2 Worker/Edge Function path. n8n must not independently re-ingest the same Shopify delivery into legacy canonical-event tables. It should process only explicitly defined internal V2 work signals and preserve exact tenant + connection identity.
2. **HENVALT_RECOVERY — scheduled discovery and orchestration.** It must consume V2-ready checkout/cart/browse work through service-only, exact-connection claim operations. It must not infer identity from tenant-wide customer IDs, recreate opportunities in legacy tables, or bypass V2 eligibility.
3. **HENVALT_DELIVERY — authorized provider boundary.** It must call the appropriate V2 delivery Edge Function/permit path. Raw recipient email, Shopify access tokens, MailerSend API tokens and fingerprint secrets must not pass through n8n item data or execution logs. Cost reservation, final consent/suppression checks, provider outcome and ambiguous-state handling remain server-side.

The V2 SQL/provider-event and order-projection lifecycle owns recovered-order attribution. n8n must never mark an order recovered merely because an email was accepted, sent, opened or clicked.

## 4. V2 delivery and trusted message contracts

The two delivery Edge Functions now accept **opaque work identifiers only**:

- Checkout: `POST /functions/v1/henvalt-shopify-contact-delivery-v2` with JSON `{"intervention_id":"<UUID>"}`.
- Cart/browse: `POST /functions/v1/henvalt-shopify-pixel-delivery-v2` with JSON `{"opportunity_id":"<UUID>"}`.

Any additional request property (including caller-supplied `subject`, `html`, `text`, email, store domain or template fields) is rejected. The n8n workflow must not run a renderer or pass message bodies to these functions.

Migration `202611190001_shopify_recovery_message_context_v2.sql` adds the service-only `resolve_shopify_recovery_message_context_v2(work_type,work_id)` RPC. It revalidates exact tenant + connection + active app/store + source lineage and returns only:
- canonical `*.myshopify.com` domain;
- allowlisted `opportunity_type`;
- template version marker.

It never returns recipient PII, provider/Shopify secrets or delivery authority. The trusted Edge Function then renders the message using `recovery-message-v2.mjs` and the verified sender display name. Current copy is deliberately conservative: no customer name, product title, cart contents, discount, fabricated checkout URL or untrusted HTML. The CTA points to the verified store's HTTPS `myshopify.com` root, not a guessed checkout permalink. This is a safe fallback, not yet a saved-checkout deep link or item-level personalization.

### Mandatory unsubscribe gate

All three templates include MailerSend's `{{unsubscribe}}` placeholder in both HTML and plain text. Before provider submission, the Edge Function calls MailerSend's domains API using the server-held API token and requires the exact sender domain to be verified with:
- `track_unsubscribe=true`;
- `track_unsubscribe_html_enabled=true`;
- `track_unsubscribe_plain_enabled=true`.

If the account/domain lookup fails, the domain is not verified, or either body insertion option is disabled, delivery fails closed with `mailer_send_v2_delivery_preflight_failed`. The placeholder is never sent knowingly as literal text. Both checkout and pixel paths perform this preflight before any permit issue/consume, so missing provider configuration creates no send attempt or cost reservation. The sending domain must be configured and verified in MailerSend before any test send.

### Provider outcome and retry boundary

Both Edge Functions mark the provider boundary before the HTTP request. A network exception, HTTP 408/5xx, missing provider message ID, or post-request ledger failure is treated as AMBIGUOUS; its cost reservation remains held for signed webhook/manual reconciliation. The response is 202 with an explicit ambiguous/pending status. n8n must finish the lease as `HANDOFF_ACCEPTED` and must never call the delivery function again for that work item. A definite provider rejection is recorded FAILED; because the claim query excludes any existing send attempt, it must not be blindly retried. n8n must not call the legacy delivery-result RPC. The V2 signed MailerSend webhook Edge Function owns provider-event correlation, suppression and ambiguous-attempt reconciliation.

Both functions require their independent server-held delivery bearer secret. Recipient email remains inside the trusted Edge Function and provider request; n8n receives only the opaque IDs and structured status.

The V2 claim/lease adapter now exists in migration 042, and migration 043 now materializes step-1 checkout interventions from eligible exact-store checkout opportunities. Disposable PostgreSQL tests cover both checkout intervention and pixel opportunity work, intervention materialization idempotency, true concurrent claim exclusion, deferred retry with a fresh lease identity, stale-worker rejection and terminal completion. The active Recovery workflow is still not wired to it; production cutover remains pending.

## 5. V2 claim/lease RPC contract — migration 042

The branch now contains `202611180042_shopify_recovery_work_claims_v2.sql`. It introduces a shared exact-store queue without merging the two delivery models.

### Scheduled discovery and checkout intervention materialization

Before claiming work, the V2 Recovery schedule should run the candidate lifecycle in this order:
1. `refresh_shopify_checkout_recovery_candidates_v2(limit)` — refreshes exact-store checkout candidate eligibility from verified webhook projections.
2. `promote_shopify_checkout_recovery_candidates_v2(limit)` — creates idempotent checkout opportunities and marks converted/closed candidates.
3. `refresh_shopify_pixel_recovery_candidates_v2(inactivity,max_age,limit)` — refreshes pseudonymous cart/browse candidates only from analytics-permitted pixel events.
4. `promote_shopify_pixel_recovery_candidates_v2(limit)` — creates cart/browse opportunities in `REVIEW_REQUIRED`; it does not authorize marketing delivery.
5. `materialize_shopify_checkout_interventions_v2(limit)` — migration 043 creates step-1 checkout intervention metadata only for open, exact-store, due checkout opportunities. It creates no intervention for pixel opportunities, issues no permit, and calls no provider.
6. `claim_shopify_recovery_work_v2(worker,limit,lease_seconds)` — leases due checkout interventions and pixel opportunities for the existing synchronous Recovery → Delivery handoff.

The checkout materializer rechecks active store/app/tenant, exact checkout/customer lineage, open checkout state, candidate token equality and absence of a same-store order. Its unique (opportunity, step) constraint makes repeated schedules idempotent. The delivery Edge Function still performs current Shopify consent, contact, suppression, sender, billing, provider-cost and final order checks; materialization is not consent or delivery authorization.

### Claim

Call the service-role RPC:

```json
{
  "p_worker_id": "HENVALT_RECOVERY",
  "p_limit": 25,
  "p_lease_seconds": 180
}
```

Endpoint: `POST /rest/v1/rpc/claim_shopify_recovery_work_v2`, with `apikey` and bearer authorization held only in the n8n credential store, and `accept-profile: henvalt` / `content-profile: henvalt`.

The response contains exactly three opaque fields per item: `lease_id`, `work_type`, and `work_id`. Tenant/store/opportunity lineage remains private in the lease table and is not returned to n8n.

- `CHECKOUT_INTERVENTION`: `work_id` and `intervention_id` are the same intervention UUID; `opportunity_id` is its exact-store opportunity.
- `PIXEL_OPPORTUNITY`: `work_id` and `opportunity_id` are the same pixel opportunity UUID; `intervention_id` is null.

No tenant ID, Shopify connection ID, opportunity lineage, expiry or attempt count is returned. No recipient email, Shopify token, provider secret, message body or send authority is returned. The queue filters inactive stores/apps/tenants, same-store conversions, existing attempts, non-due work and ineligible source states. The claim write is atomic under the unique (work type, work ID) key, so concurrent workers cannot own the same active lease.

### Finish or defer

Call `POST /rest/v1/rpc/finish_shopify_recovery_work_claim_v2`:

```json
{
  "p_lease_id": "UUID_FROM_CLAIM",
  "p_worker_id": "HENVALT_RECOVERY",
  "p_outcome": "HANDOFF_ACCEPTED",
  "p_retry_after": "01:00:00"
}
```

Allowed outcomes:
- `HANDOFF_ACCEPTED`: the V2 delivery boundary returned an accepted/ambiguous provider outcome or a successfully recorded attempt. The lease is terminal; provider reconciliation and Shopify order attribution proceed independently.
- `TERMINAL`: the item is permanently ineligible/closed/already processed and must not be retried by the worker.
- `DEFERRED`: retry the review later. The current lease is invalidated and the work becomes claimable after the supplied delay (0–24 hours).

A reclaimed item gets a new lease UUID. A stale worker cannot finish the newer lease. Network timeouts must not be reported as accepted; defer and let the V2 attempt/idempotency state decide whether another handoff is safe. Never call the legacy `authorize_delivery_request` or legacy `record_delivery_result` functions.

### HENVALT_RECOVERY → HENVALT_DELIVERY routing

The existing active `HENVALT_RECOVERY` already invokes the existing `HENVALT_DELIVERY` as a synchronous Execute Workflow subworkflow. Preserve that exact three-workflow topology; do not have Recovery call the MailerSend endpoints directly.

For each claim item, Recovery passes the opaque `work_type`, `work_id`, `opportunity_id`, `intervention_id`, `lease_id`, `tenant_id`, `shopify_connection_id` and `opportunity_type` to `HENVALT_DELIVERY`. The delivery subworkflow branches on `work_type`:
1. `CHECKOUT_INTERVENTION` → call `henvalt-shopify-contact-delivery-v2` with exactly `{"intervention_id":"<UUID>"}`. The Edge Function resolves contact and current consent, renders the approved server-side template, issues/consumes the checkout permit, reserves provider cost and submits.
2. `PIXEL_OPPORTUNITY` → call `henvalt-shopify-pixel-delivery-v2` with exactly `{"opportunity_id":"<UUID>"}`. It uses the separate pixel context, eligibility assessment, server-side template, pixel permit, final Shopify consent lookup and provider submission gate.
3. Return a structured outcome to Recovery. A 202 response with `submitted`, `ambiguous_provider_submission` or `provider_accepted_record_pending` means the server-side attempt lifecycle owns the outcome; do not resend or create another attempt. Recovery finishes the lease as `HANDOFF_ACCEPTED`.
4. A 409 eligibility/consent/suppression/order response is a review outcome. Use `DEFERRED` for conditions that can change (for example, fresh evidence or a jurisdiction policy review); use `TERMINAL` for permanently closed, converted or revoked records.
5. A 5xx before provider submission can be deferred. If provider submission may have started, the Edge Function marks the attempt AMBIGUOUS and retains its cost reservation; do not manually release it or create a second send. Let the signed MailerSend webhook reconciler resolve it.
6. Recovery calls `finish_shopify_recovery_work_claim_v2` after the subworkflow returns. Network timeouts are deferred, never treated as accepted. Never pass raw email, customer context, message bodies, Shopify tokens or provider credentials between n8n nodes. Do not log complete HTTP request/response bodies.

**Message-rendering contract is implemented in this branch.** Both Edge Functions accept only their single opaque identifier, resolve PII-free exact-store message context through the service-only RPC, and render the approved template inside the trusted Edge Function. The renderer accepts only the three allowlisted opportunity types and a validated canonical Shopify domain plus verified sender display name. It includes MailerSend's unsubscribe placeholder in HTML and plain text. The Edge Function verifies sender-domain unsubscribe insertion and the exact enabled V2 webhook before issuing a permit. The CTA intentionally points to the canonical store root; checkout deep links and item-level personalization remain excluded until a separately verified source is implemented.

MailerSend's signed event URL must point directly to the V2 webhook Edge Function with the untouched raw body and provider signature. Do not process the same provider event through both legacy and V2 event handlers.

The `HENVALT_INGEST` workflow remains outside this claim queue: verified Shopify webhooks are ingested by the Worker/Edge Function boundary, not duplicated through legacy n8n ingestion. The active `HENVALT_RECOVERY` and `HENVALT_DELIVERY` versions remain unchanged.

## 6. Cutover gates

Do not edit or publish the active workflows until each gate is satisfied:

- [x] V2 service-only claim/lease contract exists for both checkout interventions and pixel opportunities; exact-store lineage, active-lease exclusion, stale-worker rejection, deferral and terminal completion pass disposable PostgreSQL CI. Cross-tenant concurrency is enforced by the shared unique lease key and tenant/store lineage.
- [ ] A documented mapping exists from V2 opportunity/candidate → claim → intervention/permit → Edge Function → provider outcome → provider-event reconciliation.
- [ ] Checkout and pixel delivery use their distinct V2 permit paths; no fabricated checkout identity is introduced for cart/browse.
- [ ] n8n payloads contain opaque IDs and correlation IDs only; no raw recipient email, secrets, tokens or customer payloads.
- [ ] A no-send dry-run test proves that an ineligible, suppressed, unconsented, inactive or over-budget record cannot reach MailerSend.
- [ ] Duplicate execution, timeout, stale worker, provider acceptance ambiguity and webhook retry tests prove idempotency without automatic duplicate sends.
- [ ] A disposable end-to-end test proves a signed Shopify order webhook can be projected and attributed to a prior eligible V2 touch; refunds then update the dashboard totals.
- [ ] Existing legacy workflows are compared against the V2 branch contract and a rollback plan is documented.
- [ ] The owner explicitly approves any production workflow update, activation or real provider send.


## 8. Migrations 042–043 validation

The V2 work-claim and checkout intervention lifecycle passed disposable CI run #962 on 18 November 2026, including true concurrent workers. Earlier branch head 0932059e passed full CI runs #968 and #969, including checkout materializer idempotency and pixel/checkout separation. The message-context and server-rendered delivery changes are later candidate work and require their own current CI run:
- migrations 042 and 043 apply after migrations 001–041 on disposable PostgreSQL;
- a pixel opportunity is claimed with exact tenant/store lineage and no intervention/checkout identity;
- a second worker cannot claim an active lease;
- deferred work is reclaimed under a new lease UUID;
- the stale worker cannot finish the reclaimed lease;
- a current worker can complete it, after which it is no longer claimable;
- a checkout opportunity is materialized into one step-1 intervention, a repeated materialization creates zero duplicates, and the intervention is independently claimable with its own intervention/opportunity lineage;
- no recipient email, provider credentials, Shopify token or message body enters the claim response.

GitHub's connected Cloudflare Pages integration also produced successful **preview** builds for the preparation branch. The deployment records identify environment `preview`, branch `prep/public-app-hardening-2026-11-15`, and production branch `main`; they did not deploy this branch to the production environment.

## 9. Current release boundary

The repository candidate now contains migrations 039–043, pixel attribution, the exact-store V2 dashboard read model, merchant store selection, checkout intervention materialization and concurrent work claims. These remain candidate changes and have not been applied to the active Supabase project.

The active n8n workflows remain unchanged and continue to reference legacy functions. That means the new V2 database lifecycle and dashboard are validated as candidate code, but **the live n8n runtime is not yet connected to the V2 lifecycle**. This is a launch blocker, not a reason to mutate the active workflows prematurely.

No n8n workflow execution was triggered during this inspection. No active workflow was changed, disabled, published or unpublished. No customer email, provider call, billing action or production data mutation occurred.

## 8. Provider and delivery ingress request limits

The checkout delivery and signed MailerSend webhook Edge Functions now use the
shared bounded streaming request reader at
`supabase/functions/_shared/request-body-v2.ts`. Checkout input is limited
to 160 KB and a strict object-key allowlist; signed provider events are limited
to 1 MB before raw-body signature verification. Content type, UTF-8, JSON
shape and streamed byte count are validated without relying on Content-Length.
This is a branch-only hardening change. It does not change the active n8n
graphs or the live MailerSend webhook route.

## 10. Read-only inspection of the active workflow graphs — 19 November 2026

The connected n8n service was inspected again in read-only mode. Exact active
workflow versions at inspection time:

| Workflow | Workflow ID | Active version | Updated |
|---|---|---|---|
| HENVALT_INGEST | `VTpfGKNtu1CSQ4Rv` | `6368d539-708f-494a-8be8-b9601d0e8607` | 13 Nov 2026 |
| HENVALT_RECOVERY | `3GEDoeCA4paXTaDF` | `32e50bf7-4cbd-4070-bbba-f259ed17b369` | 14 Nov 2026 |
| HENVALT_DELIVERY | `CvVyybGJZSnklxiZ` | `621ae6ce-a006-4fed-a70e-acf774c360fb` | 14 Nov 2026 |

All three are active. The active graphs confirm that the current runtime is
still legacy:

### Active HENVALT_INGEST

The current graph has a public-facing webhook path `henvalt/ingest`, performs
Shopify HMAC verification, resolves the legacy tenant, writes canonical
events and checkout projections, and also handles order projection,
attribution, stopping recovery after an order, uninstall deactivation,
payment-order reconciliation and refund/revenue adjustments.

This overlaps responsibilities now implemented by the V2 Shopify Worker /
Edge Function receipt and projection path. The cutover must assign each
Shopify topic/store to exactly one authoritative ingress and projection
path. Do not globally disable HENVALT_INGEST: legacy stores and payment/
refund/uninstall responsibilities may still depend on it. Conversely, do not
send the same V2 event to both paths without an idempotent, explicitly tested
handoff.


### Active HENVALT_RECOVERY

The current graph:
- Claims legacy jobs through `henvalt.claim_next_job`.
- Claims interventions through `henvalt.claim_intervention_for_send`.
- Loads tenant-scoped data through `henvalt.get_recovery_worker_context`.
- Runs `Preflight & AI Context`, which constructs AI context containing
  customer first name, product details, previous message bodies, store name,
  cart/checkout value, recipient reference and destination URL.
- Runs Groq generation/validation, then persists a rendered message through
  `henvalt.render_and_queue_message`.
- Creates a legacy delivery request through
  `henvalt.create_delivery_request`.
- Builds a delivery payload containing recipient, subject, HTML body, text
  body, tracking token and other legacy IDs.
- Calls the existing `HENVALT_DELIVERY` subworkflow synchronously.

This is the old copy pipeline. Its current node data includes customer first name, product details, previous message bodies, recipient reference and destination URL in n8n execution items. The actual n8n execution-retention/redaction configuration was not verified during this read-only graph inspection; this is a privacy review item before launch. Do not broaden retention or copy these fields into V2 execution data. It must not be adapted by simply changing its HTTP URL: the V2 contract intentionally removes recipient and message body from n8n execution data. The V2 Recovery graph should be simplified to
candidate discovery/promotion/materialization, exact-store work claim, and
synchronous subworkflow handoff. The old AI renderer, legacy message queue,
legacy delivery request and recipient-bearing payload must be bypassed for
V2 work.

### Active HENVALT_DELIVERY

The current graph has an Execute Workflow Trigger and a separate internal
webhook. Its legacy delivery path authorizes/contextualizes a legacy delivery
request, calls the old
`https://.../functions/v1/henvalt-mailersend-delivery` endpoint, and records
the legacy delivery result. Its tracking and unsubscribe webhooks also use
legacy HENVALT token/RPC paths.

The current MailerSend event route is:
1. n8n webhook `henvalt/mailersend/events` receives raw-body data;
2. `Verify MailerSend Signature` calls the legacy
   `verify_mailersend_webhook_signature_api` RPC;
3. `Process MailerSend Event` calls legacy
   `process_mailersend_webhook_event`.

The V2 signed event processor is a separate Supabase Edge Function:
`henvalt-mailersend-webhook-v2`. A V2 MailerSend event must be routed to that
function directly with the untouched raw request body and provider signature,
or through one explicitly tested raw-body-preserving adapter. It must not be
processed by both the legacy n8n route and V2 function.

### Explicit send interlock

Both candidate V2 delivery Edge Functions now require the server-only
environment variable `HENVALT_V2_MAILERSEND_EVENTS_READY=true`. If it is
absent or false, they return 503 before message-context resolution, permit
issue or provider submission.

The Edge Functions also query the MailerSend Domains and Webhooks APIs on each attempted delivery. They require the exact verified sender domain, enabled HTML/plain unsubscribe insertion, and an enabled version-2 webhook at `SUPABASE_URL/functions/v1/henvalt-mailersend-webhook-v2/{provider_account_key}` with all eight V2 reconciliation/suppression events. Set this flag only after the provider's signed event URL has been verified end-to-end and the old n8n event route is no longer processing those same events. Dynamic API checks verify the configured V2 route; the flag remains an explicit operator attestation that the legacy duplicate route is disabled.

### Safe three-workflow destination graph

- `HENVALT_INGEST` remains the existing ingress workflow only for legacy
  responsibilities that are not duplicated by the V2 Worker/Edge path.
- `HENVALT_RECOVERY` performs V2 discovery, materialization and claim; passes
  only work type, opaque IDs, exact connection/tenant IDs and lease ID into
  the existing Delivery subworkflow.
- `HENVALT_DELIVERY` branches by work type and sends only
  `{"intervention_id":"..."}` or `{"opportunity_id":"..."}` to the
  matching V2 Edge Function. It returns a bounded status to Recovery.
- The MailerSend signed event webhook points directly to
  `henvalt-mailersend-webhook-v2`; it is not a fourth n8n workflow.

The V2 ingress also supports MailerSend's fixed-secret `webhook.test` URL-validation ping through migration 046, without persisting a fake provider event. Normal provider events still use the account-specific signing secret. The active graph remains unchanged. These findings are a cutover specification,
not authorization to update or publish the three active workflows.


## 9. Execution-level cutover contract

The full node-by-node handoff, claim lease invariants, Edge Function payload allowlist, result classification, signed MailerSend event cutover, legacy test-send hazard, and no-send acceptance suite are maintained in [Shopify V2 n8n cutover execution contract](./shopify-v2-n8n-cutover-execution-contract-2026-11-19.md). That contract is authoritative for the next preparation work. It does not authorize live workflow changes.
