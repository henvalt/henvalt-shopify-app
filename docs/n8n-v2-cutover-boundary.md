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

## 4. Cutover gates

Do not edit or publish the active workflows until each gate is satisfied:

- [ ] V2 service-only claim/lease contract exists for each due-work type and is covered by exact-store, stale-lease, duplicate-claim and tenant-isolation tests.
- [ ] A documented mapping exists from V2 opportunity/candidate → claim → intervention/permit → Edge Function → provider outcome → provider-event reconciliation.
- [ ] Checkout and pixel delivery use their distinct V2 permit paths; no fabricated checkout identity is introduced for cart/browse.
- [ ] n8n payloads contain opaque IDs and correlation IDs only; no raw recipient email, secrets, tokens or customer payloads.
- [ ] A no-send dry-run test proves that an ineligible, suppressed, unconsented, inactive or over-budget record cannot reach MailerSend.
- [ ] Duplicate execution, timeout, stale worker, provider acceptance ambiguity and webhook retry tests prove idempotency without automatic duplicate sends.
- [ ] A disposable end-to-end test proves a signed Shopify order webhook can be projected and attributed to a prior eligible V2 touch; refunds then update the dashboard totals.
- [ ] Existing legacy workflows are compared against the V2 branch contract and a rollback plan is documented.
- [ ] The owner explicitly approves any production workflow update, activation or real provider send.

## 5. Current release boundary

The repository candidate now contains migrations 039–041, pixel attribution, exact-store V2 dashboard read model and merchant store selection. Current-head GitHub validation passed on 18 November 2026. These are not deployed to the active Supabase project.

The active n8n workflows remain unchanged and continue to reference legacy functions. That means the new V2 database lifecycle and dashboard are validated as candidate code, but **the live n8n runtime is not yet connected to the V2 lifecycle**. This is a launch blocker, not a reason to mutate the active workflows prematurely.

No n8n workflow execution was triggered during this inspection. No active workflow was changed, disabled, published or unpublished. No customer email, provider call, billing action or production data mutation occurred.
