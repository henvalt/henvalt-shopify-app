# Disposable database validation

The GitHub Actions job `shopify-database-migration-validation` creates a fresh PostgreSQL 17 service, installs a synthetic baseline for the pre-existing HENVALT tables/functions, applies candidate migrations 001-006 in order, then exercises:
- app-aware OAuth finalization and exact connection binding;
- raw route-token hashing (no plaintext token persistence);
- Shopify webhook HMAC acceptance and delivery idempotency;
- Shopify privacy webhook HMAC acceptance, exact-store linkage, review-only status, and idempotency;
- two stores sharing one tenant remain distinct, including same delivery IDs across stores and rejection of mismatched immutable shop IDs;
- rejection of invalid privacy HMAC;
- service-role-only RPC permissions.

All data and secrets in the fixture are synthetic. This does not connect to the live Supabase project and does not replace a full replay against a sanitized copy of the production schema. The legacy OAuth finalizer is represented by a signature-compatible test stub, so this job validates the wrapper's contract and transaction behavior but not the internal production finalizer implementation.

The V2 inbox RPCs also reject reuse of the same delivery ID with a different raw-body digest; exact duplicate retries are acknowledged idempotently, while body-mismatch replays are rejected.

## Future activation checklist (not authorized or performed)

1. Create the Partner-owned public Shopify app only after the owner completes Shopify Partner registration and approves the one-time registration cost. The existing merchant-owned app is not transferable and remains untouched.
2. Generate the public app's client ID and secret, then store the secret in Supabase Vault through the approved secure process. Add a registry row with the chosen stable app key and the Vault secret reference. Do not reuse the legacy app's secret or create duplicate secret copies.
3. Apply migrations 001–006 only after reviewing the full production schema, testing a sanitized production-schema clone, and obtaining separate approval. The disposable PostgreSQL fixture is not a substitute for that clone.
4. Configure the V2 OAuth Edge Function with the new app's client ID and callback URL. The callback must be the V2 function route; the current Shopify app TOML remains unchanged.
5. Configure the protected Worker-to-Edge ingress URL and matching internal bearer token on both sides. The per-install route token is issued only by successful app-aware OAuth finalization.
6. Configure the public app's three mandatory compliance topics to the app-key privacy V2 route. This currently records receipts only; do not launch until exact-store export and redaction processors can complete requests within Shopify's compliance deadlines.
7. Implement and verify the connection-aware downstream adapter from the verified webhook inbox to canonical events and the existing HENVALT recovery system. The current V2 ingress stops at the durable inbox; it does not yet feed n8n or create recoveries.
8. Run an end-to-end two-store test: separate installs, signed webhooks, duplicate/replay mismatch, uninstall, reauthorization/token rotation, privacy requests, recovery attribution and billing isolation. Only then plan a controlled cutover.

No activation step above has been performed. The branch-only work does not create a new Shopify app, seed the registry, apply production migrations, deploy Edge Functions/Worker code, change n8n, or edit the live Shopify app configuration.
