-- App-aware, exact-store Shopify compliance webhook inbox.
-- PREPARATION ONLY. Depends on migration 001. Do not apply until the complete
-- privacy lifecycle and store-scoped export/redaction RPCs are independently
-- reviewed and tested. This inbox intentionally does NOT execute deletion.
--
-- It verifies raw-body Shopify HMAC using the app-specific Vault secret and
-- stores only minimum routing/request metadata. Raw bodies, emails, and full
-- customer payloads are never persisted.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_webhook_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_key text NOT NULL,
  tenant_id uuid,
  connection_id uuid,
  shop_domain text NOT NULL,
  shopify_shop_id text,
  topic text NOT NULL CHECK (topic IN (
    'customers/data_request',
    'customers/redact',
    'shop/redact'
  )),
  webhook_id text NOT NULL,
  customer_id text,
  request_id text,
  raw_body_sha256 text NOT NULL CHECK (raw_body_sha256 ~ '^[0-9a-f]{64}$'),
  hmac_verified_at timestamptz NOT NULL,
  processing_status text NOT NULL DEFAULT 'REVIEW_REQUIRED'
    CHECK (processing_status IN ('REVIEW_REQUIRED', 'PROCESSING', 'COMPLETED', 'FAILED')),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  failure_code text,
  CONSTRAINT shopify_privacy_webhook_deliveries_link_pair
    CHECK ((tenant_id IS NULL) = (connection_id IS NULL)),
  CONSTRAINT shopify_privacy_webhook_deliveries_webhook_nonempty
    CHECK (length(btrim(webhook_id)) > 0),
  CONSTRAINT shopify_privacy_webhook_deliveries_shop_format
    CHECK (shop_domain = lower(shop_domain)
      AND shop_domain ~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$'),
  CONSTRAINT shopify_privacy_webhook_deliveries_connection_fkey
    FOREIGN KEY (connection_id, tenant_id, app_key, shop_domain)
    REFERENCES henvalt.shopify_connections (id, tenant_id, app_key, shop_domain)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_privacy_webhook_deliveries_app_fkey
    FOREIGN KEY (app_key)
    REFERENCES henvalt.shopify_app_registry (app_key)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_privacy_webhook_deliveries_idempotency
    UNIQUE (app_key, shop_domain, webhook_id)
);

CREATE INDEX IF NOT EXISTS shopify_privacy_webhook_deliveries_review_idx
  ON henvalt.shopify_privacy_webhook_deliveries (processing_status, received_at)
  WHERE processing_status IN ('REVIEW_REQUIRED', 'FAILED');

CREATE INDEX IF NOT EXISTS shopify_privacy_webhook_deliveries_connection_idx
  ON henvalt.shopify_privacy_webhook_deliveries (connection_id, received_at DESC)
  WHERE connection_id IS NOT NULL;

ALTER TABLE henvalt.shopify_privacy_webhook_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_privacy_webhook_deliveries FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON henvalt.shopify_privacy_webhook_deliveries TO service_role;

CREATE OR REPLACE FUNCTION henvalt.accept_shopify_privacy_webhook_v2(
  p_app_key text,
  p_shopify_client_id text,
  p_hmac_base64 text,
  p_raw_body_base64 text,
  p_shop_domain text,
  p_topic text,
  p_webhook_id text
)
RETURNS TABLE (
  accepted boolean,
  duplicate boolean,
  receipt_status text,
  rejection_code text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'henvalt', 'vault', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_app henvalt.shopify_app_registry%rowtype;
  v_secret text;
  v_body bytea;
  v_payload jsonb;
  v_provided bytea;
  v_expected bytea;
  v_diff integer := 0;
  v_i integer;
  v_payload_shop text;
  v_shop_id text;
  v_customer_id text;
  v_request_id text;
  v_tenant_id uuid;
  v_connection_id uuid;
  v_connection_shop_id text;
  v_inserted uuid;
  v_body_digest text;
  v_existing_digest text;
BEGIN
  accepted := false;
  duplicate := false;
  receipt_status := 'REJECTED';
  rejection_code := 'INVALID_REQUEST';

  IF NULLIF(p_app_key, '') IS NULL
     OR NULLIF(p_shopify_client_id, '') IS NULL
     OR NULLIF(p_hmac_base64, '') IS NULL
     OR NULLIF(p_raw_body_base64, '') IS NULL
     OR length(p_raw_body_base64) > 1400000
     OR NULLIF(p_shop_domain, '') IS NULL
     OR NULLIF(p_webhook_id, '') IS NULL
     OR length(p_webhook_id) > 255
     OR p_topic IS NULL
     OR p_topic NOT IN ('customers/data_request', 'customers/redact', 'shop/redact')
     OR p_shop_domain <> lower(p_shop_domain)
     OR p_shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' THEN
    RETURN NEXT;
    RETURN;
  END IF;

  BEGIN
    v_body := decode(p_raw_body_base64, 'base64');
    v_payload := convert_from(v_body, 'UTF8')::jsonb;
    v_provided := decode(p_hmac_base64, 'base64');
  EXCEPTION WHEN OTHERS THEN
    RETURN NEXT;
    RETURN;
  END;

  IF octet_length(v_body) = 0 OR octet_length(v_body) > 1048576
     OR octet_length(v_provided) <> 32 THEN
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT * INTO v_app
  FROM henvalt.shopify_app_registry
  WHERE app_key = p_app_key
    AND shopify_client_id = p_shopify_client_id
    AND lifecycle_status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    rejection_code := 'APP_IDENTITY_INVALID';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT ds.decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets ds
  WHERE ds.name = v_app.webhook_secret_ref
     OR ds.id::text = v_app.webhook_secret_ref
  LIMIT 1;

  IF v_secret IS NULL OR v_secret = '' THEN
    rejection_code := 'APP_SECRET_NOT_CONFIGURED';
    RETURN NEXT;
    RETURN;
  END IF;

  v_expected := extensions.hmac(v_body, convert_to(v_secret, 'UTF8'), 'sha256');
  FOR v_i IN 0..31 LOOP
    v_diff := v_diff | (get_byte(v_expected, v_i) # get_byte(v_provided, v_i));
  END LOOP;

  IF v_diff <> 0 THEN
    rejection_code := 'HMAC_INVALID';
    RETURN NEXT;
    RETURN;
  END IF;

  v_payload_shop := lower(COALESCE(v_payload->>'shop_domain', v_payload->>'shopDomain', ''));
  IF v_payload_shop <> p_shop_domain THEN
    rejection_code := 'SHOP_DOMAIN_MISMATCH';
    RETURN NEXT;
    RETURN;
  END IF;

  v_shop_id := NULLIF(COALESCE(v_payload->>'shop_id', v_payload->>'shopId'), '');
  v_customer_id := NULLIF(v_payload #>> '{customer,id}', '');
  v_request_id := NULLIF(v_payload #>> '{data_request,id}', '');

  -- Exact app + exact shop lookup. A missing link is still durably queued for
  -- review; no tenant-wide fallback is allowed.
  SELECT sc.tenant_id, sc.id, sc.shopify_shop_id
    INTO v_tenant_id, v_connection_id, v_connection_shop_id
  FROM henvalt.shopify_connections sc
  WHERE sc.app_key = p_app_key
    AND sc.shop_domain = p_shop_domain
  LIMIT 1
  FOR SHARE;

  IF v_connection_id IS NOT NULL
     AND v_shop_id IS NOT NULL
     AND v_connection_shop_id IS NOT NULL
     AND v_shop_id <> v_connection_shop_id THEN
    rejection_code := 'SHOP_ID_MISMATCH';
    RETURN NEXT;
    RETURN;
  END IF;

  v_body_digest := encode(extensions.digest(v_body, 'sha256'), 'hex');

  INSERT INTO henvalt.shopify_privacy_webhook_deliveries (
    app_key, tenant_id, connection_id, shop_domain, shopify_shop_id,
    topic, webhook_id, customer_id, request_id, raw_body_sha256,
    hmac_verified_at, processing_status
  )
  VALUES (
    p_app_key, v_tenant_id, v_connection_id, p_shop_domain, v_shop_id,
    p_topic, p_webhook_id, v_customer_id, v_request_id,
    v_body_digest,
    now(), 'REVIEW_REQUIRED'
  )
  ON CONFLICT (app_key, shop_domain, webhook_id) DO NOTHING
  RETURNING id INTO v_inserted;

  IF v_inserted IS NULL THEN
    SELECT raw_body_sha256 INTO v_existing_digest
    FROM henvalt.shopify_privacy_webhook_deliveries
    WHERE app_key = p_app_key
      AND shop_domain = p_shop_domain
      AND webhook_id = p_webhook_id;

    IF v_existing_digest IS DISTINCT FROM v_body_digest THEN
      rejection_code := 'DELIVERY_ID_BODY_MISMATCH';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  accepted := true;
  duplicate := v_inserted IS NULL;
  receipt_status := CASE WHEN v_inserted IS NULL THEN 'DUPLICATE' ELSE 'REVIEW_REQUIRED' END;
  rejection_code := NULL;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.accept_shopify_privacy_webhook_v2(text,text,text,text,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.accept_shopify_privacy_webhook_v2(text,text,text,text,text,text,text)
  TO service_role;

COMMENT ON TABLE henvalt.shopify_privacy_webhook_deliveries IS
  'App-aware Shopify privacy webhook inbox. Verified requests remain REVIEW_REQUIRED until exact-store processing is proven; no raw payload or customer email is stored.';

COMMIT;
