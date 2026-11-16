# Exact-Store Privacy, Consent and Recovery Isolation Remediation Plan

**Status:** design/preparation only; not implemented or approved for production.
**Inspection date:** 2026-11-16
**Target branch:** `prep/public-app-hardening-2026-11-15`
**Scope:** safely support independent Shopify stores under one HENVALT tenant without cross-store recovery, consent, privacy, attribution, or reporting effects.

## 1. Executive decision

A tenant is an account/billing container, not a Shopify store identity. A Shopify customer ID, email, checkout ID, cart token, session ID, or shop-domain string in mutable metadata is not sufficient by itself to prove which connected store owns a record.

The durable identity for store-scoped operations must be the immutable internal `shopify_connections.id` (referred to below as `shopify_connection_id`), resolved from a trusted, verified Shopify app identity + shop domain. The app identity must also be retained where multiple Shopify apps can connect to the same HENVALT backend.

**Fail-closed rule:** if the source record cannot be tied to exactly one connection, or if any linked record conflicts with that connection, do not send, suppress, attribute, redact, or bill based on a guessed store. Quarantine the operation for reconciliation and preserve an auditable outcome.

Do not silently backfill legacy rows from customer email, Shopify customer ID, checkout token, session, or unverified metadata. Historical ambiguity is a data-reconciliation problem, not permission to infer ownership.

## 2. Confirmed production hazards

Read-only inspection of deployed Supabase function bodies (documented in `recovery-delivery-privacy-function-body-audit.md` and `secondary-function-lineage-audit.md`) found:

- Cart and browse candidate discovery can join a tenant's events/customers to multiple active store connections.
- Checkout candidate discovery uses shop-domain metadata for part of the join, but downstream order/conversion checks remain tenant/customer scoped.
- Recovery worker context and sequence scheduling can treat an order or checkout in another store as conversion/advancement.
- Delivery authorization does not enforce one same-store connection across the complete request → intervention → sequence → opportunity → customer → checkout/source-event lineage.
- Unsubscribe and inbound OPT_OUT paths apply tenant-wide consent/suppression by default.
- Shopify customer privacy redaction selects records using tenant + Shopify customer ID/email without an exact connection predicate.
- Shop redaction currently deletes the tenant, although the request concerns one Shopify shop.
- Store-addressed billing/revenue endpoints resolve a shop to a tenant and then aggregate tenant-wide rows.

These are commercial and privacy blockers for multi-store operation. The current production behavior must not be described as store-isolated.

## 3. Canonical store identity and lineage model

### 3.1 Trusted connection resolution

At ingress, verify Shopify HMAC against the secret belonging to the registered app identity. Resolve the normalized `*.myshopify.com` shop domain to exactly one connection using trusted server-side state and app key. Do not trust caller-supplied tenant IDs, connection IDs, app keys, or shop identity headers.

Persist the resolved `shopify_connection_id` (and app key where applicable) at the earliest durable event boundary. For each new record, derive tenant ID from that connection rather than accepting an independent tenant value.

### 3.2 Propagation targets

Add a nullable connection reference first, then make it required for new store-originated records after backfill/reconciliation and staged enforcement. The lineage should cover at minimum:

- raw webhook/provider event and canonical event;
- pixel event/session and cart snapshot;
- customer identity (store-scoped Shopify customer mapping);
- checkout/cart snapshot;
- opportunity and recovery sequence;
- intervention and delivery request/attempt;
- order and order attribution;
- conversation and inbound/outbound message;
- unsubscribe token and consent/suppression event;
- privacy request and compliance processing receipt;
- revenue ledger and email usage measurement where store-level reporting is required.

Keep tenant IDs for tenant authorization and aggregation, but enforce that every store-scoped row's tenant matches its referenced connection's tenant. Where a table represents a shared tenant-level object (for example, shared provider credentials), do not falsely assign it to a store; instead record the selected store sender/profile or explicit tenant-level policy at the delivery boundary.

### 3.3 Database constraints

Candidate migration design, subject to schema-specific review:

1. Add nullable `shopify_connection_id` FKs to relevant store-originated tables.
2. Add a unique key on `shopify_connections(tenant_id, id)` if not already present, then composite FKs `(tenant_id, shopify_connection_id) → shopify_connections(tenant_id, id)` to prevent cross-tenant connection references.
3. Add indexes beginning with `shopify_connection_id` for candidate discovery, suppression, privacy, attribution, and reporting paths.
4. Add store-scoped unique constraints only after duplicate/ambiguity preflight. Examples: customer mapping by (connection, Shopify customer ID); checkout mapping by (connection, Shopify checkout ID); order mapping by (connection, Shopify order ID).
5. Preserve existing tenant-level uniqueness only where it represents a genuine tenant-wide invariant. Do not remove constraints blindly; perform duplicate and collision analysis first.
6. Use staged `NOT VALID` foreign keys and validate only after historical rows are resolved. A nullable column is a transition mechanism, not proof that legacy NULL rows are safe.

Do not add cascading deletes from a Shopify connection to business records. Store deletion must follow a reviewed retention/redaction policy, not an accidental FK cascade.

## 4. Consent and unsubscribe contract

### 4.1 Default scope

Shopify consent and an unsubscribe token generated from a store-specific recovery must be scoped to the originating `shopify_connection_id` by default. A tenant-wide suppression may be offered only as an explicit merchant policy, recorded with actor, timestamp, scope, and source. Do not infer tenant-wide consent from an email match.

### 4.2 Token lifecycle

A new unsubscribe token must bind to immutable lineage: tenant, connection, customer mapping, intervention/delivery, token hash, created/expiry timestamps, and used state. Store only a cryptographic hash of the token. Validation must check expiry and one-time use and return the trusted scope from the stored record, never from query parameters.

The unsubscribe handler must atomically:
- claim/consume a valid token once;
- update consent for the store-scoped customer mapping;
- create a suppression keyed by connection + customer/email according to the policy;
- stop only that connection's eligible recoveries and pending deliveries;
- append an audit/compliance receipt.

If the historical token has no unambiguous connection lineage, do not broaden it to tenant-wide suppression automatically. Route it through a safe legacy policy/reconciliation path and record the decision.

### 4.3 Shopify consent webhooks and inbound replies

Resolve Shopify consent webhooks to the exact verified connection before applying changes. Shopify customer IDs are store-local; never use tenant + customer ID alone.

For MailerSend inbound replies, persist connection lineage on the conversation when created from a recovery. Resolve inbound replies through the opaque reply-token hash to that exact conversation and connection. An OPT_OUT reply suppresses the originating store by default. If a tenant-wide opt-out option is supported, require an explicit policy setting and auditable scope decision.

## 5. Privacy request contract

### 5.1 Durable request intake

For each Shopify privacy topic, verify HMAC using the correct app secret and persist an idempotent compliance request with:
- topic and Shopify request/event identifier;
- verified app key and normalized shop domain;
- resolved connection ID, if one exists;
- received timestamp and payload hash;
- processing status, attempt count, and completion receipt.

Duplicate deliveries must return the existing request outcome. An uninstalled or never-linked shop may have no current active connection; retain a durable unresolved request and resolve against a verified historical connection/app identity where possible. Never guess a tenant from email or customer ID.

### 5.2 Customer data request

Export only records tied to the resolved store connection and the store's Shopify customer identity. Clearly separate shared tenant/account data from store-owned data; do not disclose another store's records. If lineage is incomplete, report/queue the ambiguity rather than expanding the export to the tenant.

### 5.3 Customer redaction

Redaction must operate on an explicit connection + Shopify customer ID scope. Email can assist discovery but cannot define the deletion scope. Build a preflight manifest of candidate row counts/IDs by table and connection before mutation. Apply the approved data-minimization/retention policy, preserve legally required compliance receipts/audit facts, and ensure another store's records remain intact.

### 5.4 Shop redaction

A shop redaction must not delete the HENVALT tenant. It must:
- resolve the exact historical/current connection and app identity;
- disable that connection and revoke its Shopify credentials/tokens;
- stop its pending deliveries and recovery jobs;
- redact/delete that store's data according to the approved retention schedule;
- remove or anonymize store-specific configuration and identifiers;
- preserve other stores, tenant membership, shared provider configuration, billing/account records, and compliance receipts where retention is required;
- produce an idempotent completion receipt.

If the shop cannot be resolved unambiguously, keep the request unresolved and escalate; do not run tenant-wide deletion.

## 6. Recovery, delivery and attribution enforcement

Every candidate and worker path must derive one connection from immutable source lineage. Require the same connection for:

- source event/pixel event and cart/checkout;
- customer mapping;
- opportunity and sequence;
- intervention, delivery request, delivery attempt;
- order and attribution.

Conversion/advancement checks must include the same connection. A Store B order must not stop a Store A recovery, even when customer IDs, emails, cart tokens, or session-like values collide.

Before delivery claim/send, authorize the complete lineage and verify the connection is active and belongs to the same tenant. Deny missing, inactive, ambiguous, or conflicting lineage. The delivery provider may remain tenant-configured, but sender identity, branding, reply routing, and unsubscribe URL must be selected under an explicit per-store/tenant policy.

Attribution and performance fees must require confirmed order-to-opportunity linkage on the same connection. POSSIBLE/customer-only matches remain non-billable. Store revenue summaries must filter by exact connection; tenant-level billing, if selected, must be explicitly labelled tenant-wide and aggregate only valid same-store attributed rows.

## 7. Safe implementation sequence

No production DDL or function replacement is authorized by this plan. Proposed order:

**Stage A — read-only inventory and preflight**
- Enumerate every store-originated table, function, trigger, view, RPC, RLS policy, and unique index.
- Measure NULL/missing/conflicting connection lineage and cross-store duplicate IDs.
- Build read-only reports for candidate backfill confidence; do not mutate records.
- Define retention rules and choose tenant/store/hybrid billing principal.

**Stage B — additive schema**
- Add nullable connection references, composite tenant+connection FKs, indexes, and privacy request lineage fields.
- Keep old RPC signatures available while adding versioned store-aware RPCs.
- Do not backfill ambiguous rows automatically.

**Stage C — dual-write and trusted backfill**
- New verified webhook/OAuth/pixel paths write connection IDs.
- Backfill only rows with deterministic, independently verified source lineage.
- Quarantine uncertain rows; preserve evidence and audit reason.

**Stage D — versioned store-aware functions**
- Implement v2 candidate discovery, worker context, delivery authorization, sequence scheduling, consent, unsubscribe, privacy, attribution, and reporting functions.
- Add same-store regression tests before routing any traffic.
- Ensure RLS and service-role grants preserve least privilege.

**Stage E — shadow comparison**
- Run old and new candidate/report logic read-only and compare results.
- Investigate every mismatch; do not send from shadow results.
- Verify Store A/B isolation and legacy single-store parity.

**Stage F — controlled cutover**
- Requires separate explicit approval, backup/rollback plan, tested idempotency, and operational monitoring.
- Enable store-aware path for a controlled test tenant first.
- Retain a rollback path; do not drop old columns/functions until all callers are migrated and retention obligations are met.

## 8. Mandatory regression matrix

Use two independent stores A and B under the same tenant, deliberately reusing customer email, Shopify customer ID, cart token, session reference, checkout/order identifiers wherever the platform/test harness permits.

1. A cart candidate is never joined to B's connection.
2. B checkout/order never suppresses A cart recovery.
3. B pixel event never advances/suppresses A browse recovery.
4. B order never stops A sequence.
5. Delivery request with A opportunity + B customer/checkout is denied.
6. Any inactive or conflicting connection in lineage denies delivery.
7. A unsubscribe token suppresses A only under default policy.
8. A Shopify consent webhook updates A's customer mapping only.
9. A inbound OPT_OUT reply suppresses A only under default policy.
10. Expired, used, malformed, or cross-store token is rejected.
11. A customer redaction leaves B's same-ID/email records untouched.
12. A shop redaction leaves B, tenant membership, shared provider config and tenant account intact.
13. Unlinked/uninstalled shop privacy request is durably queued and never guessed to a tenant.
14. A store revenue series contains only A's confirmed attributed revenue.
15. Tenant-level billing, if chosen, is labelled tenant-wide and counts each confirmed recovery exactly once.
16. POSSIBLE/customer-only attribution never produces a performance fee.
17. Duplicate privacy/webhook delivery is idempotent and preserves a completion receipt.
18. Legacy rows with NULL or ambiguous connection lineage fail closed or follow an explicitly reviewed compatibility policy; no silent default-store fallback.

## 9. Release gates and explicit non-actions

Before any public multi-store release:
- all regression cases pass;
- privacy topic HMAC and app identity routing are verified for each app;
- store-scoped RLS and RPC authorization are independently reviewed;
- privacy retention/deletion behavior is approved;
- billing principal and dashboard scope are explicit;
- shadow comparison has no unexplained mismatches;
- rollback and incident procedures are documented.

**This document changes no live system.** No Supabase migration or function was applied, no active n8n workflow was changed, no Cloudflare Worker or Edge Function was deployed, no Shopify app was created or released, and no PR was merged. Any implementation or cutover beyond branch-only preparation requires separate explicit authorization.
