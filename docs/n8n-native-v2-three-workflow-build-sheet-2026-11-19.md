# HENVALT three-workflow V2 native n8n build sheet

Status: implementation specification only. It is not an imported workflow, does not change active workflow versions, and does not authorize activation. Preserve exactly three production workflows.

## Topology and ownership

| Workflow | V2 responsibility | Must not do |
|---|---|---|
| `HENVALT_INGEST` | Keep legacy routes isolated during migration; V2 Shopify webhooks are received by Cloudflare Worker → protected Supabase Edge Function → Vault-backed verified inbox/projection | Must not receive the same V2 Shopify callback or duplicate-write the V2 event into legacy canonical/recovery tables |
| `HENVALT_RECOVERY` | Schedule candidate refresh/promotion, checkout intervention materialization, atomic work claim, invoke Delivery synchronously, finish the lease | Must not render messages, resolve recipients, call MailerSend, or finish the lease before Delivery returns |
| `HENVALT_DELIVERY` | Receive one opaque claim, validate, route to the correct V2 Edge Function, return sanitized classification | Must not call legacy send RPCs, create message bodies/tokens, call MailerSend directly, or finish Recovery's lease |

The current live workflows are still legacy and must remain untouched until a separately reviewed cutover. Do not import this build sheet as a fourth workflow.

## HENVALT_RECOVERY — candidate node sequence

1. **Schedule Trigger** — every 1 minute. Use one execution-scoped worker ID such as `henvalt_recovery_v2:<execution-id>` (3–80 safe characters). Do not use a constant shared worker ID.
2. **HTTP Request — Refresh Checkout Candidates** — service-role Supabase credential; POST `/rest/v1/rpc/refresh_shopify_checkout_recovery_candidates_v2`; JSON `{p_minimum_inactive_for:"30 minutes",p_limit:100}`.
3. **HTTP Request — Promote Checkout Candidates** — `promote_shopify_checkout_recovery_candidates_v2`; `{p_limit:100}`.
4. **HTTP Request — Refresh Pixel Candidates** — `refresh_shopify_pixel_recovery_candidates_v2`; `{p_inactivity_for:"60 minutes",p_max_age:"24 hours",p_limit:200}`.
5. **HTTP Request — Promote Pixel Candidates** — `promote_shopify_pixel_recovery_candidates_v2`; `{p_limit:200}`.
6. **HTTP Request — Materialize Checkout Interventions** — `materialize_shopify_checkout_interventions_v2`; `{p_limit:100}`.
7. **IF/Code — Stage Accepted?** — every stage must return JSON `accepted:true`. Stop before claim if any stage rejects, returns malformed data, or times out. Do not continue after a failed discovery stage.
8. **HTTP Request — Claim V2 Recovery Work** — `claim_shopify_recovery_work_v2`; `{p_worker_id,p_limit:25,p_lease_seconds:180}`. The database response must contain only `lease_id`, `work_type`, `work_id` per item; its `claimed` count must equal the item-array length. The migration now enforces this minimal response.
9. **Split Out / Loop Over Items** — validate UUIDs and enum. Construct correlation ID `v2:<work_id>`. Build a new object containing exactly `work_type`, `work_id`, `lease_id`, `worker_id`, `correlation_id`; never pass the original claim item onward.
10. **Execute Workflow — HENVALT_DELIVERY** — synchronous subworkflow call, wait for completion. Pass only the five allowlisted fields. Its error output, unknown outcome, or invalid retry policy must be caught and mapped to a sanitized `DEFERRED` result with a 3600-second retry; never log the raw exception. This is necessary because the Edge Function may have submitted even if the subworkflow response was lost.
11. **Code/IF — Validate Delivery Result** — accept only `HANDOFF_ACCEPTED`, `TERMINAL`, or `DEFERRED`; retry interval must be an integer 0–86400 seconds. No provider body or raw exception text in result.
12. **HTTP Request — Finish V2 Work Claim** — service-role Supabase credential; POST `/rest/v1/rpc/finish_shopify_recovery_work_claim_v2`; body `{p_lease_id,p_worker_id,p_outcome,p_retry_after:"<seconds> seconds"}`. Require response `finished:true` **and** an `outcome` exactly equal to the requested outcome; missing/mismatched acknowledgements, false/stale leases are operational alerts, not success.

The Recovery workflow owns the lease because it owns the claim. Delivery only returns a classified outcome. A 202 accepted ambiguous/pending response is `HANDOFF_ACCEPTED`, not `DEFERRED`: the Edge Function already crossed the provider boundary and its send-attempt ledger/signed webhook reconciler own the outcome. A network timeout between Recovery and Delivery may be deferred; the Edge Function's existing-attempt guard prevents a duplicate provider submission if it did process the request.

## HENVALT_DELIVERY — candidate node sequence

1. **Execute Workflow Trigger** — accept the five-field payload only.
2. **Code — Validate Opaque Claim** — validate work type, UUIDs, worker ID and correlation ID. Create a fresh body; never forward arbitrary input fields.
3. **Switch — Work Type**:
   - `CHECKOUT_INTERVENTION` → HTTP Request to `/functions/v1/henvalt-shopify-contact-delivery-v2`, body exactly `{intervention_id:work_id}`.
   - `PIXEL_OPPORTUNITY` → HTTP Request to `/functions/v1/henvalt-shopify-pixel-delivery-v2`, body exactly `{opportunity_id:work_id}`.
4. **HTTP Request — V2 Edge Handoff** — use the corresponding server-held delivery bearer credential; JSON content type; bounded timeout; no automatic retry. Capture status and response JSON only. Do not save request headers or credentials in node output.
5. **Code — Classify Handoff**:
   - 2xx + `accepted:true` + `submitted`, `accepted`, `handed_off`, `ambiguous_provider_submission`, `provider_accepted_record_pending`, or `provider_outcome_requires_reconciliation` → `HANDOFF_ACCEPTED`.
   - 502 + `accepted:false` + `error:"provider_submission_rejected"` → `TERMINAL` (Edge Function has recorded the failed provider attempt).
   - invalid-request 400/422 → `TERMINAL` only where the Edge Function contract defines the request as permanently invalid. Gateway-level 404/410 → `DEFERRED` with an operational alert: a missing/retired Edge Function route must never close every claimed opportunity as terminal.
   - 401/403, 409, 429, 5xx, timeout, malformed/unknown response → `DEFERRED` plus operational alert where appropriate.
6. **Return to Recovery** — only `work_type`, `work_id`, `outcome`, `reason_code`, `retry_after_seconds`. Never return customer/provider payloads.

Delivery must not call the legacy `henvalt-mailersend-delivery`, `authorize_delivery_request`, `record_delivery_result`, or legacy MailerSend event RPCs for V2 claims. The trusted Edge Function owns consent/contact/suppression, sender verification, cost reservation, final order checks, server-side rendering, provider submission and ambiguous reconciliation.

## HENVALT_INGEST — ingress boundary

The V2 Shopify webhook route is **not** an n8n webhook: the branch Worker forwards unchanged raw bytes to `henvalt-shopify-webhook-ingress`, which verifies the app-specific HMAC in the protected database RPC and projects exact-store checkout, consent, order and refund records. The active legacy `HENVALT_INGEST` route must not receive the same V2 callback and write the same event into legacy tables. Cut over each webhook topic deliberately; preserve legacy topics only while their V2 equivalents are not registered. No dual callback or dual write.

The V2 inbox currently has no n8n consumer requirement for the Recovery scheduler: the Edge Function projects verified source data into V2 tables directly. Keep HENVALT_INGEST's future responsibility limited to explicitly retained legacy/internal events until a separate design defines its V2 role.

## MailerSend events and legacy sender shutdown

- V2 MailerSend signed events must go directly to `henvalt-mailersend-webhook-v2` with original raw body and signature.
- Exactly one receiver must own each event stream. Do not let legacy n8n and V2 Edge Function process the same event.
- Do not disable the legacy receiver until V2 URL validation and signed event reconciliation tests pass and the provider endpoint change is approved.
- The live Delivery workflow contains a manual one-off send branch with a hard-coded historical delivery request and recipient. It was not executed. It must be reviewed and disabled/removed before launch under explicit production change approval.
- Verify n8n instance-level execution retention/redaction. Workflow-level settings inspected so far do not prove customer payloads are not saved.

## Mandatory no-send acceptance tests before any cutover

- Every candidate stage rejection/timeout stops before claim.
- Concurrent Recovery workers cannot claim the same work item.
- Claim JSON contains exactly the three opaque fields.
- Recovery→Delivery payload contains exactly five fields.
- Checkout work can reach only checkout Edge Function; pixel work only pixel Edge Function.
- All ineligible, inactive, suppressed, unsubscribed, converted, wrong-store and wrong-tenant test fixtures stop before provider submission.
- 202 submitted and 202 ambiguous both finish the lease as HANDOFF_ACCEPTED.
- Explicit provider rejection finishes TERMINAL; timeout/429/5xx unconfirmed results defer.
- Stale lease finish is rejected; deferred work gets a fresh lease ID.
- Fake fetch fails the test if any request targets MailerSend or an unapproved external host.
- Execution outputs contain no customer PII, provider tokens, Shopify tokens, message bodies or raw provider response bodies.

This build sheet is a draft specification. No workflow import, activation, live RPC, production deployment, webhook re-registration or provider send is authorized by it.
