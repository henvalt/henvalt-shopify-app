# Store-scope uniqueness and constraint audit

**Status:** read-only catalog inspection of deployed `henvalt` indexes. No database objects were changed.

## Existing uniqueness keys that are tenant-scoped

| Table | Current unique key | Multi-store consequence |
|---|---|---|
| `customers` | `(tenant_id, shopify_customer_id)` | Same Shopify customer ID in two stores of one tenant collides |
| `checkouts` | `(tenant_id, shopify_checkout_id)`; partial `(tenant_id, checkout_token)` | Same checkout ID/token across stores collides |
| `canonical_events` | `(tenant_id, idempotency_key)` | Same event key across stores collides |
| `webhook_events` | `(tenant_id, idempotency_key)`; `(tenant_id,source,source_event_id)` | Same Shopify webhook/event identifier across stores collides |
| `opportunities` | `(tenant_id, idempotency_key)` | Store events can collide on idempotency |
| `recovery_interventions` | `(tenant_id,idempotency_key)`; `(tenant_id,sequence_id,step_number)` | Parent lineage must first be store-bound |
| `delivery_requests` | `(tenant_id,idempotency_key)`; `(tenant_id,intervention_id)` | Store lineage must be inherited and validated |
| `orders` | `(tenant_id,shopify_order_id)` | Same order ID across stores collides |
| `order_attributions` | `(tenant_id,order_id)` | Attribution identity is tenant-scoped |
| `revenue_ledger` | recovery unique `(tenant_id,order_id)`; adjustment keys include tenant/order/source event | Ledger identity is tenant-scoped |
| `billing_measurements` | unique `(tenant_id,ledger_entry_id)` (two equivalent unique indexes observed) | No store identity on measurement |
| `billing_usage_charges` | `(tenant_id,idempotency_key)`; one per measurement | Usage charge is tenant-scoped |
| `email_suppressions` | active unique `(tenant_id,email_normalized)` | One store unsubscribe may suppress same email across tenant |
| `customer_conversations` | `(tenant_id,delivery_request_id)`; `(tenant_id,id)`; globally unique reply-token hash | Conversation needs originating delivery connection lineage |
| `unsubscribe_tokens` | globally unique token hash | Token itself is safe random identifier, but token record lacks connection FK |
| `shopify_privacy_requests` | unique `webhook_id` | Request table lacks app key and connection FK |
| `billing_accounts` | primary key `tenant_id`; unique provider subscription ID | Cannot hold independent Shopify billing account per store in one tenant |

## Existing connection-specific protections

- `shopify_connections.shop_domain` is globally unique, and `(tenant_id,shopify_shop_id)` is unique.
- `pixel_keys.shopify_connection_id` is a non-null FK to `shopify_connections(id)`, with an index on connection/active/created time. Preserve this design.
- `shopify_privacy_requests.webhook_id` uniqueness is a useful provider idempotency boundary; retain it while adding app/connection identity.
- `conversation_messages.provider_event_id` is unique; `provider_events(provider,event_hash)` is unique. These are provider event idempotency keys and should not be casually changed to connection-scoped without verifying provider event semantics.

## Important billing design decision

The live `billing_accounts` primary key is `tenant_id`, and billing summary/claim RPCs operate at tenant level. A future schema must explicitly decide:
- Shopify Billing: per store/connection, if each Shopify app installation owns its own subscription.
- Paddle or external billing: potentially tenant-level, if the merchant organization is the billed customer.
- Mixed providers: provider/account model must support the provider's actual billing principal, not assume all subscriptions are tenant-level.

Do not add `shopify_connection_id` to billing tables and assume the model is settled. First define whether a tenant can have multiple billed stores, how tenant-wide revenue is apportioned, and how one store's subscription cancellation affects only that store.

## Migration design constraints

- Add nullable store connection references first; keep existing tenant FKs and tenant membership semantics.
- Use composite FKs/unique indexes only after all referenced parents carry the connection ID and backfill/collision reports are reviewed.
- Existing tenant-scoped unique indexes may need replacement with connection-scoped variants, but only after duplicate detection and RPC conflict-target updates are prepared together.
- Do not change the unique global shop domain key; one Shopify shop should resolve to one active HENVALT connection record.
- Email suppression needs an explicit store-vs-tenant policy and likely a store-scoped key plus a separately represented optional global suppression.
- Preserve globally unique cryptographic reply/unsubscribe token hashes; bind their records to the exact originating connection through their parent lineage.
- Keep the two equivalent billing-measurement unique indexes in mind; do not add another duplicate index.

## Still not complete

This catalog report does not yet enumerate every non-unique index, check constraint, trigger, view, FK delete action, function caller or dynamic SQL reference. The full migration remains blocked on that inventory and on explicit billing/suppression scope decisions.
