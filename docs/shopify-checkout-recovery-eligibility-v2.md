# Exact-store checkout recovery eligibility V2

**Status:** candidate implementation on `prep/public-app-hardening-2026-11-15`; not applied or deployed.

## What it does

The service-only `henvalt.refresh_shopify_checkout_recovery_candidates_v2(interval, limit)` creates or refreshes an eligibility record only when:

- the exact-store checkout is still `OPEN`;
- its last update is older than the supplied inactivity policy;
- the exact Shopify connection is active;
- its registered Shopify app is active;
- the owning HENVALT tenant is active; and
- no order identity exists with the same connection and checkout token.

A matching order in Store A cannot suppress a checkout in Store B, even when both stores reuse the same checkout token. Closed checkouts are marked `CHECKOUT_CLOSED`; matching orders mark existing candidates `CONVERTED`. Both states are terminal for the same candidate key and survive later refresh upserts, so a contradictory or delayed open projection cannot resurrect previously closed work.

## Important boundaries

The candidate contains no email, phone, address, or raw webhook payload. It is only a pseudonymous eligibility record named `READY_FOR_CONTACT_RESOLUTION`.

It does **not** create a legacy opportunity, enqueue n8n, select a recipient, check marketing consent, send an email, create an attribution, or authorize delivery. The RPC returns `delivery_authorized: false` by design.

The inactivity interval is supplied by the trusted server caller (15 minutes to 7 days); no arbitrary recovery delay is hard-coded. The eventual merchant-facing policy must be configured and tested before activation.

## Still required before real recovery

1. A consent-aware, exact-store contact-resolution path with a lawful basis and store-scoped opt-out.
2. Exact-store opportunity and intervention lineage, including store-scoped reply and unsubscribe handling.
3. A delivery authorization RPC that revalidates the complete chain, recipient, consent, active app/store/tenant, idempotency and suppression immediately before send.
4. An adapter into the existing three n8n workflows only after those contracts are store-safe.
5. Two-store end-to-end tests for email, reply, opt-out, conversion, attribution, revenue and uninstall behavior.

## Safety

This is a branch-only candidate. No production migration, data, n8n workflow, Worker, Edge Function, Shopify setting or app release is changed.
