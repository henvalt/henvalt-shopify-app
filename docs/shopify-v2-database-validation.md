# Disposable database validation

The GitHub Actions job `shopify-database-migration-validation` creates a fresh PostgreSQL 17 service, installs a synthetic baseline for the pre-existing HENVALT tables/functions, applies candidate migrations 001-006 in order, then exercises:
- app-aware OAuth finalization and exact connection binding;
- raw route-token hashing (no plaintext token persistence);
- Shopify webhook HMAC acceptance and delivery idempotency;
- Shopify privacy webhook HMAC acceptance, exact-store linkage, review-only status, and idempotency;
- rejection of invalid privacy HMAC;
- service-role-only RPC permissions.

All data and secrets in the fixture are synthetic. This does not connect to the live Supabase project and does not replace a full replay against a sanitized copy of the production schema. The legacy OAuth finalizer is represented by a signature-compatible test stub, so this job validates the wrapper's contract and transaction behavior but not the internal production finalizer implementation.
