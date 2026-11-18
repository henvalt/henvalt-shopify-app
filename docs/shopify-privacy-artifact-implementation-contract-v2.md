# Privacy export artifact implementation contract — V2

**Status: branch-only engineering specification. Not deployed. Not a legal determination.**

This contract turns the export-delivery design into an implementable, testable boundary. It deliberately does not create a production bucket, schema, Edge Function, scheduled worker, or merchant UI.

## 1. Non-negotiable trust boundaries

- The webhook receipt is the root of authority. Every artifact and audit event must bind to the same immutable `receipt_id`, `tenant_id`, `connection_id`, `app_key`, and normalized `shop_domain`.
- Revalidate that full tuple at claim, build, artifact write, download authorization, attestation, purge, and completion. Never accept tenant/store identifiers from a browser as authority.
- The only artifact writer, reader, and purger are service-side processors. Browser roles receive no Storage object access and no direct table writes.
- The bucket is private. No public URL, signed URL, service key, raw Storage key, or export body may appear in webhook responses, logs, analytics, or browser-visible database rows.
- The existing V2 completion RPC remains fail-closed until artifact, delivery and redaction postcondition evidence are durable and tested.

## 2. Proposed service-only schema (not yet a migration)

### `henvalt.shopify_privacy_export_artifacts_v2`

| Column | Type / rule | Purpose |
| --- | --- | --- |
| `id` | uuid primary key | Internal artifact identity |
| `receipt_id` | uuid not null | Exact privacy receipt |
| `tenant_id` | uuid not null | Same-tenant fence |
| `connection_id` | uuid not null | Immutable Shopify store binding |
| `app_key` | text not null | App identity snapshot |
| `shop_domain` | text not null | Normalized store snapshot |
| `artifact_version` | integer not null, positive | Format version |
| `generation_id` | uuid not null | Idempotency key for one build attempt |
| `bucket_id` | text not null, fixed allowlist | Private bucket identifier |
| `object_key` | text not null, random opaque key | Never a customer/store/request identifier |
| `sha256_hex` | text not null, 64 lowercase hex | Integrity digest |
| `byte_count` | bigint not null, positive and bounded | Size verification |
| `content_type` | text not null, allowlisted | Download type |
| `completeness_status` | enum: `COMPLETE_FOR_MERCHANT_REVIEW`, `INCOMPLETE`, `REVIEW_REQUIRED` | Explicit scope result |
| `manifest_json` | jsonb not null, schema-validated and non-PII | Included categories and per-order outcomes |
| `created_at` | timestamptz not null | Build time |
| `expires_at` | timestamptz not null | Short fixed retention window |
| `purged_at` | timestamptz nullable | Confirmed object purge time |
| `state` | enum: `STAGED`, `AVAILABLE`, `PURGE_PENDING`, `PURGED`, `FAILED` | Artifact lifecycle |

Constraints:
- Unique `(receipt_id, generation_id)`; unique `(bucket_id, object_key)`.
- Composite foreign keys must prove the receipt's tenant/connection tuple. The connection must match tenant, app key, and shop domain.
- `expires_at > created_at`; reject oversized artifacts before Storage write.
- The manifest must not contain names, emails, phone numbers, raw order IDs, access tokens, signed URLs, or export data. It contains only category names, counts, opaque per-item outcome codes, completeness booleans, and schema version.
- A new generation supersedes but does not silently overwrite a prior object. The old object is queued for purge and remains auditable until purge is confirmed.

### `henvalt.shopify_privacy_delivery_evidence_v2`

Append-only events with: `id`, `receipt_id`, `tenant_id`, `connection_id`, `artifact_id` nullable, `actor_user_id` nullable, `event_type`, `outcome_code`, `correlation_id`, `created_at`.

Allowed event types:
- `ARTIFACT_GENERATED`
- `DOWNLOAD_AUTHORIZED`
- `DOWNLOAD_STREAM_STARTED`
- `DOWNLOAD_STREAM_FAILED`
- `MERCHANT_ATTESTED_PROVIDED_TO_SUBJECT`
- `ARTIFACT_PURGE_REQUESTED`
- `ARTIFACT_PURGED`
- `ARTIFACT_PURGE_FAILED`

No raw payload, PII, object key, URL, claim token, or request body is allowed in this table. The attestation event records that an authenticated owner/admin asserts they provided the response; it is not proof the subject received it.

## 3. Artifact state machine

```text
BUILDING
  ├─ validation / completeness failure ─> REVIEW_REQUIRED (no artifact available)
  └─ verified manifest + private object + digest ─> AVAILABLE
AVAILABLE
  ├─ expiry / revocation ─> PURGE_PENDING
  └─ authenticated download ─> AVAILABLE (append evidence only)
PURGE_PENDING
  ├─ object delete confirmed + metadata tombstoned ─> PURGED
  └─ delete failure ─> PURGE_PENDING (retry + alert)
```

The privacy receipt itself stays `REVIEW_REQUIRED` until all request-specific requirements have been satisfied. An artifact being available for merchant review is not equivalent to the merchant having provided it to the data subject.

## 4. Build protocol

1. Claim a receipt using the existing leased queue and single-use token.
2. Re-read receipt, job, and connection using the exact tuple; reject stale claim, expired lease, duplicate generation, or mismatch.
3. Run the exact-store export builder and produce a manifest from an explicit allowlist of data categories/fields.
4. Compare requested order IDs to the full requested list. Any unmatched ID, unresolved email-only identity, unbound legacy row, incomplete category, or unsupported identifier form sets `REVIEW_REQUIRED`.
5. Serialize deterministically; enforce a configured maximum byte size; calculate SHA-256 over the exact bytes to be stored.
6. Write to private Storage using a cryptographically random opaque object key. Do not derive it from receipt, tenant, shop, customer, or order identifiers.
7. Read object metadata back and verify byte count and digest before marking the artifact `AVAILABLE`.
8. Insert the `ARTIFACT_GENERATED` event and persist the artifact row in a transactionally safe sequence. If DB persistence fails after object upload, leave a recoverable orphan record/job and purge it through reconciliation; never report success.
9. Keep the queue job `REVIEW_REQUIRED` unless all Shopify response obligations and merchant-facing workflow requirements are met. The current export is a HENVALT data inventory, not a substitute for data HENVALT never collected.

## 5. Authenticated download protocol

Use an Edge Function proxy, not a signed URL.

1. Require a valid Supabase Auth bearer token and call Auth `getUser`; do not authorize from decoded JWT claims alone.
2. Resolve the actor's current tenant membership from the database. Require OWNER or ADMIN and verify the actor is still active.
3. Load the artifact by opaque artifact ID, then revalidate the receipt's complete immutable store tuple and tenant membership. Ignore any client-provided tenant/store ID.
4. Require `state = AVAILABLE`, `expires_at > now()`, `purged_at IS NULL`, receipt not redacted/revoked, and object metadata/digest valid.
5. Append `DOWNLOAD_AUTHORIZED`, then `DOWNLOAD_STREAM_STARTED`; stream bytes from private Storage with `Content-Disposition: attachment`, `Cache-Control: no-store`, and `X-Content-Type-Options: nosniff`.
6. If the upstream stream fails, append `DOWNLOAD_STREAM_FAILED`. Never set a field named `delivered_to_subject` based on handler entry or stream start.
7. Provide a separate authenticated merchant action to attest “provided to data subject”. Require explicit confirmation and record actor, timestamp, artifact version, and the exact statement attested. This still represents merchant attestation, not independently verified receipt by the subject.

## 6. Purge and deadline processing

- Expiry is an actual deletion obligation. A scheduled service worker must select expired artifacts, verify exact tuple, delete the Storage object through the Storage API, confirm absence, tombstone the manifest, and append purge evidence.
- Retry transient failures with bounded exponential backoff. After the retry threshold, retain `PURGE_PENDING`, emit an alert, and expose it to the deadline monitor. Never mark purged when the Storage delete response is ambiguous.
- The monitor must separately report: approaching Shopify response deadline, request still review-required, artifact expired but not purged, and missing merchant attestation.
- The current SQL deadline view is read-only. It is not a scheduler or alert channel; a worker/alert integration is still required.

## 7. RLS and privilege contract

- Both tables live in private `henvalt`, not an exposed schema.
- Enable and FORCE RLS as defense in depth; no policies for `anon` or `authenticated`.
- Revoke table privileges from `PUBLIC`, `anon`, and `authenticated`; grant only required operations to `service_role`.
- Any privileged RPC must pin `search_path = ''`, schema-qualify every object, revoke PUBLIC execution, and be granted only to `service_role`.
- Do not create policies that let merchants read object keys or manifest JSON directly. Merchant list/detail APIs return only safe labels, status, expiry and opaque artifact IDs.
- Storage bucket policy must deny browser roles; service-side code uses the server credential without exposing it to the client.

## 8. Required tests before implementation is considered complete

### SQL adversarial tests
- Cross-tenant receipt/artifact tuple rejected.
- Same-tenant but different-store connection rejected.
- Mismatched app key or shop domain rejected.
- Duplicate generation and object-key collision rejected.
- Invalid digest, size, content type, expiry and manifest fields rejected.
- Browser roles cannot select, insert, update, or delete either table.
- PUBLIC/anon/authenticated cannot execute privileged RPCs.
- Stale claim token, expired lease, revoked connection and redacted receipt cannot create an artifact or authorize download.

### Edge Function tests
- Missing/invalid bearer token, disabled user, non-member, viewer role, stale membership, wrong tenant and wrong store all fail closed.
- No service credential, object key, signed URL, customer data or export bytes appear in errors/logs.
- Expired, purged, revoked, review-required, and digest-mismatched artifacts cannot be streamed.
- Interrupted stream creates failure evidence and never merchant attestation.
- A merchant attestation requires a current owner/admin and is immutable/auditable.

### Storage and worker tests
- Bucket is private and inaccessible from public/anon/authenticated clients.
- Object upload digest/size round-trip is verified.
- Failed DB write after upload is reconciled without false availability.
- Expired object is actually deleted; ambiguous deletion remains pending.
- Repeated purge is idempotent.
- Deadline monitor surfaces stuck builds, review-required requests, missing attestation, and purge failures.

## 9. Release gate

Do not create the bucket or apply schema until the exact table names/constraints have been reconciled with the current V2 queue and receipt definitions, the Storage API behavior is verified against current Supabase docs, and the migration can be generated using the Supabase CLI workflow. Do not deploy the Edge Function or worker until adversarial tests pass. Do not replace the fail-closed completion RPC until the export and redaction evidence processors both exist.

**Current status:** specification only. Production Supabase remains untouched; no bucket, schema, function, worker, or n8n workflow has been changed.
