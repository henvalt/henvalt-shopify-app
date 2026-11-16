# HENVALT Store-Isolation Regression Matrix

Status: preparation specification only. No production code, database, workflow, or Shopify app was changed by creating this document.

This matrix is the acceptance gate for introducing a second Shopify app identity while retaining the existing merchant-owned app as a legacy installation. It is designed around two independent Shopify stores owned by one HENVALT tenant, plus a separate tenant to prove tenant isolation.

## Test fixtures

Use synthetic data only:

- Tenant T1 has stores A and B, each represented by a distinct Shopify connection.
- Tenant T2 has store C.
- Legacy app identity is `legacy`; future public app identity is `public_v1`.
- Store A and B deliberately reuse overlapping Shopify customer IDs, checkout IDs, order IDs, source event IDs, email addresses, and idempotency strings where Shopify permits this.
- Store C uses distinct values.
- Each store has different store name, sender identity, recovery settings, and email branding. Billing fixtures must cover the explicitly selected commercial principal (per-store, per-tenant, or hybrid); the test suite must not assume that decision before it is approved.
- Provider credentials for MailerSend remain tenant/provider scoped unless the product explicitly introduces a separate provider account per store.

## A. App identity and OAuth

| ID | Scenario | Required result |
|---|---|---|
| OAUTH-01 | Existing legacy app starts OAuth | Existing callback, app key, and credentials resolve to `legacy`; no public secret is consulted |
| OAUTH-02 | Public app starts OAuth | OAuth state is bound to `public_v1`; callback uses the public app's client ID/secret |
| OAUTH-03 | Change unsigned shop header/app-key header after OAuth starts | Callback rejects mismatch; identity comes from signed state and server-side app registry |
| OAUTH-04 | Expired, replayed, or consumed OAuth state | Reject; no connection or token mutation |
| OAUTH-05 | Public app install attempts to overwrite a legacy connection for same shop | Fail closed with explicit conflict; never overwrite tokens or rebind silently |
| OAUTH-06 | Token refresh for legacy and public identities | Correct app credentials and exact connection/refresh lease are used |
| OAUTH-07 | Unknown, disabled, or unconfigured app key | Reject before token exchange or persistence |
| OAUTH-08 | Client ID or secret accidentally appears in logs, response, DB row, or browser payload | Test fails; only secret references and non-secret app metadata may be exposed |

## B. Webhook authentication and routing

| ID | Scenario | Required result |
|---|---|---|
| WEB-01 | Valid legacy webhook | Verify raw body with legacy secret and bind exact legacy connection |
| WEB-02 | Valid public webhook | Verify raw body with public secret and bind exact public connection |
| WEB-03 | Valid body signed with wrong app secret | Reject; no event row or side effect |
| WEB-04 | Mutate raw body after signature creation | Reject |
| WEB-05 | Spoof shop domain or app key in unsigned headers/body | Reject or resolve only through verified app identity + trusted connection mapping |
| WEB-06 | Replayed webhook ID for same connection | Idempotent; no duplicate event/opportunity |
| WEB-07 | Same source event ID in Store A and Store B | Both accepted as distinct store events |
| WEB-08 | Unknown/uninstalled shop sends validly shaped webhook | No tenant guessing; safe rejection or durable unresolved event according to explicit policy |

## C. Store-scoped event and customer identity

| ID | Scenario | Required result |
|---|---|---|
| DATA-01 | Same Shopify customer ID appears in A and B | Two store-bound customer records; never merge by tenant + Shopify ID |
| DATA-02 | Same email appears in A and B with different consent | Consent remains store-specific; one store's consent does not overwrite the other |
| DATA-03 | Customer ID absent, same email in A and B | No automatic cross-store customer merge |
| DATA-04 | Same checkout ID/token appears in A and B | Two distinct checkout rows |
| DATA-05 | Same order ID appears in A and B | Two distinct order rows |
| DATA-06 | Same idempotency key is submitted for A and B | Distinct connection-scoped records; retry within one store remains idempotent |
| DATA-07 | Event lacks a trusted connection mapping | Quarantine/reject from store-specific recovery; never assign current active store by inference |
| DATA-08 | Parent event and child checkout/customer point to different connections | Transaction rejected and audited |
| DATA-09 | Customer, checkout, opportunity and recovery lineage cross connection IDs | Constraint/RPC rejects the write |\n| IDENTITY-01 | Same customer ID and email in A and B | Separate store-bound customers; no cross-store email fallback |\n| IDENTITY-02 | Same session, anonymous reference or alias in A and B | No cross-store session or alias linking |\n| IDENTITY-03 | Checkout resolution from an event in A | Only A's connection-scoped checkout can resolve |

## D. Recovery eligibility, delivery and conversion stops

| ID | Scenario | Required result |
|---|---|---|
| REC-01 | A and B both have abandoned checkout opportunities | Each candidate carries its own connection ID and store context |
| REC-02 | A customer purchases in A while B has an open opportunity | Only A's matching opportunity is stopped |
| REC-03 | Order paid event in B shares customer email with A | A's recovery remains eligible unless a separate explicit tenant-wide suppression policy applies |
| REC-04 | Cart/browse event has missing or ambiguous store identity | No message is sent |
| REC-05 | Delivery request IDs are mixed across stores | Authorization rejects the mixed lineage |
| REC-06 | Connection becomes inactive after scheduling but before send | Delivery authorization blocks sending |
| REC-07 | Same delivery request retried | Existing idempotency and attempt safeguards prevent duplicate send |
| REC-08 | Refund/cancel/payment-failure event belongs to B | Only B's matching order/recovery/ledger is updated |
| REC-09 | Store A delivery request references Store B sender profile | Authorization/rendering rejects mismatch |
| REC-10 | MailerSend provider token lookup | Remains tenant/provider scoped but only authorizes delivery for a valid store-bound delivery request |\n| ELIG-01 | Paid order in B shares checkout/customer identifiers with A | Does not suppress A's opportunity |\n| ELIG-02 | Active recovery sequence in B shares customer with A | Does not suppress A by default |\n| CONS-03 | Communication eligibility evaluated for A opportunity | Uses consent evidence tied to A's exact connection |\n| CONS-04 | A suppression exists for shared email | B remains eligible unless explicit tenant-wide suppression policy applies |\n| PROC-01 | Cart/browse candidate generated in A or B | Idempotency includes exact connection identity |\n| STOP-01 | B attribution/order matches A checkout/token text | Cannot stop A's recovery sequence |

## E. Attribution, dashboard and billing

| ID | Scenario | Required result |
|---|---|---|
| ATTR-01 | Recovered order in A follows A intervention | Attribution and ledger entry are attached to A's connection |
| ATTR-02 | Similar order in B follows B intervention | Attribution and ledger entry are attached to B, not A |
| ATTR-03 | A and B have separate dashboard requests | Each store view reports only its own events, messages, orders and recovered revenue |
| ATTR-04 | Tenant-wide overview requested | Aggregation is explicit and labelled as tenant-wide; it is not returned accidentally from a store endpoint |
| BILL-01 | A and B use the approved billing principal | Per-store, tenant-wide, or hybrid account/subscription mapping matches the documented product decision; no accidental principal is inferred |
| BILL-02 | A usage measurement is submitted from B | Reject; charge must resolve to the measurement's store |
| BILL-03 | Same billing idempotency key appears in A and B | Store-scoped uniqueness; retries in one store remain idempotent |
| BILL-04 | Tenant-wide billing rollup requested under the selected model | Sum exact store measurements without duplicating or omitting ledger entries; label tenant scope explicitly |
| BILL-05 | No recovered revenue | No performance fee is created merely from sent messages or projected value |

## F. Privacy, consent, unsubscribe and inbound replies

| ID | Scenario | Required result |
|---|---|---|
| PRIV-01 | Customer data request for A | Export only A's customer data and store-specific events |
| PRIV-02 | Customer redact request for A | Delete/redact only A's customer identity and dependent personal data |
| PRIV-03 | Same customer ID/email exists in B | B's records are not accidentally exported or erased |
| PRIV-04 | Valid compliance webhook for uninstalled shop | Durable unresolved compliance case; no silent discard |
| PRIV-05 | Compliance webhook signed with other app's secret | Reject |\n| PRIV-06 | Expired privacy export payload is purged | Sensitive payload cleared; minimal store-bound compliance receipt retained per policy |
| CONS-01 | Consent update in A | Update A only; retain source and observed timestamp |
| CONS-02 | Consent update in B with opposite value | B's state changes independently |
| REPLY-01 | Shopper replies to A's recovery email | Reply maps through exact provider message/delivery/conversation lineage to A |
| REPLY-02 | A and B share email address | Reply is not routed by email alone |
| REPLY-03 | A conversation uses B's AI knowledge base or branding | Reject; reply context must use originating store scope |
| REPLY-04 | Conversation is opted out, closed, or requires human | AI does not send an automatic reply |
| UNSUB-01 | Unsubscribe token created from A | Suppression applies to A's store identity and any explicitly defined global suppression policy, never accidental tenant-wide customer merge |

## G. Pixel and browser identity

| ID | Scenario | Required result |
|---|---|---|
| PIX-01 | Pixel key for A submits event | Event resolves to A's exact connection |
| PIX-02 | Pixel key for A is paired with B's origin | Reject |
| PIX-03 | Revoked/uninstalled connection pixel key submits event | Reject |
| PIX-04 | Same anonymous/session reference exists in A and B | Separate store-scoped identity |
| PIX-05 | Supported pixel event list differs from collector allow-list | CI fails before merge |

## H. Tenant authorization and settings

| ID | Scenario | Required result |
|---|---|---|
| AUTH-01 | User belongs to T1 and selects A | Server verifies membership and A's connection belongs to T1 |
| AUTH-02 | User changes selected store ID to C (T2) | Reject, even if client sends a valid UUID |
| AUTH-03 | User belongs to T1 with two active stores | Explicit store selection required; no arbitrary first-row selection |
| AUTH-04 | User has no active connection | Safe no-store state; no tenant-wide fallback |
| SET-01 | A updates recovery settings | A changes only, unless setting is explicitly tenant-shared |
| SET-02 | A updates sender profile/branding | A changes only under recommended store-specific default |
| SET-03 | Shared MailerSend provider config updated | Tenant-level provider behavior remains intentional and visible |
| SET-04 | Tenant member role changes | Membership applies across tenant stores according to existing role model, not app identity |

## I. Migration and rollout safety

| ID | Scenario | Required result |
|---|---|---|
| MIG-01 | Existing row maps to exactly one connection through trusted source lineage | Backfill candidate is deterministic and auditable |
| MIG-02 | Existing row has no shop marker or multiple possible connections | Remains unresolved; not assigned by guess |
| MIG-03 | Composite unique index is introduced | Preflight collision report is empty or collisions are explicitly reconciled |
| MIG-04 | Old active n8n workflow calls legacy RPC signature during compatibility window | Legacy behavior remains correct and cannot overwrite public identity |
| MIG-05 | New app-aware workflow calls new RPC signature | Exact connection ID is verified server-side |
| MIG-06 | Rollback to legacy app path | Legacy credentials, connection and workflows remain operational |
| MIG-07 | Deploy sequence interrupted between DB, Edge Function, Worker and n8n stages | System fails closed without accepting unsigned identity or sending cross-store mail |

## Billing decision gate

Before enabling BILL-01 through BILL-04 as executable acceptance tests, record the approved commercial principal in the billing architecture decision record. The decision must specify who authorizes payment, how multiple Shopify installations map to one or more billing accounts, how recovered revenue is consolidated, and how email costs are allocated. Until that decision is approved, tests must validate isolation and consistency without presuming per-store subscriptions.

## Release gates

A public-app rollout is not ready until:
- all P0 identity, OAuth, webhook, store-isolation, privacy and delivery tests pass;
- all legacy regression tests pass;
- migration preflight reports mapped/ambiguous/missing/conflicting rows separately;
- no secret is exposed to browser, Git, or logs;
- the release plan supports rollback without replacing the merchant-owned legacy app;
- the user explicitly authorizes production deployment and Shopify app release.

This matrix is a test specification, not an assertion that these tests have already run.


## J. App identity, OAuth collision and secret isolation

| ID | Scenario | Required result |
|---|---|---|
| APP-01 | Legacy app receives callback state created by public_v1 route | Reject; state app_key and trusted callback route must match |
| APP-02 | Public app receives callback state created by legacy route | Reject; no cross-app secret fallback |
| APP-03 | Legacy HMAC sent to public_v1 ingress | Reject before n8n forwarding |
| APP-04 | Public_v1 HMAC sent to legacy ingress | Reject before n8n forwarding |
| APP-05 | Unknown or disabled app_key appears on trusted ingress route | Reject; never default to legacy |
| APP-06 | Same shop already connected to legacy; public_v1 OAuth begins | Conflict before token exchange/finalization where possible; existing connection unchanged |
| APP-07 | Same shop already connected to public_v1; legacy OAuth begins | Conflict; existing connection unchanged |
| APP-08 | Same app repeats a consumed OAuth callback | Reject replay; no Vault token update |
| APP-09 | Two different shops in one tenant use different app keys | Both connections remain distinct and tenant-consistent |
| APP-10 | App registry row references missing Vault secret | Fail closed; do not use another app's secret |
| APP-11 | Caller supplies app_key header/body conflicting with trusted Worker route | Strip/reject caller value; only Worker-authenticated route identity is accepted |
| APP-12 | Connection app_key differs from OAuth state app_key | Reject before any token/Vault write |
| APP-13 | App-aware connection resolver finds zero or multiple matches | Structured unresolved/ambiguous failure; never select LIMIT 1 |
| APP-14 | Token refresh request supplies another shop domain or app key | Reject; refresh is bound to immutable connection ID and lease |
| APP-15 | App A uninstall webhook targets a store connected under app B | Reject; no cross-app deactivation |
| APP-16 | Legacy app receives a valid webhook after public_v1 route is enabled | Legacy HMAC and routing continue unchanged |
| APP-17 | Public app registry entry is inactive | Reject OAuth, refresh and webhook processing; no legacy fallback |
| APP-18 | Rollback disables public_v1 ingress | Legacy app continues; public_v1 events fail closed and do not enter legacy path |

