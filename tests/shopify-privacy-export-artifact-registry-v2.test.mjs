import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/202611180025_shopify_privacy_export_artifact_registry_v2.sql", import.meta.url), "utf8");

test("privacy artifact metadata is bound to the immutable receipt and exact Shopify connection", () => {
  assert.match(migration, /UNIQUE INDEX IF NOT EXISTS shopify_privacy_receipts_artifact_binding_uidx[\s\S]*\(id, tenant_id, connection_id, app_key, shop_domain\)/);
  assert.match(migration, /FOREIGN KEY \(receipt_id, tenant_id, connection_id, app_key, shop_domain\)[\s\S]*REFERENCES henvalt\.shopify_privacy_webhook_deliveries/);
  assert.match(migration, /FOREIGN KEY \(connection_id, tenant_id, app_key, shop_domain\)[\s\S]*REFERENCES henvalt\.shopify_connections/);
});

test("artifact object names are opaque and integrity/size/expiry are constrained", () => {
  assert.match(migration, /object_key ~ '\^\[0-9a-f\]\{8\}-/);
  assert.match(migration, /sha256_hex text NOT NULL CHECK \(sha256_hex ~ '\^\[0-9a-f\]\{64\}\$'\)/);
  assert.match(migration, /byte_count BETWEEN 1 AND 26214400/);
  assert.match(migration, /CHECK \(expires_at > created_at\)/);
  assert.match(migration, /UNIQUE \(receipt_id, generation_id\)/);
  assert.match(migration, /UNIQUE \(bucket_id, object_key\)/);
});

test("incomplete artifacts cannot become available and purge state is explicit", () => {
  assert.match(migration, /state <> 'AVAILABLE'[\s\S]*completeness_status = 'COMPLETE_FOR_MERCHANT_REVIEW'/);
  assert.match(migration, /'STAGED', 'AVAILABLE', 'PURGE_PENDING', 'PURGED', 'FAILED'/);
  assert.match(migration, /state = 'PURGED' AND purged_at IS NOT NULL/);
});

test("delivery evidence is append-only and records honest download/attestation states", () => {
  assert.match(migration, /'DOWNLOAD_AUTHORIZED'[\s\S]*'DOWNLOAD_STREAM_STARTED'[\s\S]*'DOWNLOAD_STREAM_FAILED'[\s\S]*'MERCHANT_ATTESTED_PROVIDED_TO_SUBJECT'/);
  assert.match(migration, /GRANT SELECT, INSERT ON henvalt\.shopify_privacy_delivery_evidence_v2 TO service_role/);
  assert.doesNotMatch(migration, /GRANT [^;]*UPDATE[^;]*shopify_privacy_delivery_evidence_v2/);
  assert.doesNotMatch(migration, /GRANT [^;]*DELETE[^;]*shopify_privacy_delivery_evidence_v2/);
});

test("artifact and evidence metadata are isolated from browser roles and no bucket is created", () => {
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /FORCE ROW LEVEL SECURITY/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_privacy_export_artifacts_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
  assert.match(migration, /REVOKE ALL ON henvalt\.shopify_privacy_delivery_evidence_v2[\s\S]*FROM PUBLIC, anon, authenticated, service_role/);
  assert.doesNotMatch(migration, /INSERT INTO storage\.buckets|CREATE POLICY[\s\S]*storage\.objects/);
});
