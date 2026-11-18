# Shopify privacy artifact processor V2

**Status: preparation-branch implementation. Not deployed. No Storage bucket provisioned.**

## Processing sequence

1. The service-only Edge Function claims one existing customers/data_request lease using the queue RPC.
2. It calls the existing exact-store export builder. It accepts no tenant, store, customer, or receipt identifiers from the caller.
3. It requires exported=true, completion_eligible=true, legacy_scope_review_required=false, customer_identity_found=true, exact shop_domain and customer ID match, and a records object.
4. If completeness fails, it invokes the existing fail-closed completion gate solely to release the claim into REVIEW_REQUIRED. That RPC returns false by design. No artifact row or Storage object is created.
5. For an eligible draft, the worker canonicalizes JSON, enforces 25 MiB, hashes the exact bytes, and derives a random UUID object key.
6. It inserts STAGED metadata before upload so interrupted or ambiguous uploads are discoverable by the purge lifecycle.
7. It uploads to the private bucket with upsert disabled, reads the object back, and verifies byte count and SHA-256.
8. It appends ARTIFACT_GENERATED evidence, then changes metadata from STAGED to AVAILABLE.
9. Uncertain upload, readback, evidence, or activation outcomes attempt to move the staged artifact to PURGE_PENDING. It is never downloadable on an uncertain outcome.

## Configuration

Required Edge Function secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and HENVALT_PRIVACY_ARTIFACT_TTL_SECONDS. The TTL must be an integer from 3600 to 604800 seconds. No implicit retention period is selected.

The function accepts POST only and requires the service-role bearer credential. Keep gateway JWT verification enabled. Do not expose it to the dashboard or browser.

## Storage bucket prerequisite

The bucket henvalt-privacy-exports-v2 must be created as private, with a 25 MiB maximum file size and only application/json allowed. Browser roles must have no Storage object policies. This branch does not create or change the bucket. Upload cannot succeed until a separately reviewed bucket exists.

Supabase documentation: https://supabase.com/docs/guides/storage/buckets/fundamentals and https://supabase.com/docs/guides/storage/uploads/standard-uploads

## Current hard stop

The current SQL export builder deliberately reports legacy_scope_review_required=true and completion_eligible=false. Therefore this processor currently takes the review-hold path and creates no artifact. This is intentional: incomplete export data is not serialized as a downloadable artifact.

The upload/readback/activation path is implemented but remains unreachable until the export builder's completeness contract is independently resolved and tested. The existing completion RPC remains fail-closed. Artifact availability does not imply merchant attestation, redaction completion, or Shopify request completion.

## Recovery

A staged row is inserted before upload. An uncertain upload or post-upload failure transitions the row to PURGE_PENDING when possible. If the process crashes before that transition, the staged row is discoverable by expiry and the purge claim RPC. If metadata insertion fails, no object upload is attempted. The worker never logs export payloads, customer data, object keys, credentials, or Storage response bodies.
