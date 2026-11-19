# HENVALT V2 candidate migration compatibility register — 19 November 2026

**Disposition: REVIEW REQUIRED — NOT APPROVED FOR PRODUCTION.**

This register is a source-level inventory of the 47 candidate migration files listed by the identity V2 CI workflow. It records the principal object/operation surface and identifies migrations requiring heightened production-parity review. It is not a substitute for a complete SQL semantic review, production schema comparison, historical-row disposition, or replay against a restorable production-like clone. The current live database baseline recorded in the 19 November readiness review is 178 migrations ending at `20261114174204`; none of this candidate chain is recorded as production-applied.

## Review rules

- Treat all 47 migrations as unapplied candidate SQL. CI applies them only to a disposable baseline.
- `CREATE TABLE IF NOT EXISTS` does not prove an existing production table has the expected columns, constraints, indexes, owner, RLS or grants.
- Every `CREATE OR REPLACE FUNCTION` requires signature, owner, SECURITY DEFINER, search_path, dependency and EXECUTE-grant comparison against production.
- Every ALTER/DROP/trigger replacement requires an object-existence check and a before/after data and behavior comparison.
- Do not run this chain against production as a diagnostic. Use a restorable clone first.
- The CI workflow's filename list is the source of truth for ordering; do not infer order from filesystem sorting.

## Ordered 47-file inventory

| # | Migration | Primary surface / operation class | Production-parity focus |
|---:|---|---|---|
| 01 | `202611160001_shopify_webhook_identity_foundation.sql` | App registry, connection identity columns/indexes, per-install webhook route tokens, webhook delivery inbox; RLS and service grants | Existing `shopify_connections` shape and uniqueness; app-key/domain collisions; existing policies/grants |
| 02 | `202611160002_shopify_webhook_verified_inbox_rpc.sql` | Verified webhook acceptance RPC; inserts delivery receipt and updates route-token state | Exact function overload, raw-body/HMAC contract, idempotency and role grants |
| 03 | `202611160003_shopify_oauth_state_app_identity.sql` | OAuth state app identity column/index and compatibility alteration | Existing OAuth state rows, nullable/backfill semantics and index selectivity |
| 04 | `202611160004_shopify_oauth_app_aware_finalizer.sql` | Replaces OAuth install finalizer; updates connections and route tokens | Existing finalizer behavior, token rotation, tenant/store binding and function ACL |
| 05 | `202611160005_shopify_app_oauth_secret_resolver.sql` | App OAuth identity/secret resolver RPC | Vault/registry dependencies, secret exposure boundary, function ACL |
| 06 | `202611160006_shopify_privacy_webhook_inbox_v2.sql` | Privacy webhook inbox table, RLS, verified acceptance RPC | Existing privacy receipt schema and exact receipt uniqueness |
| 07 | `202611160007_exact_store_core_lineage_foundation.sql` | Adds exact connection lineage to customers, sessions, aliases, checkouts and canonical events; unique indexes and conditional FK constraints | **High risk:** live legacy rows, duplicate keys, orphan references, existing unique/FK constraints, index build locks |
| 08 | `202611160008_shopify_pixel_event_inbox_v2.sql` | Pixel event inbox and ingestion RPC; rate-limit upsert; RLS/grants | Existing pixel rate-limit table/key semantics, RPC execution boundary and service-role revokes |
| 09 | `202611160009_shopify_pixel_identity_graph_v2.sql` | Customer/session/alias/checkout identity tables, indexes, projection function, RLS | Existing webhook delivery uniqueness and cross-store identity collision checks |
| 10 | `202611160010_shopify_checkout_webhook_projection_v2.sql` | Alters checkout identity nullability/columns; drops and recreates checkout token index; replaces checkout projection RPC | **High risk:** explicit index drop/recreate and table alterations; checkout rows and token duplicates |
| 11 | `202611160011_shopify_order_conversion_projection_v2.sql` | Order identity table, indexes, RLS, verified order projection RPC | Same-store checkout/order matching; duplicate order IDs and historical conversion mapping |
| 12 | `202611170001_shopify_checkout_recovery_eligibility_v2.sql` | Checkout recovery candidate table/index, refresh RPC, RLS | Existing checkout identities, policy time bounds, duplicate candidate keys and terminal-state semantics |
| 13 | `202611170002_shopify_recovery_opportunity_foundation_v2.sql` | Recovery opportunity table/index and checkout candidate promotion RPC | Existing candidate lineage, opportunity uniqueness and idempotent promotion |
| 14 | `202611170003_shopify_email_consent_evidence_v2.sql` | Consent/evidence tables, checkout columns/indexes, verified consent projection RPC | **High risk:** existing consent representations, conflicting opt-outs, historical evidence provenance and fail-closed defaults |
| 15 | `202611170004_shopify_checkout_jurisdiction_projection_v2.sql` | Replaces checkout jurisdiction projection RPC | Region source, unknown-region behavior and downstream send gate |
| 16 | `202611170005_shopify_mailer_provider_events_suppression_v2.sql` | Intervention/provider/attempt/event/suppression tables, indexes, RLS and MailerSend webhook ingestion RPC | **High risk:** provider event idempotency, suppression precedence, existing provider configuration and all table ACLs |
| 17 | `202611170006_shopify_single_use_delivery_authorization_v2.sql` | Sender profiles and single-use delivery permits; issue/consume RPCs | Permit entropy, expiry, exact intervention scope, consume-once concurrency and attempt creation |
| 18 | `202611170007_shopify_contact_resolution_and_delivery_v2.sql` | Alters provider registry; contact/delivery context and submission-result RPCs | Recipient PII boundary, caller-supplied content rejection, provider readiness and attempt state transitions |
| 19 | `202611170008_shopify_delivery_cost_reservations_v2.sql` | Provider cost columns/constraint changes, cost reservation table, triggers, resolver replacement | **High risk:** explicit constraint drop/recreate, trigger replacement, reservation uniqueness and historical attempt backfill |
| 20 | `202611170009_shopify_exact_store_uninstall_processor_v2.sql` | Uninstall receipt trigger processor; deactivates store lineage and cancels pending work/permits | **High risk:** exact-store isolation, active sends/leases, webhook receipt ordering and irreversible suppression effects |
| 21 | `202611170010_shopify_order_lifecycle_projection_v2.sql` | Replaces verified order projection RPC | Function behavior compatibility and order state transitions |
| 22 | `202611170011_shopify_refund_adjustments_v2.sql` | Refund adjustment table/index and refund projection RPC; updates order totals | **High risk:** historic refund reconciliation, currency/decimal semantics, idempotency and order amount integrity |
| 23 | `202611170012_shopify_recovery_attribution_fee_ledger_v2.sql` | Attribution policies, attribution rows, fee measurements, triggers and backfill/reconciliation functions | **Critical financial review:** exact-store paid-order attribution, delivery timestamp semantics, fee idempotency, refund adjustments, currency and legacy send-attempt backfill |
| 24 | `202611170013_shopify_ambiguous_delivery_reconciliation_v2.sql` | Replaces delivery cost reservation synchronization function | Reservation lifecycle and accepted/ambiguous/failed provider state mapping |
| 25 | `202611170014_shopify_privacy_processing_queue_v2.sql` | Privacy processing jobs, claim/complete/fail RPCs and receipt trigger | **High risk:** duplicate receipt enqueue, lease expiry, deadline handling and exact receipt linkage |
| 26 | `202611170015_shopify_customer_privacy_export_v2.sql` | Customer privacy export builder RPC | Export scope, data minimization, authorization and artifact retention |
| 27 | `202611170016_shopify_customer_redaction_impact_preview_v2.sql` | Customer redaction impact preview RPC | FK coverage and preview completeness; no mutation during preview |
| 28 | `202611170017_shopify_customer_redaction_fk_inventory_v2.sql` | FK dependency inventory RPC | Catalog visibility, schema scope and completeness of dependency enumeration |
| 29 | `202611170018_shopify_customer_redaction_send_guard_v2.sql` | Redaction guard table, send-stop triggers and guard RPCs | **Critical privacy/sending review:** existing delivery rows, trigger ordering, concurrent permit consumption and fail-closed guard behavior |
| 30 | `202611170019_shopify_exact_store_shop_redact_stop_v2.sql` | Shop-redact trigger processor; deactivates exact store and cancels pending work | **High risk:** exact-store scope, privacy receipt idempotency, pending sends/leases and irreversible state changes |
| 31 | `202611170020_shopify_redacted_store_oauth_tombstone_v2.sql` | Redacted-store tombstones and OAuth state/tombstone triggers | **High risk:** stale OAuth replay, tombstone uniqueness, retention and reinstall policy |
| 32 | `202611170021_shopify_privacy_order_scope_v2.sql` | Privacy order-scope table and expanded privacy webhook acceptance RPC | Existing receipt/order-scope rows, exact order identifiers and RPC signature compatibility |
| 33 | `202611170022_shopify_privacy_order_scope_report_v2.sql` | Replaces privacy scope report, export builder and redaction preview RPCs | Scope completeness and compatibility with earlier export/redaction signatures |
| 34 | `202611170023_shopify_privacy_deadline_monitor_v2.sql` | Privacy deadline monitor view and service-role access | Existing view name/shape, underlying status semantics and grants |
| 35 | `202611180024_shopify_privacy_completion_evidence_gate_v2.sql` | Replaces privacy completion RPC with evidence gate | **High risk:** legacy completion callers, evidence completeness and no premature closure |
| 36 | `202611180025_shopify_privacy_export_artifact_registry_v2.sql` | Artifact registry and delivery evidence tables; unique index; ENABLE/FORCE RLS | **High risk:** existing receipt artifact bindings, FORCE RLS owner/bypass behavior, service-role grants and artifact uniqueness |
| 37 | `202611180026_shopify_privacy_export_purge_lifecycle_v2.sql` | Artifact purge columns/index and claim/confirm/fail RPCs | **High risk:** existing artifacts, expiry/retention, purge lease races and proof of deletion |
| 38 | `202611180027_shopify_pixel_recovery_candidates_v2.sql` | Pixel recovery candidate table/index and refresh RPC | Pixel inbox duplicates, consent/jurisdiction prerequisites and candidate idempotency |
| 39 | `202611180028_shopify_general_recovery_opportunities_v2.sql` | Alters opportunity nullability and type constraint; adds pixel lineage index and promotion RPC | **High risk:** explicit constraint drop/recreate, existing opportunity rows, nullable lineage and cross-type uniqueness |
| 40 | `202611180029_shopify_customer_contact_evidence_v2.sql` | Contact evidence history/current tables and record RPC | **High risk:** PII retention, evidence provenance, current-row uniqueness and grants |
| 41 | `202611180030_shopify_contact_lookup_context_v2.sql` | Contact lookup context RPC | Exact connection/customer scoping and PII return surface |
| 42 | `202611180031_shopify_contact_jurisdiction_region_v2.sql` | Alters contact evidence region columns/constraints and replaces record RPC | **High risk:** explicit region constraint drops/replacements, legacy region values and RPC signature migration |
| 43 | `202611180032_shopify_pixel_delivery_eligibility_v2.sql` | Jurisdiction policy table/index and eligibility assessment RPC | Default-deny behavior, policy coverage and missing-region handling |
| 44 | `202611180033_shopify_admin_marketing_consent_lookup_v2.sql` | Admin marketing consent evidence/current tables; record and eligibility RPCs | **High risk:** authoritative consent freshness, negative evidence precedence and PII access |
| 45 | `202611180034_shopify_pixel_delivery_permits_v2.sql` | Pixel permits, send attempts, cost reservations, indexes, RLS, triggers and issue/consume/result RPCs; also revises shared cost reservation behavior | **Critical:** large multi-object migration; trigger interactions with checkout delivery; permit single-use concurrency; cost cap race safety; role grants |
| 46 | `202611180035_shopify_pixel_delivery_context_v2.sql` | Pixel delivery context RPC | Opaque ID boundary and recipient/content secrecy |
| 47 | `202611180036_shopify_pixel_provider_submission_gate_v2.sql` | Pixel provider submission authorization RPC | Consent, jurisdiction, cap, sender and suppression checks at the final submission boundary |

**Important correction:** the workflow currently lists additional files numbered 037–043 and 202611190001–004 after the entries above. The complete ordered sequence is 55? No — the 47-file count must be taken from the workflow's complete shell list, not this abbreviated table. This register must not be used as an execution manifest until the remaining entries are appended and count-checked.
