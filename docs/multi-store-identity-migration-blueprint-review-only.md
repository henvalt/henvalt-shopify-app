# Multi-Store Identity Migration Blueprint — Review Only

**Status:** design only; not executable SQL  
**Date:** 2026-11-16  
**Target branch:** `prep/public-app-hardening-2026-11-15`  
**Production impact:** none. Do not apply, merge or deploy from this document.

## Goal

Introduce app-aware Shopify identity and exact store lineage without breaking the existing merchant-owned HENVALT app, its OAuth credentials, installations, tokens, webhooks or current single-store behavior.

The stable internal identity must be:

`app_key + shopify_connection_id`

- `app_key` identifies the HENVALT Shopify app registration (for example, the current merchant-owned legacy app and a future Partner-owned public app).
- `shopify_connection_id` identifies the exact installed Shopify store connection.
- Shopify client IDs are identifiers, not secrets. Shopify API secrets remain in secret storage and are selected only by trusted server-side app registry configuration.
- A shop domain alone is not a sufficient permanent identity because it does not distinguish app registrations and can be reused across app lifecycles.

## 0. Release boundaries and compatibility

1. Keep the existing app registration and client credentials as `legacy`; do not transfer, replace or rotate them as part of this work.
2. A future public app gets a distinct app key, client ID and secret. Do not create or pay for that registration as part of this preparation.
3. Existing records remain valid legacy records until proven backfillable.
4. New code must fail closed when app identity or store lineage is missing, conflicting or ambiguous.
5. Do not use tenant membership, email, shop domain metadata, current active-connection count, or "first matching connection" as a substitute for immutable lineage.
6. Deploy in additive, compatibility-first stages. No destructive constraint changes until all writers/readers and backfill checks are ready.

## 1. App registry and OAuth identity

Introduce a server-owned app registry with:
- immutable `app_key`;
- Shopify client ID;
- app lifecycle state (active, legacy, disabled);
- secret reference to a managed secret store;
- permitted webhook route / callback configuration;
- timestamps and audit fields.

Do not store plaintext API secrets in Postgres, Git, n8n node JSON, browser-visible configuration, or logs.

OAuth begin must:
1. select an app key from a trusted app-specific route/configuration;
2. load the matching client ID and secret reference server-side;
3. include the app key in the signed/hashed OAuth state record;
4. bind state to intended redirect, expiry, nonce and app identity.

OAuth callback must:
1. resolve state and app key before signature validation;
2. select only that app's secret;
3. verify Shopify HMAC and state/nonce/expiry;
4. finalize installation using app key + normalized shop domain;
5. persist the exact connection ID and app key;
6. reject a shop already connected to a conflicting app identity until the data model explicitly supports parallel installations.

Token refresh must resolve credentials from the stored connection's app key, not from a global secret or shop-domain-only lookup.

## 2. Trusted webhook and pixel ingress

The edge boundary must select an app identity from a trusted route such as an app-specific path or immutable route binding. Never select an app secret based on an unsigned shop header.

Required order:
1. read exact raw request body;
2. resolve app key from trusted route configuration;
3. verify HMAC with that app's secret;
4. validate topic and shop domain;
5. resolve exact connection using app key + normalized shop domain, including historical/uninstalled connection records where compliance retention requires it;
6. attach server-trusted app key and connection ID to the downstream envelope;
7. forward only after verification.

The n8n ingress workflow must not independently choose a secret from untrusted payload data. Its verifier/resolver RPC contract must accept trusted app identity and return exact connection identity.

Pixel keys already reference `shopify_connections(id)`; preserve that binding. Pixel event persistence must carry the connection ID resolved from the pixel key, not trust a client-provided tenant or shop ID.

## 3. Store lineage propagation

Add nullable `shopify_connection_id` to Shopify-originated records in a compatibility stage, beginning with source-of-truth records:

- webhook/provider event receipt;
- canonical event;
- customer;
- checkout/cart snapshot/session and session alias;
- opportunity;
- order and order adjustment source;
- recovery sequence/intervention/delivery request/delivery attempt;
- customer conversation/message and inbound provider event;
- tracking/unsubscribe token;
- attribution and revenue-ledger row;
- privacy request/export/redaction receipt.

Use composite tenant/connection integrity wherever the parent has `tenant_id`: a connection must belong to the same tenant as the child row. Where app key is also persisted, validate that the connection's app key matches it.

For derived records, copy connection identity from the immutable parent lineage; do not re-resolve it from metadata at send time. Keep an audit trail of source event and derivation.

### Store-scoped identity and uniqueness

Review and replace tenant-only uniqueness where external identifiers are scoped by Shopify store:

- customer: connection + Shopify customer ID;
- checkout: connection + Shopify checkout ID;
- checkout/cart token: connection + token;
- session and session alias: connection + external session/alias;
- canonical event: connection + source event identity/idempotency;
- order: connection + Shopify order ID;
- opportunity: connection + source event + recovery-cycle identity;
- provider event: retain provider-level event deduplication where provider IDs are globally unique, but include tenant/connection lineage after route resolution.

Never merge two stores' customers solely because their email addresses match. Email is a contact point, not the source-system primary key.

Do not drop existing tenant-level constraints before duplicate/collision analysis, dual-key compatibility and a rollback path have been reviewed.

## 4. Recovery and delivery enforcement

Every candidate function must return a validated connection ID. Each candidate processor must re-check the same identity inside its write transaction.

The worker context must derive connection from opportunity → source event/checkout/customer and verify all links. Delivery authorization must validate:
- delivery request;
- intervention;
- sequence;
- opportunity;
- customer;
- checkout/cart/session;
- source event;
- active Shopify connection;
- app identity;
- sender policy and current consent/suppression.

Any missing, inactive, conflicting or cross-connection link must deny claim/send and produce a structured reason plus audit event.

Every follow-up scheduler, conversion stop, order projection, attribution, tracking redirect, revenue adjustment and recovery cancellation must use the same connection predicate. A paid order in Store B must never stop a recovery in Store A.

## 5. Consent, conversations and unsubscribe

Shopify consent updates must resolve exact app + connection before resolving a customer. Default Shopify consent scope is the originating store.

Merchant-configurable tenant-wide suppression can be supported as a separate explicit policy, not an implicit side effect of tenant-scoped rows.

Inbound reply routing must bind reply token → conversation → customer → opportunity → intervention/delivery → connection and verify sender identity. Opt-out must retain source connection and apply configured scope.

Unsubscribe tokens must bind exact intervention/delivery/customer/connection, have expiry and used-state semantics, and return trusted suppression scope from validation. Do not use email to infer the source store.

## 6. Privacy compliance

Privacy webhook handling must resolve app key + shop domain to exact active or historical connection after HMAC verification.

- Customer data request: export only data sourced from the exact connection.
- Customer redact: delete/anonymize only data sourced from that connection, preserving other stores' records even when customer IDs/emails match.
- Shop redact: delete/anonymize only store-originated data and revoke that connection. Never delete the tenant as a shortcut.
- Uninstalled or unmatched shops: retain a durable `REVIEW_REQUIRED` request and compliance receipt; do not guess a tenant or connection.
- Shared provider credentials, tenant membership and account-level records must follow a documented retention policy and must not be deleted as store data.

The recovered legacy privacy handler is a source snapshot, not a safe multi-app implementation. It must not be copied unchanged to a public-app route.

## 7. Billing principal — decision gate

Current production schema models one billing account per tenant, while Shopify subscriptions are associated with individual app installations. This is a product/accounting decision, not just a database migration.

Before schema changes, approve one explicit model:
- **Per store:** each connection has its own Shopify subscription, usage cap, recovered revenue and performance fee.
- **Per tenant:** stores share one merchant billing principal; onboarding, authorization and payment collection must support a tenant-level account independent of a single Shopify installation.
- **Hybrid:** one tenant account with per-store measurements and a defined consolidated invoice/payment principal.

Whichever model is chosen:
- attribution must be same-connection and CONFIRMED/PROBABLE according to the billing policy;
- POSSIBLE/customer-only matches remain non-billable;
- store dashboards filter by connection;
- tenant summaries are clearly labelled tenant-wide;
- email provider costs are allocated to the store that originated the delivery, while tenant-level shared cost treatment is explicit;
- uninstall/cancellation must stop future sends and billing entitlements for the affected principal without disabling unrelated stores.

Do not choose the billing principal implicitly by preserving the current `billing_accounts(tenant_id)` primary key.

## 8. Backfill and quarantine policy

Backfill only from explicit, trusted evidence:
- a webhook receipt already tied to a known connection;
- a pixel key's exact connection FK;
- a validated immutable delivery/recovery chain;
- a trusted app-aware OAuth state/install record.

Do not backfill from email, tenant-only IDs, current active connection, guessed shop domain, or "only one store currently active".

Classify each row:
- `RESOLVED`: one exact connection proven;
- `LEGACY_SINGLE_STORE`: one historical app/store identity proven by immutable records;
- `AMBIGUOUS`: multiple plausible connections;
- `UNRESOLVED`: no trustworthy source.

Only RESOLVED/LEGACY_SINGLE_STORE rows can be backfilled automatically. AMBIGUOUS/UNRESOLVED rows stay quarantined and cannot trigger recovery, send, attribution billing or destructive privacy action until reviewed.

## 9. Rollout stages and gates

1. **Inventory freeze:** capture schema, constraints, triggers, RPC signatures, deployed Edge Function versions, n8n workflow versions and Worker routes.
2. **Additive identity schema:** app registry and nullable identity columns, composite FK prerequisites, no existing reader behavior changed.
3. **Ingress dual-write:** trusted app-aware verification and exact connection ID on new webhook/pixel source rows.
4. **Writer migration:** customer, checkout, session, event, order, consent and privacy writers persist connection identity.
5. **Backfill preview:** SELECT-only collision report, dry-run counts by classification, sampled lineage proof.
6. **Reader migration:** candidate discovery, worker context, delivery authorization, reply/unsubscribe, attribution, stop-recovery, dashboard and billing reads enforce connection identity.
7. **Two-store regression:** deliberately reuse customer ID, email, checkout ID/token, session reference, order ID and provider events across two stores.
8. **Legacy regression:** install/refresh/uninstall/webhook/privacy tests against existing legacy app identity.
9. **Canary:** one explicitly authorized test store, recovery disabled by default, test-only delivery sink, no real customer sends.
10. **Release review:** security/privacy review, Shopify compliance checks, migration rollback plan, explicit user approval before any production change.

## 10. Rollback design

- Additive columns and registry records can remain unused if the new code is rolled back.
- Keep legacy app identity and secret references intact.
- Do not reverse-backfill ambiguous rows.
- Do not drop old indexes/constraints until a later, separately approved cleanup.
- Keep new app installs disabled until ingress, OAuth, token refresh, privacy, recovery and billing gates all pass.
- A rollback must disable new app-key routes and new sends without deleting store/customer/order history or disrupting the legacy app.

## 11. Required validation evidence before implementation approval

- Exact list of all writers and readers updated, including external n8n/Worker/Edge Function callers.
- Constraint and index migration plan with collision counts.
- Backfill classification counts and sample proof.
- Automated two-store tests for all external ID reuse cases.
- Privacy export/redact tests proving Store B survives Store A requests.
- OAuth/HMAC tests proving one app secret cannot validate another app's request.
- Billing decision and example invoice/reconciliation calculations.
- Confirmed CI pass on the final branch head.
- Explicit approval for each production migration/deployment/release stage.

## Explicit non-actions

No SQL migration is included here. No production schema, data, Edge Function, n8n workflow, Cloudflare Worker, Shopify app configuration, secret, or deployment was changed.
