-- HENVALT exact-store privacy export artifact registry V2.
-- PREPARATION ONLY. Creates metadata/evidence tables; it does NOT create a
-- Storage bucket, upload/download objects, or enable request completion.
-- Requires migrations 001, 006, 014 and 024.

BEGIN;

-- A composite key lets artifact/evidence rows prove the full immutable
-- receipt identity, rather than relying on receipt UUID alone.
CREATE UNIQUE INDEX IF NOT EXISTS shopify_privacy_receipts_artifact_binding_uidx
  ON henvalt.shopify_privacy_webhook_deliveries
    (id, tenant_id, connection_id, app_key, shop_domain);

CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_export_artifacts_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  connection_id uuid NOT NULL,
  app_key text NOT NULL,
  shop_domain text NOT NULL,
  artifact_version integer NOT NULL DEFAULT 1 CHECK (artifact_version > 0),
  generation_id uuid NOT NULL,
  bucket_id text NOT NULL DEFAULT 'henvalt-privacy-exports-v2'
    CHECK (bucket_id = 'henvalt-privacy-exports-v2'),
  object_key text NOT NULL,
  sha256_hex text NOT NULL CHECK (sha256_hex ~ '^[0-9a-f]{64}$'),
  byte_count bigint NOT NULL CHECK (byte_count BETWEEN 1 AND 26214400),
  content_type text NOT NULL DEFAULT 'application/json'
    CHECK (content_type = 'application/json'),
  completeness_status text NOT NULL
    CHECK (completeness_status IN (
      'COMPLETE_FOR_MERCHANT_REVIEW', 'INCOMPLETE', 'REVIEW_REQUIRED'
    )),
  manifest_schema_version integer NOT NULL DEFAULT 1
    CHECK (manifest_schema_version > 0),
  manifest_summary jsonb NOT NULL
    CHECK (jsonb_typeof(manifest_summary) = 'object'),
  state text NOT NULL DEFAULT 'STAGED'
    CHECK (state IN ('STAGED', 'AVAILABLE', 'PURGE_PENDING', 'PURGED', 'FAILED')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  expires_at timestamptz NOT NULL,
  purged_at timestamptz,
  CONSTRAINT shopify_privacy_export_artifacts_expiry_order
    CHECK (expires_at > created_at),
  CONSTRAINT shopify_privacy_export_artifacts_purge_state
    CHECK (
      (state = 'PURGED' AND purged_at IS NOT NULL)
      OR (state <> 'PURGED' AND purged_at IS NULL)
    ),
  CONSTRAINT shopify_privacy_export_artifacts_available_completeness
    CHECK (
      state <> 'AVAILABLE'
      OR completeness_status = 'COMPLETE_FOR_MERCHANT_REVIEW'
    ),
  CONSTRAINT shopify_privacy_export_artifacts_object_key_uuid
    CHECK (object_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.]json$'),
  CONSTRAINT shopify_privacy_export_artifacts_generation_uidx
    UNIQUE (receipt_id, generation_id),
  CONSTRAINT shopify_privacy_export_artifacts_bucket_object_uidx
    UNIQUE (bucket_id, object_key),
  CONSTRAINT shopify_privacy_export_artifacts_receipt_binding_fkey
    FOREIGN KEY (receipt_id, tenant_id, connection_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_privacy_webhook_deliveries
      (id, tenant_id, connection_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_privacy_export_artifacts_connection_binding_fkey
    FOREIGN KEY (connection_id, tenant_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_connections (id, tenant_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_privacy_export_artifacts_expiry_idx
  ON henvalt.shopify_privacy_export_artifacts_v2 (expires_at, id)
  WHERE state IN ('AVAILABLE', 'PURGE_PENDING');

CREATE INDEX IF NOT EXISTS shopify_privacy_export_artifacts_receipt_idx
  ON henvalt.shopify_privacy_export_artifacts_v2 (receipt_id, created_at DESC);

CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_delivery_evidence_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  connection_id uuid NOT NULL,
  app_key text NOT NULL,
  shop_domain text NOT NULL,
  artifact_id uuid,
  actor_user_id uuid,
  event_type text NOT NULL CHECK (event_type IN (
    'ARTIFACT_GENERATED',
    'DOWNLOAD_AUTHORIZED',
    'DOWNLOAD_STREAM_STARTED',
    'DOWNLOAD_STREAM_FAILED',
    'MERCHANT_ATTESTED_PROVIDED_TO_SUBJECT',
    'ARTIFACT_PURGE_REQUESTED',
    'ARTIFACT_PURGED',
    'ARTIFACT_PURGE_FAILED'
  )),
  outcome_code text NOT NULL
    CHECK (outcome_code ~ '^[A-Z0-9_]{1,64}$'),
  correlation_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT shopify_privacy_delivery_evidence_receipt_binding_fkey
    FOREIGN KEY (receipt_id, tenant_id, connection_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_privacy_webhook_deliveries
      (id, tenant_id, connection_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_privacy_delivery_evidence_artifact_binding_fkey
    FOREIGN KEY (artifact_id, receipt_id, tenant_id, connection_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_privacy_export_artifacts_v2
      (id, receipt_id, tenant_id, connection_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS shopify_privacy_delivery_evidence_receipt_idx
  ON henvalt.shopify_privacy_delivery_evidence_v2 (receipt_id, created_at, id);

ALTER TABLE henvalt.shopify_privacy_export_artifacts_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_privacy_export_artifacts_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_privacy_delivery_evidence_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_privacy_delivery_evidence_v2 FORCE ROW LEVEL SECURITY;

REVOKE ALL ON henvalt.shopify_privacy_export_artifacts_v2
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.shopify_privacy_delivery_evidence_v2
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON henvalt.shopify_privacy_export_artifacts_v2 TO service_role;
-- Evidence is append-only: service code may read and insert, never update/delete.
GRANT SELECT, INSERT ON henvalt.shopify_privacy_delivery_evidence_v2 TO service_role;

COMMENT ON TABLE henvalt.shopify_privacy_export_artifacts_v2 IS
  'Service-only metadata for exact-store private export objects. Does not itself create the Storage bucket or prove upload/delivery.';
COMMENT ON COLUMN henvalt.shopify_privacy_export_artifacts_v2.object_key IS
  'Random UUID filename only; never encode tenant, store, receipt, customer or order identifiers.';
COMMENT ON COLUMN henvalt.shopify_privacy_export_artifacts_v2.manifest_summary IS
  'Non-PII manifest summary only: schema/category names, counts and opaque outcome codes; never export payload or customer identifiers.';
COMMENT ON TABLE henvalt.shopify_privacy_delivery_evidence_v2 IS
  'Append-only service-only audit evidence. Download stream events are not proof that a merchant provided the export to the data subject.';

COMMIT;
