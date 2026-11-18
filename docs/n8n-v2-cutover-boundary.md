# HENVALT V2 runtime cutover boundary — n8n

**Status:** read-only architecture checkpoint, 18 November 2026. The three production workflows were inspected but not executed, edited, unpublished or republished. No production Supabase or Shopify changes were made.

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

## 4. Existing V2 delivery Edge Function contracts

The branch already has two distinct server-side delivery boundaries:

- Checkout recovery: `henvalt-shopify-contact-delivery-v2` accepts an opaque `intervention_id` plus `subject`, `html` and/or `text`. It resolves the exact-store checkout intervention, refreshes Shopify customer consent, issues and consumes the checkout permit, rechecks recipient identity, reserves provider cost, and submits to MailerSend.
- Cart/browse pixel recovery: `henvalt-shopify-pixel-delivery-v2` accepts an opaque `opportunity_id` plus `subject`, `html` and/or `text`. It resolves the exact-store pixel context, refreshes Shopify consent/contact evidence, issues and consumes a pixel-specific permit, rechecks recipient identity, reserves provider cost, and submits to MailerSend.

Both require the server-held delivery bearer secret. Neither accepts a recipient email from n8n, and both keep the raw recipient email inside the trusted Edge Function/provider request. Both record SUBMITTED/FAILED/AMBIGUOUS outcomes internally; n8n must not call the legacy result RPC afterward. The V2 signed MailerSend webhook Edge Function owns provider-event correlation, suppression and ambiguous-attempt reconciliation.

The V2 claim/lease adapter now exists in migration 042 and is covered by disposable PostgreSQL tests for both checkout intervention and pixel opportunity work, concurrent claim exclusion, deferred retry with a fresh lease identity, stale-worker rejection and terminal completion. The active Recovery workflow is still not wired to it; production cutover remains pending.

## 5. V2 claim/lease RPC contract — migration 042

The branch now contains `202611180042_shopify_recovery_work_claims_v2.sql`. It introduces a shared exact-store queue without merging the two delivery models.

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

The response contains opaque IDs only:
- `CHECKOUT_INTERVENTION`: `work_id` and `intervention_id` are the same intervention UUID; `opportunity_id` is its exact-store opportunity.
- `PIXEL_OPPORTUNITY`: `work_id` and `opportunity_id` are the same pixel opportunity UUID; `intervention_id` is null.

Each item also contains `lease_id`, tenant ID, immutable Shopify connection ID, opportunity type, expiry and attempt count. It contains no recipient email, Shopify token, provider secret, message body or send authority. The queue filters inactive stores/apps/tenants, same-store conversions, existing attempts, non-due work and ineligible source states. The claim write is atomic under the unique (work type, work ID) key, so concurrent workers cannot own the same active lease.

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

### HENVALT_RECOVERY routing

For each claim item:
1. `CHECKOUT_INTERVENTION` → call `henvalt-shopify-contact-delivery-v2` with `intervention_id`, `subject`, `html` and/or `text`. The Edge Function itself performs contact resolution, fresh consent checks, checkout permit issue/consume, cost reservation and provider submission.
2. `PIXEL_OPPORTUNITY` → call `henvalt-shopify-pixel-delivery-v2` with `opportunity_id`, `subject`, `html` and/or `text`. It uses the separate pixel context, eligibility assessment, pixel permit, final Shopify consent lookup and provider submission gate.
3. A 202 response with `submitted`, `ambiguous_provider_submission` or `provider_accepted_record_pending` means the server-side attempt lifecycle owns the outcome; do not resend or create another attempt. Finish the lease as `HANDOFF_ACCEPTED`.
4. A 409 eligibility/consent/suppression/order response is a review outcome. Use `DEFERRED` for conditions that can change (for example, fresh evidence or a jurisdiction policy review); use `TERMINAL` for permanently closed, converted or revoked records.
5. A 5xx before provider submission can be deferred. If provider submission may have started, the Edge Function marks the attempt AMBIGUOUS and retains its cost reservation; do not manually release it or create a second send. Let the signed MailerSend webhook reconciler resolve it.
6. Never pass raw email or Shopify/provider credentials between n8n nodes. Keep message content limited to the requested subject/body and avoid logging complete HTTP request/response bodies.

The `HENVALT_INGEST` workflow remains outside this claim queue: verified Shopify webhooks are ingested by the Worker/Edge Function boundary, not duplicated through legacy n8n ingestion. `HENVALT_DELIVERY` is not yet cut over; first validate the worker's V2 handoff in a disabled/dry-run workflow copy and then explicitly approve a production update. The current active workflows remain unchanged.

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


## 8. Migration 042 validation

The V2 work-claim contract is implemented and passed current-head CI run #935 on 18 November 2026:
- migration 042 applies after migrations 001–041 on disposable PostgreSQL;
- a pixel opportunity is claimed with exact tenant/store lineage and no intervention/checkout identity;
- a second worker cannot claim an active lease;
- deferred work is reclaimed under a new lease UUID;
- the stale worker cannot finish the reclaimed lease;
- a current worker can complete it, after which it is no longer claimable;
- a checkout intervention is independently claimable with its own intervention/opportunity lineage;
- no recipient email, provider credentials, Shopify token or message body enters the claim response.

GitHub's connected Cloudflare Pages integration also produced successful **preview** builds for the preparation branch. The deployment records identify environment `preview`, branch `prep/public-app-hardening-2026-11-15`, and production branch `main`; they did not deploy this branch to the production environment.

## 9. Current release boundary

The repository candidate now contains migrations 039–041, pixel attribution, exact-store V2 dashboard read model and merchant store selection. Current-head GitHub validation passed on 18 November 2026. These are not deployed to the active Supabase project.

The active n8n workflows remain unchanged and continue to reference legacy functions. That means the new V2 database lifecycle and dashboard are validated as candidate code, but **the live n8n runtime is not yet connected to the V2 lifecycle**. This is a launch blocker, not a reason to mutate the active workflows prematurely.

No n8n workflow execution was triggered during this inspection. No active workflow was changed, disabled, published or unpublished. No customer email, provider call, billing action or production data mutation occurred.
