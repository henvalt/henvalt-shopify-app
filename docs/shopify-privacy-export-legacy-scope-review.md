# Privacy export legacy-scope review (V2)

Status: **OPEN — completion must remain fail-closed**

This review records why `build_shopify_customer_privacy_export_v2` currently returns
`legacy_scope_review_required=true` and `completion_eligible=false`. It is a
coverage investigation, not approval to export or delete historical records.

## Confirmed current behavior

The V2 builder positively scopes its current record families through the exact
`tenant_id + shopify_connection_id + customer_identity_id` relationship.
It includes V2 customer identity, sessions and aliases, pixel inbox events,
checkouts, recovery candidates/opportunities, consent evidence, interventions,
delivery attempts/permits/suppressions, provider events, orders, refunds,
attributions, and fee measurements.

The builder also emits the verified Shopify order IDs from the privacy receipt
through `shopify_privacy_order_scope_report_v2`. That report distinguishes
requested, exact-customer-matched, and unmatched IDs. It deliberately does not
claim that order identity matching alone makes the complete export ready.

## Legacy lineage gap confirmed in migration 007

Migration `202611160007_exact_store_core_lineage_foundation.sql` adds nullable
`shopify_connection_id` to these pre-existing tables:

| Legacy table | Exact-store lineage | Safe export rule |
| --- | --- | --- |
| `henvalt.customers` | Nullable `shopify_connection_id` | Include only rows with the receipt's exact connection and an independently verified Shopify customer ID match. |
| `henvalt.sessions` | Nullable `shopify_connection_id` | Include only exact-connection rows linked through the same-store customer relationship. |
| `henvalt.session_aliases` | Nullable `shopify_connection_id` | Include only aliases whose session parent is exact-connection scoped. |
| `henvalt.checkouts` | Nullable `shopify_connection_id` | Include only exact-connection rows linked to the customer or an included session, with same-store relationship validation. |
| `henvalt.canonical_events` | Nullable `shopify_connection_id` | Include only exact-connection events with a defensible customer/session/checkout link. |

The migration explicitly says it does **not** backfill history and that NULL
means historical or unresolved. Its composite foreign keys are `NOT VALID`,
so they protect new writes but do not prove that historical rows are valid.
Therefore a tenant match, email match, customer reference, session reference,
or checkout token by itself is not sufficient to assign an old row to a store.

## Additional legacy workflow families requiring schema-level inventory

The older browse-abandonment path reads tenant-scoped `opportunities` and
uses `customers`, `canonical_events`, `sessions`, and `checkouts`. Its
worker context and downstream recovery/delivery tables must be inspected for
an immutable exact-connection path before any customer-level records from those
families can be included. A tenant-only foreign key or tenant-only idempotency
key is not store lineage.

The current V2 export covers V2 recovery and delivery tables, but that does
not establish coverage of historical V1 rows in `opportunities`,
`recoveries`, `interventions`, delivery logs, or other operational tables.
These must be enumerated from the actual schema and migrations before the
review gate can be removed.

## Required next engineering steps

1. **Catalog inventory:** enumerate every table that can hold customer,
   session, checkout, order, message, consent, event, attribution, or recovery
   data. Record primary keys, tenant keys, connection keys, customer links,
   foreign keys, and nullable/unvalidated constraints.
2. **Coverage classification:** for each table, classify records as (a)
   exact-connection and exact-customer attributable, (b) exact-connection but
   customer link unresolved, or (c) historical/tenant-only ambiguous.
3. **No heuristic backfill:** do not populate `shopify_connection_id` from
   email, tenant membership, matching numeric Shopify IDs, checkout tokens,
   or session aliases. Only immutable source evidence can support a backfill.
4. **Export implementation:** add only class (a) records to the customer
   export, with explicit fields and bounded payloads. Preserve the Shopify
   request's explicit order scope and report unmatched requested order IDs.
5. **Redaction parity:** use the same lineage inventory for redaction impact
   and deletion. Do not delete ambiguous tenant-wide rows on behalf of one
   store.
6. **Tests:** seed two stores in one tenant plus NULL-lineage historical rows.
   Prove that the export contains only the requesting store/customer, reports
   unresolved scope, and cannot become completion-eligible while any required
   family is unresolved.
7. **Completion evidence:** only enable completion after durable artifact
   delivery evidence (for data requests) or verified deletion postconditions
   (for redaction) are implemented and tested.

## Current decision

Keep the export processor's completeness guard and the database completion
gate unchanged. The processor must hold requests for review rather than emit
an incomplete export or report a false completion. The next implementation
should begin with a read-only catalog and relationship inventory, then add
per-family export coverage with two-store isolation tests.
