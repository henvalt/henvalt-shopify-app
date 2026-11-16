# Additional Recovery, Identity and Consent Function Audit

Status: read-only review of deployed `henvalt` function definitions. No database changes were made.

## Scope and method

Inspected deployed PostgreSQL function definitions from `pg_proc` / `pg_get_functiondef` for identity resolution, opportunity eligibility, communication eligibility, candidate processing, order-stop handling and privacy-export retention. This is a source-level contract audit, not an end-to-end test.

## Findings

### P0 — Identity resolution is tenant-scoped, not store-scoped

`resolve_identity(p_event_id)` loads the canonical event's tenant, customer reference, email, session reference and anonymous reference. It then:
- resolves customer by tenant + Shopify customer ID;
- falls back to tenant + lowercased email;
- resolves session aliases by tenant + alias;
- creates/updates sessions by tenant + session reference;
- resolves checkout by tenant + email + optional session reference.

There is no `shopify_connection_id` in the function contract or predicates. Two stores in one tenant can therefore collide on customer IDs, email fallback, session aliases, session references and checkout resolution. The event ID is a trusted parent only if its own store lineage has already been resolved; the current function does not carry that lineage forward.

**Required change in future migration:** resolve the canonical event's exact connection first and include it in every identity lookup, alias, session and checkout operation. Email is a contact attribute, never a cross-store identity key. Ambiguous legacy rows must be quarantined.

### P0 — Eligibility can suppress one store because of another store

`evaluate_eligibility(p_opportunity_id)`:
- looks up opportunity by ID;
- checks paid/refunded/voided/cancelled orders by tenant + checkout ID;
- checks existing active recovery sequences by tenant + customer ID;
- delegates to communication eligibility using tenant + customer ID.

With multiple stores per tenant, an order or active sequence in Store B can suppress Store A's opportunity if the customer/checkout identifiers overlap. It does not require same-connection lineage.

**Required change:** every order, checkout, customer, sequence and opportunity comparison must be constrained to one validated connection. A customer-wide concurrency limit, if desired, must be an explicit merchant policy and must not silently merge Shopify identities.

### P0 — Communication consent and suppression are tenant-wide

`evaluate_communication_eligibility(p_tenant_id, p_customer_id, ...)` loads a tenant customer and checks active email suppressions by tenant + customer or normalized email. It uses customer-level consent fields/metadata and tenant-level messaging compliance settings.

This is not sufficient to prove consent for a particular Shopify store. In particular, a consent webhook from one shop can update a tenant customer row that is shared by another shop, and an email suppression can affect both stores without an explicit policy decision.

**Required change:** store-specific consent evidence must be linked to the originating connection and source webhook. Default Shopify consent/unsubscribe behavior should be store-scoped. A tenant-wide suppression may be layered on only as an explicit, visible policy with a clear scope.

### P1 — Opportunity communication context has no connection binding

`evaluate_opportunity_communication_eligibility(p_tenant_id, p_opportunity_id)` joins opportunity to customer and checkout using tenant IDs, extracts country/evidence metadata, then calls the tenant-scoped communication evaluator. It does not verify that the checkout/customer belongs to the same Shopify connection as the opportunity.

**Required change:** derive and compare the immutable connection ID across opportunity, checkout, customer and source event before evaluating eligibility.

### P1 — Candidate processors preserve tenant-only identity keys

The deployed candidate processor functions create opportunities with idempotency keys based on tenant + session hash (cart) or tenant + session + product hash (browse), and persist shop domain as JSON metadata. The processors call tenant-scoped eligibility and create recovery sequences without a typed connection ID. Checkout cycle logic also uses tenant-scoped checkout/opportunity relationships.

**Required change:** connection ID must be a first-class field in candidate output, opportunity lineage and idempotency scope. JSON shop-domain metadata may remain diagnostic but cannot serve as referential integrity or authorization.

### P1 — Order-stop handling trusts tenant lineage only

`stop_recovery_after_order(p_attribution_id)` joins attribution to order by tenant, then resolves recovery by tenant + checkout ID or tenant + tracking token. It correctly avoids stopping sequences for customer-only POSSIBLE attribution, but CONFIRMED/PROBABLE status alone does not prove that the order and recovery belong to the same store.

**Required change:** require the attribution, order, opportunity, sequence, intervention and tracking token to share the same validated connection. Preserve the POSSIBLE/non-billable and non-stopping behavior.

### P2 — Privacy export retention cleanup is payload-only

`purge_expired_shopify_privacy_exports()` clears expired `result_payload` and `result_expires_at` values. It does not delete the compliance request or receipt row. This is useful for retaining a minimal audit receipt, but the future store-scoped model must ensure retained metadata does not preserve unnecessary personal data or leak a different store's identity.

## New regression requirements

- IDENTITY-01: same customer ID and email in A and B resolve to separate store-bound customers.
- IDENTITY-02: same session, anonymous reference or alias in A and B cannot cross-link.
- IDENTITY-03: checkout resolution only considers the originating connection.
- ELIG-01: a paid order in B does not suppress A's opportunity.
- ELIG-02: an active recovery sequence in B does not suppress A's opportunity by default.
- CONS-03: communication eligibility evaluates consent evidence for the opportunity's exact connection.
- CONS-04: an A suppression does not suppress B unless a separately configured tenant-wide policy applies.
- PROC-01: cart/browse idempotency includes connection identity.
- STOP-01: an attribution/order from B cannot stop an A recovery sequence even with matching checkout ID or token text.
- PRIV-06: expiry cleanup clears sensitive export payload but preserves a minimal, store-bound compliance receipt under the retention policy.

## Migration implications

These findings expand the set of records that need connection lineage: canonical events, customers, session aliases, sessions, checkouts, opportunities, recovery sequences/interventions, orders, attributions, tracking tokens, consent evidence, suppressions and privacy receipts.

The migration must not backfill connection identity from email, customer ID, session text or the mere existence of one currently active store. Only trusted source-event/webhook/pixel lineage or an independently verifiable historical shop mapping can resolve a row. Otherwise mark it ambiguous/unresolved and exclude it from cross-store recovery and billable attribution until reviewed.
