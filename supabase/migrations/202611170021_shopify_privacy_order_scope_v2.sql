-- HENVALT preserve Shopify privacy request order scope V2.
-- PREPARATION ONLY. Stores only requested order IDs, bound to the exact verified receipt.
-- No raw payload, email, phone, export, deletion, or completion behavior is added.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_privacy_webhook_order_scope_v2 (
  receipt_id uuid NOT NULL,
  scope_kind text NOT NULL CHECK (scope_kind IN ('REQUESTED', 'TO_REDACT')),
  ordinal integer NOT NULL CHECK (ordinal > 0),
  shopify_order_id text NOT NULL
    CHECK (shopify_order_id ~ '^[1-9][0-9]{0,19}$'
      AND shopify_order_id::numeric <= 9223372036854775807),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_privacy_webhook_order_scope_v2_pk PRIMARY KEY (receipt_id, scope_kind, ordinal),
  CONSTRAINT shopify_privacy_webhook_order_scope_v2_unique_order UNIQUE (receipt_id, scope_kind, shopify_order_id),
  CONSTRAINT shopify_privacy_webhook_order_scope_v2_receipt_fkey
    FOREIGN KEY (receipt_id) REFERENCES henvalt.shopify_privacy_webhook_deliveries(id)
    ON UPDATE RESTRICT ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS shopify_privacy_webhook_order_scope_v2_lookup_idx
  ON henvalt.shopify_privacy_webhook_order_scope_v2 (receipt_id, scope_kind, shopify_order_id);

ALTER TABLE henvalt.shopify_privacy_webhook_order_scope_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_privacy_webhook_order_scope_v2 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON henvalt.shopify_privacy_webhook_order_scope_v2 TO service_role;

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
  v_order_array jsonb;
  v_order_item jsonb;
  v_order_id text;
  v_order_scope text;
  v_order_count integer;
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

  -- Preserve only order IDs explicitly scoped by Shopify.
  IF p_topic = 'customers/data_request' THEN
    v_order_array := v_payload->'orders_requested';
    v_order_scope := 'REQUESTED';
  ELSIF p_topic = 'customers/redact' THEN
    v_order_array := v_payload->'orders_to_redact';
    v_order_scope := 'TO_REDACT';
  ELSE
    v_order_array := '[]'::jsonb;
    v_order_scope := NULL;
  END IF;

  IF p_topic IN ('customers/data_request', 'customers/redact') THEN
    IF jsonb_typeof(v_order_array) IS DISTINCT FROM 'array' THEN
      rejection_code := 'INVALID_ORDER_SCOPE';
      RETURN NEXT;
      RETURN;
    END IF;
    IF jsonb_array_length(v_order_array) > 10000 THEN
      rejection_code := 'INVALID_ORDER_SCOPE';
      RETURN NEXT;
      RETURN;
    END IF;
    v_order_count := jsonb_array_length(v_order_array);
    FOR v_order_item IN SELECT value FROM jsonb_array_elements(v_order_array) LOOP
      IF jsonb_typeof(v_order_item) NOT IN ('number', 'string') THEN
        rejection_code := 'INVALID_ORDER_SCOPE';
        RETURN NEXT;
        RETURN;
      END IF;
      v_order_id := v_order_item #>> '{}';
      IF v_order_id IS NULL
         OR v_order_id !~ '^[1-9][0-9]{0,19}$'
         OR v_order_id::numeric > 9223372036854775807 THEN
        rejection_code := 'INVALID_ORDER_SCOPE';
        RETURN NEXT;
        RETURN;
      END IF;
    END LOOP;
    IF (SELECT count(DISTINCT value #>> '{}') FROM jsonb_array_elements(v_order_array)) <> v_order_count THEN
      rejection_code := 'INVALID_ORDER_SCOPE';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

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

  IF v_inserted IS NOT NULL AND v_order_scope IS NOT NULL THEN
    INSERT INTO henvalt.shopify_privacy_webhook_order_scope_v2 (
      receipt_id, scope_kind, ordinal, shopify_order_id
    )
    SELECT v_inserted, v_order_scope, ordinality::integer, value #>> '{}'
    FROM jsonb_array_elements(v_order_array) WITH ORDINALITY AS order_item(value, ordinality);
  END IF;

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

COMMENT ON TABLE henvalt.shopify_privacy_webhook_order_scope_v2 IS
  'Minimal order IDs explicitly requested by a verified Shopify privacy receipt. Scope is immutable per receipt and never inferred across stores.';

COMMIT;
