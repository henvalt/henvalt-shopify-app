# Secondary Recovery, Conversation and Billing Lineage Audit

**Inspection date:** 2026-11-16  
**Environment:** live HENVALT Supabase production, read-only function catalog/source inspection  
**Branch:** `prep/public-app-hardening-2026-11-15`  
**Safety:** no function, table, row, trigger, workflow, or deployment was changed.

## Executive result

A second function-body pass confirms that store identity is still lost after the initial candidate query. The following deployed functions were inspected directly: `schedule_next_recovery_intervention`, `process_mailersend_inbound_reply`, `create_unsubscribe_token`, `validate_unsubscribe_token`, `unsubscribe_customer_by_token`, `control_plane_billing_summary`, `control_plane_revenue_series`, `measure_billing_entry`, `measure_billing_period`, `evaluate_order_attribution`, and `stop_recovery_after_order`.

## 1. Follow-up sequence scheduler

Deployed `schedule_next_recovery_intervention(p_delivery_request_id)` validates tenant relationships between delivery, intervention, sequence, opportunity and customer. It checks that the cart/browse/checkout opportunity's shop domain maps to an active connection in the tenant. That is not enough to prove the whole chain belongs to that connection.

The scheduler's conversion/advancement checks remain tenant-scoped:
- Browse: any tenant order for the same customer after opportunity creation can stop the sequence.
- Cart: any tenant order for the same customer after last activity can stop it.
- Cart-to-checkout: a tenant checkout matching customer and cart token can stop it.
- Checkout: any tenant order matching checkout ID can stop it.
- Email suppression checks tenant/customer or tenant/email.
- Sender identity and MailerSend provider configuration are tenant-wide.

**Required invariant:** resolve one trusted connection from the opportunity's immutable source lineage, then require the order, checkout, customer, sequence, intervention, delivery request and active connection to match it. Missing or conflicting lineage must prevent scheduling. Provider credentials may remain tenant-scoped, but sender-brand selection needs an explicit per-store policy.

## 2. Inbound replies and opt-out

Deployed `process_mailersend_inbound_reply(p_payload, p_raw_body_base64)` routes replies using the hashed reply token, tenant, conversation and matching sender email. The conversation links to customer, opportunity and recovery IDs, so this is stronger than an email-only lookup.

However, the conversation and its upstream recovery lineage do not carry an explicit store connection in the inspected contract. On OPT_OUT, the function:
- sets the tenant customer's email consent false;
- inserts/updates a tenant-scoped email suppression keyed by tenant/email;
- invokes tenant-scoped `suppress_customer_recovery`.

A reply from one store can therefore suppress another store's recovery if the tenant shares a customer/email identity. The inbound provider event is stored with tenant identity but no connection identity.

**Required contract:** persist the originating connection on the conversation from its source opportunity/delivery lineage; verify it on inbound reply routing; apply store-scoped opt-out by default, with tenant-wide opt-out only if the merchant explicitly selects that policy. Preserve the raw inbound event and audit receipt.

## 3. Unsubscribe token lifecycle

- `create_unsubscribe_token` derives tenant/customer from intervention → opportunity → customer and stores intervention ID in token metadata, but no explicit connection ID.
- `validate_unsubscribe_token` only checks the token hash exists; it does not return originating store/suppression scope or check used/expiry state.
- `unsubscribe_customer_by_token` updates the tenant customer, creates tenant-scoped suppression, calls tenant-scoped recovery suppression, and marks the token used.

The current behavior is an implicit tenant-wide opt-out. The originating intervention ID in metadata is useful lineage, but the validator and consumer do not enforce it.

**Required contract:** token validation returns a trusted immutable connection and explicit policy scope. A token must be tied to the exact intervention/delivery/customer lineage. Do not infer store from email.

## 4. Billing and revenue reporting

### Billing principal

The live schema audit found `billing_accounts` is keyed by `tenant_id`, and `measure_billing_entry` / `measure_billing_period` create measurements by tenant. This represents one billing account per tenant, not independent Shopify billing subscriptions per store. The public-app design must decide and document whether the commercial principal is the tenant, each store, or a hybrid before changing billing keys or subscriptions.

### Billing summary

`control_plane_billing_summary(p_shop_domain)` resolves a shop domain to a tenant, then:
- reads the tenant's single billing account;
- aggregates all tenant billing measurements for the calendar month;
- aggregates all tenant email usage measurements for the billing interval.

It therefore reports tenant-wide billing and email usage under a store-specific endpoint. That may be correct only if HENVALT deliberately bills the whole tenant as one account and clearly labels the scope. It is misleading if the dashboard implies store-only numbers.

### Revenue series

`control_plane_revenue_series(p_shop_domain,...)` resolves an active shop to a tenant, then sums all tenant revenue-ledger rows for the requested time window. The returned series is therefore tenant-wide, not store-specific.

### Measurement

`measure_billing_entry` loads a ledger entry by ID and derives tenant/amount/currency; `measure_billing_period` iterates tenant ledger entries. Both are tenant-principal operations. They need not be store-scoped if billing remains tenant-level, but every ledger row must first have validated same-store attribution so a cross-store match cannot become billable.

**Required decision:** choose tenant/store/hybrid billing principal explicitly. Regardless of that choice, revenue and email usage reporting must state its scope, and a store-specific dashboard query must filter by the exact connection. A tenant-level performance fee must only include confirmed, same-connection attribution and must not treat POSSIBLE/customer-only attribution as billable.

## 5. Attribution and stop-recovery confirmation

The inspected `evaluate_order_attribution` and `stop_recovery_after_order` definitions confirm earlier findings:
- tracking-token attribution is tenant-scoped;
- checkout attribution matches tenant + checkout ID;
- customer fallback matches tenant + customer ID;
- checkout fallback in stop-recovery matches tenant + checkout ID;
- tracking-token fallback matches tenant + token;
- no same-connection comparison exists between order, opportunity, intervention and recovery sequence.

Customer-only POSSIBLE matches are non-billable and do not directly stop a sequence, which is a useful guard. It does not remove cross-store risk from CONFIRMED/PROBABLE token/checkout matches or store-reused external IDs.

## 6. Additional regression requirements

Add the following two-store cases to the main regression matrix:
1. Store A follow-up scheduler must continue when the same customer places an order in Store B.
2. Store A cart sequence must continue when Store B receives a checkout with the same customer/cart token.
3. Store A checkout sequence must continue when Store B receives an order with a reused checkout identifier.
4. An inbound reply token from Store A must resolve only to Store A's conversation and recovery.
5. An opt-out reply from Store A must not silently suppress Store B unless tenant-wide scope was explicitly configured.
6. An unsubscribe token from Store A must expose Store A's trusted scope and must not suppress Store B by default.
7. Store-specific billing summary/revenue series must exclude Store B ledger and email usage rows.
8. Tenant-level billing, if selected, must clearly label tenant scope and aggregate only valid, same-store attributed ledger rows.
9. Duplicate external IDs and customer emails across stores must not collapse into one HENVALT customer or one billable attribution.

## Explicit non-actions

This is a read-only audit. No production SQL, DDL, data, RLS, grants, functions, triggers, n8n workflows, Cloudflare bindings/secrets, or Shopify app settings were changed. No migration was applied and no workflow was executed.
