# Shopify expiring offline-token refresh lease fencing

**Status:** draft candidate only  
**Live audit date:** 2026-11-23

## Verified live defects

The live claim RPC serializes claims with a transaction-scoped advisory lock and a row lock, then stores only the lease expiry timestamp. The live completion RPC checks that the lease timestamp is still in the future but does not identify the worker that owns it. The live failure RPC updates by shop domain alone and can clear any active lease.

A worker whose request outlives its lease can therefore complete or fail after another worker has claimed a replacement lease. This can overwrite or disrupt a newer token pair.

The live claim function's shop-domain regex was also tested directly against the live database. With standard_conforming_strings enabled, the double-escaped-dot pattern did not match demo.myshopify.com; the single-escaped-dot pattern did. The candidate migration corrects the pattern.

## Candidate design

- Each claim generates a random UUID lease ID and stores it alongside the lease expiry.
- The claim RPC returns the lease ID to the Edge Function.
- Completion and failure RPCs require that exact lease ID and a still-live lease.
- A stale completion returns STALE_REFRESH_LEASE without writing Vault secrets or expiry fields.
- A stale failure is a no-op and returns recorded=false.
- Successful completion persists both Vault secrets and both expiry timestamps in one database transaction, then clears the lease ID and expiry.
- Every failure path passes the original lease ID; a stale worker cannot clear a replacement lease.
- The Edge Function refuses a malformed claim response before contacting Shopify.
- The Edge Function returns HTTP 409 for a stale completion and does not attempt a second cleanup RPC.
- The lease is ten minutes, while the Shopify HTTP request timeout remains fifteen seconds. The longer lease reduces overlap; the lease ID remains the correctness fence if execution is delayed.

## Shopify-specific constraint

Shopify explicitly requires refresh operations to be serialized per shop and warns that concurrent refreshes can leave one worker holding a token already replaced by another. Shopify also recommends atomically storing the returned access-token/refresh-token pair. Its newer retry behavior allows retrying the previously presented refresh token after ambiguous transient failures, but that is a recovery path—not permission to run concurrent refreshes.

References:
- https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens
- https://shopify.dev/changelog/posts/more-resilient-refreshes-for-expiring-offline-access-tokens

## Verification

The Deno regression suite covers service-role gating, malformed/missing lease IDs, successful fenced completion, stale completion, network failure, terminal provider rejection, malformed provider token pairs, persistence failure cleanup, non-claimed conflicts, and invalid shop domains.

The SQL contract workflow checks lease ownership, lease expiry, stale cleanup, function privileges, legacy RPC removal, and the shop-domain regex. It does not execute the migration against production. Before rollout, the SQL should also be exercised against a disposable PostgreSQL/Supabase-compatible test database and the deployed Edge Function should be verified against the migrated RPC signatures.

## Rollout safety

- No production migration or function deployment is included.
- No Shopify API calls, credential rotations, token refreshes, emails, charges, or recovery switches are triggered by CI.
- Keep the existing refresh worker disabled until the migration and Edge Function are deployed together in a controlled maintenance window.
- The old RPC signatures are dropped by the candidate migration because leaving them callable would preserve an unfenced write path. The migration restores service_role-only execution on the new signatures.
