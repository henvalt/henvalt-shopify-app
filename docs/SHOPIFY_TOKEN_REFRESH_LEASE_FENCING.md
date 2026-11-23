# Shopify expiring offline-token refresh lease fencing

**Status:** draft candidate only  
**Live audit date:** 2026-11-23

## Verified live defects

The live claim RPC serializes claims with a transaction-scoped advisory lock and a row lock, then stores only the lease expiry timestamp. The live completion RPC checks that the lease timestamp is still in the future but does not identify the worker that owns it. The live failure RPC updates by shop domain alone and can clear any active lease.

A worker whose request outlives its lease can therefore complete or fail after another worker has claimed a replacement lease. This can overwrite or disrupt a newer token pair.

The live claim function's shop-domain regex was also tested directly against the live database. With standard_conforming_strings enabled, the double-escaped-dot pattern did not match demo.myshopify.com; the single-escaped-dot pattern did. The candidate migration corrects the pattern. The checked-in token-storage migration did not declare the live lease timestamp/error columns, so this migration also adds all lease fields with IF NOT EXISTS to remain safe on both the current live schema and a clean migration replay.

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
- The lease is ten minutes, while the Shopify HTTP request timeout remains fifteen seconds. Supabase currently caps Edge Function wall-clock duration at 150 seconds on Free and 400 seconds on paid plans; ten minutes exceeds those documented runtime limits. The longer lease reduces overlap; the lease ID remains the correctness fence if execution is delayed. See https://supabase.com/docs/guides/functions/limits.

## Shopify-specific constraint

Shopify explicitly requires refresh operations to be serialized per shop and warns that concurrent refreshes can leave one worker holding a token already replaced by another. Shopify also recommends atomically storing the returned access-token/refresh-token pair. Its newer retry behavior allows retrying the previously presented refresh token after ambiguous transient failures, but that is a recovery path—not permission to run concurrent refreshes.

References:
- https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens
- https://shopify.dev/changelog/posts/more-resilient-refreshes-for-expiring-offline-access-tokens

## n8n integration and rollout ordering

The active HENVALT_RECOVERY workflow runs every minute. Its scheduled path reaches the stale-work repair node, then the due-token query, then the token-refresh Edge Function. At the 2026-11-23 13:40:28 UTC execution, the due-token query returned zero rows and the refresh HTTP node did not execute. The live test-shop token snapshot at 13:41:10 UTC showed 46 minutes remaining, no active lease, no refresh error, and no reauthorization requirement.

The n8n HTTP Request node currently has a 20-second timeout. The Edge Function's Shopify request timeout is 15 seconds, before accounting for the claim and completion RPCs. Increase the n8n timeout to at least 30 seconds in the same controlled rollout; do not change the live workflow as part of this draft.

Recommended rollout order:
1. Pause the scheduled recovery workflow or isolate its token-refresh branch before changing the RPC contract.
2. Drain in-flight executions and allow the existing 90-second lease window to expire (use at least a two-minute quiet period).
3. Deploy the new Edge Function and apply the migration while the scheduled caller remains paused.
4. Verify that a claim returns a UUID lease ID, that stale completion/failure are no-ops, and that the current owner can atomically persist the pair.
5. Set the n8n caller timeout to at least 30 seconds, then resume the schedule.

Do not deploy the Edge Function before the migration while the schedule is running: the old claim RPC does not return a lease ID, so the new handler correctly fails closed but cannot safely release that old lease. Do not apply the migration while an old worker may still be in flight.

## Verification

The Deno regression suite covers service-role gating, malformed/missing lease IDs, successful fenced completion, stale completion, network failure, terminal provider rejection, malformed provider token pairs, persistence failure cleanup, non-claimed conflicts, and invalid shop domains.

The SQL contract workflow checks lease ownership, lease expiry, stale cleanup, function privileges, legacy RPC removal, and the shop-domain regex. It does not execute the migration against production. Before rollout, the SQL should also be exercised against a disposable PostgreSQL/Supabase-compatible test database and the deployed Edge Function should be verified against the migrated RPC signatures.

## Rollout safety

- No production migration or function deployment is included.
- No Shopify API calls, credential rotations, token refreshes, emails, charges, or recovery switches are triggered by CI.
- Keep the existing refresh worker disabled until the migration and Edge Function are deployed together in a controlled maintenance window.
- The old RPC signatures are dropped by the candidate migration because leaving them callable would preserve an unfenced write path. The migration restores service_role-only execution on the new signatures.
