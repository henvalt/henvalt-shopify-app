# Shopify privacy export delivery and redaction safety — V2 design

**Status: preparation only. Not deployed. Not a legal determination.**

This document records the evidence checked on 2026-11-18 and the implementation boundary for the next privacy milestone. It deliberately does not create a Storage bucket, alter production data, execute a redaction, or claim a Shopify privacy request is complete.

## 1. Evidence and current boundary

### Production Supabase state observed read-only

- Project: HENVALT (ocyplckdojdubyrsxcxa).
- The production migration history contains the November 14 legacy privacy migrations, but does not contain the new V2 identity/privacy migration series being prepared in this branch.
- storage.buckets returned zero rows. There is no existing Storage bucket to use for a private privacy-export artifact.
- Production has the legacy henvalt.shopify_privacy_requests table. It stores a nullable tenant_id, shop_domain, webhook/customer/request identifiers, the webhook payload, and an inline JSON result_payload; it has no immutable Shopify connection ID or app-key binding.
- The deployed henvalt-shopify-privacy ingress uses one SHOPIFY_API_SECRET, resolves a connection by shop domain with limit=1, and calls the legacy tenant-scoped export/redaction RPCs.
- The deployed henvalt-privacy-export endpoint validates the Supabase access token with Auth and requires exactly one OWNER/ADMIN membership. It reads the inline result_payload and returns it as an attachment. It updates result_delivered_at before the response body has been transferred to the browser. That timestamp therefore means “download handler accepted/started”, not proof the merchant received or passed on the file.
- The legacy export RPC searches by customer ID OR email across the tenant, and returns broad legacy tables. The legacy redaction RPC likewise operates tenant-wide. It is not safe as the V2 exact-store implementation.
- The legacy redaction RPC deletes email suppression rows. That cannot be carried into V2 without a reviewed decision on preserving an irreversible suppression fingerprint, since deleting suppression evidence could permit future marketing sends.

### Branch V2 state

- Migrations 021–023 preserve requested/redacted Shopify order IDs, report exact-store order-identity matches, and provide a read-only 30-day deadline monitor.
- Migration 022 explicitly returns export_data_complete=false, requires_manual_review=true, and redaction preview safe_to_execute=false. It is an identity/scope report, not a complete Shopify data export or a deletion executor.
- The V2 privacy webhook Edge Function in the branch only verifies and durably records the webhook; its HTTP 200 means “received”, not “exported/deleted”.
- These V2 migrations and source changes remain unmerged and unapplied to production.

## 2. Export delivery design

### Artifact lifecycle

1. **Receive** — verify the raw Shopify webhook HMAC and exact app/store route. Persist the receipt idempotently. Do not put customer email, phone, order IDs, or export content in the HTTP response or logs.
2. **Claim** — a service-only worker claims the exact receipt with a short lease and a single-use claim token. Recheck receipt → tenant → immutable connection → app key → shop domain at every privileged step.
3. **Build** — produce a versioned export from the V2 exact-store identity graph. Include every requested order ID in the manifest. For each ID, report whether a corresponding exact-store customer/order identity is present. An identity match is not proof that the requested Shopify data fields are complete.
4. **Completeness gate** — do not call the export complete if any requested order ID is unmatched, the customer identity is unresolved, the export omits data HENVALT actually stores, or the request contains an identifier form the system cannot safely resolve. Shopify notes that some customer records can arrive with only an email address; an ID-only V2 resolver must fail closed and route that case to review.
5. **Store** — once the artifact is complete enough for merchant review, write it to a **private** bucket using a generated, non-identifying object key. Store only object metadata (bucket/key, digest, byte count, content type, creation/expiry times, receipt/tenant/connection IDs) in a service-only artifact manifest. Never use a public bucket, customer email, Shopify ID, or request ID as the object key.
6. **Merchant access** — authenticate the current Supabase user with Auth, then verify a current OWNER/ADMIN membership and the exact tenant/receipt binding server-side. Do not trust decoded JWT claims or client-supplied tenant IDs. A merchant must be able to see which shop/request the artifact belongs to before downloading.
7. **Deliver the bytes** — preferred first implementation is an authenticated Edge Function proxy: revalidate user and membership on each request, check artifact expiry and request state, fetch the object server-side, and stream it with Content-Disposition: attachment, Cache-Control: no-store, and X-Content-Type-Options: nosniff. Do not return a public URL or put a service-role key in the browser.
8. **Audit honestly** — record separate events for artifact generated, download authorized, download stream started/served, and merchant confirmation that they have provided the export to the data subject. A server cannot prove that a browser completed the download or that a merchant forwarded it. Do not set a generic delivered flag before sending the response body; do not equate “download served” with “provided to the data subject”.
9. **Expire and purge** — enforce a short, explicit artifact retention window; delete the Storage object and clear artifact metadata on expiry. Purging must be a real scheduled/operational process, not merely a cleanup call opportunistically triggered by the next webhook or page visit. Preserve a minimal non-PII audit receipt after the artifact is removed.

### Why not hand out signed URLs by default?

Supabase supports private buckets and time-limited signed URLs. However, current Storage documentation says individual signed URLs cannot be revoked; deleting/moving/renaming the object is the per-object invalidation path. Supabase also documents CDN behavior where cached responses can outlive token expiry until cache expiry, and recommends deleting the object when access must be cut off. For a sensitive customer export, an authenticated proxy is the safer initial control because it rechecks membership and request state on each download instead of creating a bearer URL that remains usable until expiry/cache invalidation. If signed URLs are ever chosen, this limitation must be explicitly accepted and the object must be deleted at purge time.

## 3. Export content and Shopify completeness

The current V2 SQL export is a HENVALT data inventory: customer/session identity references, pixel event facts, checkout/recovery lifecycle facts, consent evidence, send/provider events, order/refund identity facts, attributions, and fee measurements. It does **not** prove that HENVALT has a full copy of Shopify's requested customer/order data, and it does not fetch the requested Shopify order records from the Admin API.

Before marking a request complete, the implementation must:

- enumerate the exact fields HENVALT stores for the customer and for each orders_requested[] entry;
- compare the export manifest against the full requested ID list, not just the subset that happens to match existing HENVALT order rows;
- identify any requested data that HENVALT never stored and provide an explicit “not held by HENVALT” explanation for merchant review rather than fabricating data;
- decide whether the merchant must retrieve the missing order/customer data from Shopify Admin, and make that step explicit in the merchant workflow;
- handle email-only payloads through a separately reviewed exact-store matching process. Do not silently use tenant-wide email matching as a fallback.

Until those gates pass, the export must remain review-required and must not be represented as a complete response.

## 4. Retention-safe customer redaction design

A redaction executor must not be built until the following are reviewed and approved:

- the exact-store foreign-key dependency graph for all V2 and legacy rows;
- which customer-linked PII fields are erased, anonymized, or retained;
- retention duties for financial/fee measurements, tax/accounting evidence, send attempts, provider delivery evidence, abuse prevention, and security/audit records in each launch jurisdiction;
- whether an irreversible, keyed recipient fingerprint is retained to preserve unsubscribe/suppression behavior after customer identity deletion, including key rotation and access restrictions;
- safe detachment of provider events, delivery cost reservations, refunds, order attribution, and billing measurements from customer identity without corrupting the financial ledger;
- treatment of legacy rows that lack an immutable Shopify connection ID. They must remain unresolved/manual review; never infer a store from tenant membership or unverified webhook metadata.

The executor must first stop future sends for the exact customer/store, revoke outstanding permits, cancel queued interventions, and fence concurrent send authorization. It must then apply the approved field-level plan in one idempotent transaction or a durable multi-step state machine with explicit retry/review states. It must preserve required financial/audit facts while removing customer PII, and produce a postcondition report. “RPC returned matched” is not sufficient evidence of completed redaction.

The current V2 preview correctly keeps safe_to_execute=false and lists blockers for legacy rows, retention policy, suppression retention, cost-ledger detachment, and provider-audit FK detachment. Keep those blockers until the relevant design and tests exist.

## 5. Required data model before implementation

Proposed service-only records (names are illustrative; do not treat them as committed schema):

- **Export artifact manifest**: receipt ID, tenant ID, immutable connection ID, artifact version, private bucket/object key, SHA-256 digest, byte count, content type, completeness status, generated/expiry/purged timestamps, and generation attempt ID.
- **Privacy delivery audit**: receipt ID, actor user ID where applicable, event type, timestamp, request correlation ID, and non-PII outcome code. No signed URL, raw payload, customer email, phone, or export body.
- **Merchant completion attestation**: receipt ID, authenticated owner/admin actor, attested action (e.g. “provided to data subject”), timestamp, and explicit statement of what was/was not included. This is separate from webhook acknowledgement and file download.
- **Deletion plan/execution record**: receipt ID, exact connection ID, policy version, planned record counts, completed record counts, preserved-retention categories, unresolved legacy counts, attempt/lease state, and a final postcondition result.

All tables must have RLS enabled, no browser-facing write path, and service-role-only privileges unless a narrowly scoped merchant read policy is explicitly justified. Storage objects must remain private. Avoid SECURITY DEFINER functions in exposed schemas; any privileged function must live in the private henvalt schema, pin search_path, revoke PUBLIC/anon/authenticated execution, and receive a specific adversarial SQL test.

## 6. Acceptance tests required before release

- A tenant owner can list only requests for their own tenant; a different tenant, non-member, stale session, and non-owner cannot retrieve or download an artifact.
- A tenant with multiple stores can only access the selected receipt's exact connection lineage; same-tenant cross-store order IDs and customer IDs never appear.
- A request whose orders_requested[] contains unmatched IDs remains incomplete and review-required.
- An email-only customer payload cannot be guessed into a customer identity.
- Duplicate webhook, duplicate worker claim, expired lease, stale claim token, regenerated artifact, expired artifact, and concurrent download cases are idempotent and auditable.
- An artifact is not publicly accessible and cannot be retrieved by guessing its object key.
- A failed or interrupted HTTP response does not create a false “delivered to data subject” status.
- Artifact expiry actually deletes the object; the deadline monitor surfaces purge failures.
- Redaction cannot run until retention policy is approved and all legacy/unbound rows are resolved or explicitly excluded under a reviewed policy.
- Concurrent redaction and delivery authorization cannot result in a post-redaction send.
- Financial ledger, refunds, provider/cost audit references, and approved suppression evidence remain internally consistent after redaction.

## 7. Release decision

**Not launch-ready.** The production legacy privacy path is tenant-scoped and inline-payload based; the new V2 exact-store path is not deployed; there is no production Storage bucket; and the current download audit does not prove completed delivery. Keep the V2 branch unmerged and production untouched until the design, schema, worker, merchant UI, deletion policy, and end-to-end tests are complete.

## References

- Shopify mandatory privacy webhooks and 30-day completion requirement: https://shopify.dev/docs/apps/build/compliance/privacy-law-compliance
- Supabase private bucket access model: https://supabase.com/docs/guides/storage/buckets/fundamentals
- Supabase signed URL creation: https://supabase.com/docs/reference/javascript/file-buckets-createsignedurl
- Supabase signed URL revocation and Storage CDN behavior: https://supabase.com/docs/guides/storage/security/signing-keys and https://supabase.com/docs/guides/storage/cdn/smart-cdn
