# Legacy customer-data dependency audit — V2 redaction planning

**Status: read-only production audit; preparation branch documentation only. Not a legal determination. No redaction or data mutation performed.**

Audit date: 2026-11-18  
Supabase project: HENVALT (`ocyplckdojdubyrsxcxa`)

## Executive finding

The live legacy schema is not safe for a direct `DELETE FROM customers` redaction strategy. The customer row has seven direct foreign-key dependants with mixed `CASCADE` and `SET NULL` behavior. Downstream cascades can remove conversations, delivery requests, attempts, messages and tracking records; other links survive with nullable customer references. Separately, personal data exists in free-form JSON payloads and recipient/contact columns without a direct customer foreign key. A direct customer deletion would therefore be both over-destructive in some branches and incomplete in others.

The new V2 exact-store identity migrations remain branch-only and unapplied. Production legacy records do not have the immutable Shopify connection lineage needed to safely infer which store owns a customer row. Do not backfill or delete them by tenant or by unverified webhook metadata.

## 1. Read-only production inventory

Point-in-time row counts (not customer-level data):

| Table | Rows |
|---|---:|
| customers | 3 |
| shopify_connections | 4 |
| shopify_privacy_requests | 0 |
| checkouts | 2 |
| sessions | 5 |
| session_aliases | 2 |
| opportunities | 5 |
| recovery_sequences | 3 |
| recovery_interventions | 5 |
| delivery_requests | 3 |
| delivery_attempts | 5 |
| messages | 6 |
| tracking_tokens | 7 |
| unsubscribe_tokens | 7 |
| provider_events | 4 |
| email_usage_measurements | 4 |
| customer_conversations | 0 |
| conversation_messages | 0 |
| email_suppressions | 0 |
| orders | 0 |
| order_attributions | 0 |
| revenue_ledger | 0 |
| billing_measurements | 0 |
| canonical_events | 166 |
| webhook_events | 132 |
| audit_log | 255 |
| processing_errors | 0 |

Counts can change after the audit. No record values, customer IDs, email addresses, phone numbers, or tokens were selected or emitted.

## 2. Direct customer foreign-key graph

The live database reports these direct references to `customers.id`:

| Child table | FK column | ON DELETE |
|---|---|---|
| checkouts | customer_id | SET NULL |
| customer_conversations | customer_id | CASCADE |
| email_suppressions | customer_id | SET NULL |
| opportunities | customer_id | SET NULL |
| orders | customer_id | SET NULL |
| sessions | customer_id | SET NULL |
| unsubscribe_tokens | customer_id | CASCADE |

### Implications

- Deleting a customer cascades to `customer_conversations` and `unsubscribe_tokens`. The conversation FK has further cascade relationships to `conversation_messages`; conversations also reference opportunities, recovery sequences, interventions and delivery requests. This can erase communication and operational evidence beyond the customer profile.
- The unsubscribe token rows are currently seven records globally. Their customer FK cascades, so a naive delete removes token-based unsubscribe capability/evidence. The system must replace that linkage with a reviewed, irreversible suppression representation before any identity row is removed; do not simply discard opt-out state.
- The `SET NULL` children survive but can still retain personal data in their own columns, JSON metadata, tokens or references. Nulling the FK is not erasure.
- Opportunity/recovery/intervention/delivery cascades and downstream `RESTRICT` constraints (including email usage measurements and billing usage charges) mean deletion order cannot be guessed from the direct customer FK list. A transactional plan must account for all indirect dependencies and preserve financial records.

## 3. PII-bearing storage outside the direct FK graph

Column inventory and non-value presence checks found these paths:

- `customers`: email present on 3 rows; phone present on 2.
- `checkouts`: email present on 2 rows; checkout token is also a sensitive identifier.
- `canonical_events`: email column populated on 89 rows; 92 payloads contain one or more contact/customer keys.
- `webhook_events`: 92 payloads contain one or more contact/customer keys. 130 rows have `metadata.shop_domain`, but that metadata is not cryptographic proof of app/store identity.
- `messages`: recipient populated on 6 rows; tracking tokens are separate linked records.
- `provider_events`: recipient email populated on 4 rows; payload is JSON and may contain provider-supplied fields.
- `audit_log`: 2 payloads contain contact/customer/recipient keys.
- `shopify_privacy_requests`: legacy table includes raw webhook `payload` and `result_payload` columns, but currently has zero rows.
- `processing_errors`: JSON payload exists as a possible storage path; current row count is zero.
- `conversation_messages`: sender/recipient email columns exist; current table row count is zero.

The counts above are presence checks only. They do not disclose values and do not prove all JSON documents are free of PII. A future export/redaction process must inspect known JSON schemas and versioned payload shapes without dumping raw payloads into logs.

## 4. RLS posture

RLS is enabled on the inspected customer, checkout, session, opportunity, conversation, suppression, unsubscribe, message, provider-event, canonical-event, webhook-event and legacy privacy-request tables. `FORCE ROW LEVEL SECURITY` is false on those tables.

RLS enabled is not proof that a service-role redaction executor is safe, nor does it make tenant-wide legacy RPCs exact-store safe. Every privileged executor still needs exact receipt → tenant → immutable connection → app key → shop binding, narrowly scoped grants, fixed search path, idempotency and adversarial cross-store tests.

## 5. Critical legacy limitation: store lineage

The production customer-centric legacy tables are tenant-scoped and do not have the V2 immutable Shopify connection ID on their rows. The live tenant can own multiple Shopify connections. Existing webhook `metadata.shop_domain` is only metadata, not HMAC-verified lineage for historical records. Consequently:

- Do not infer a customer’s store from tenant membership, email, matching Shopify IDs, checkout token, or webhook metadata.
- Do not bulk-backfill `shopify_connection_id` on legacy rows.
- Keep unbound rows in a manual-review / unresolved state.
- A customer redaction receipt with an exact V2 connection must not sweep legacy tenant-wide rows unless a separate verified binding exists.

## 6. Recommended V2 redaction architecture

### Phase A — freeze and scope

1. Claim the exact verified `customers/redact` receipt under a short lease and immutable claim token.
2. Resolve the exact app key, tenant, connection and shop domain from the verified receipt. Reject ambiguous or missing bindings.
3. Resolve customer identity only through exact-store Shopify customer ID. Email-only payloads remain review-required unless a separately approved, collision-safe exact-store matching protocol is implemented.
4. Materialize a read-only impact manifest listing exact rows by table, connection lineage, FK path, PII-bearing fields and retention category. Do not include raw values in the manifest.

### Phase B — stop sending before erasure

1. Fence new authorizations for the exact customer/store.
2. Revoke outstanding single-use delivery permits for that identity and connection.
3. Cancel queued interventions and unsent delivery work for the exact scope.
4. Recheck the fence immediately before any provider call; a redaction arriving concurrently with a send must prevent a new send.
5. Preserve the minimal suppression evidence needed to prevent future sends, using a separately reviewed keyed fingerprint design. Do not preserve raw email merely for convenience, and do not delete existing suppression evidence without replacement.

### Phase C — field-level erase/anonymize

Use a reviewed table-by-table plan, not broad cascade deletion. Separate:
- direct customer identity and contact fields;
- checkout/session/contact references and payloads;
- event and webhook payloads;
- message recipient and provider payloads;
- unsubscribe/suppression evidence;
- tracking/reply tokens and delivery artifacts;
- financial attribution, revenue, refunds, cost reservations, billing and accounting evidence;
- minimal security/audit evidence.

The policy must define which fields are erased, irreversibly anonymized, retained under a documented legal basis, or held for manual review. HENVALT must not choose tax/accounting retention periods or jurisdictional legal bases by guesswork.

### Phase D — postconditions

A completed state requires all of the following:
- no unresolved PII in the exact customer/store scope, including known JSON payloads and provider/message copies;
- no active send authorization, queued intervention or reusable customer token for that scope;
- approved suppression state remains effective without exposing the original address;
- financial and cost ledgers remain internally consistent, with customer references detached only where the approved policy permits;
- unresolved legacy rows are reported and do not get silently counted as deleted;
- an auditable, non-PII completion report records what was erased, anonymized, retained and excluded, with policy version and exact receipt lineage.

## 7. Required tests before any executor

- Two stores in one tenant with the same Shopify customer ID and overlapping order IDs: only the receipt's exact store is affected.
- Missing/ambiguous connection, email-only payload, stale claim, expired lease and duplicate webhook: fail closed and remain review-required.
- Direct customer delete is not used as the primary redaction primitive; tests prove no unintended cascade into financial, delivery, conversation or audit evidence.
- Unsubscribe/suppression survives identity erasure without retaining raw contact data.
- PII scan covers structured columns and known JSON paths in canonical events, webhooks, messages, provider events, audit and privacy payloads.
- Redaction races against queued send, permit issuance, permit consumption and provider submit; no new send can occur after the fence.
- Cost reservations, email usage, provider events, revenue ledger, refunds and billing measurements remain reconcilable.
- Every affected table has exact-store scope and cross-tenant/cross-store negative tests.
- Retry after partial failure is idempotent and resumes from a durable phase marker.

## 8. Release decision

**No production redaction executor should be implemented against the legacy customer graph.** The live graph is tenant-scoped, has destructive cascades, and contains PII in multiple disconnected columns/payloads. Continue with the V2 exact-store identity graph and build a service-only impact-manifest/preview first. Keep execution disabled until the retention policy, suppression strategy, all PII storage paths, and concurrency fences have reviewed tests.

This audit is preparation only. It does not execute deletion, update RLS, modify any production row, deploy a migration, or certify legal compliance.

## References

- Shopify privacy compliance webhooks and customer/order request payloads: https://shopify.dev/docs/apps/build/compliance/privacy-law-compliance
- Shopify webhook compliance topics: https://shopify.dev/docs/apps/build/webhooks/subscribe
- Shopify merchant processing responsibilities and distinctions between erasure and profile deletion: https://help.shopify.com/en/manual/privacy-and-security/privacy/processing-customer-data-requests
