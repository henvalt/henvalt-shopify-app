# Shopify OAuth webhook registration hardening

## Problem

The OAuth callback previously queried `webhookSubscriptions(first:100)` once per expected topic (12 times), then performed a final verification query. Every installation therefore made up to 13 subscription-list requests before counting create mutations.

## Change

The callback now delegates registration to `webhook-registration.ts`:

1. Read the existing subscription set once.
2. If that read fails, fail closed and do not create subscriptions against an unknown state.
3. Create only expected topic/destination pairs that are missing.
4. Read the subscription set once more and verify every expected topic against the exact ingress URI.
5. Treat the final Shopify subscription list as the source of truth; a mutation response alone never marks a webhook verified.

This reduces list queries from up to 13 to exactly 2 on a healthy callback, while preserving per-topic error details and final verification. Create mutations remain sequential to avoid bursts and make per-topic failure reporting deterministic. The callback also resolves the Shopify shop GID through the GraphQL Admin API instead of the legacy REST `shop.json` endpoint. The subscription inventory is fully paginated (100 per page), with repeated-cursor and page-limit guards, so an existing matching subscription beyond the first 100 records is not missed. A schema migration adds the missing owner column referenced by the owner-bound OAuth flow and is ordered before the expiring-token finalization RPC.

## Tests

The Deno test suite covers:

- one initial list + one final list, with creates only for missing topics;
- fail-closed behavior when the initial list is unavailable (no create mutations);
- reconciliation when a create mutation reports a user error but final state confirms the subscription;
- no success when final verification cannot find the expected subscription;
- GraphQL shop identity lookup success, GraphQL errors, and missing shop IDs;
- multi-page subscription inventory and repeated-cursor fail-closed behavior;
- migration ordering for the OAuth state owner column.

## Safety boundary

This is a draft code change only. It does not change the deployed Supabase Edge Function, Shopify app version, webhook subscriptions, secrets, n8n workflows, recovery switches, email delivery, billing, or production database.
