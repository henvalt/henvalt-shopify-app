-- HENVALT exact-store customer/session/checkout identity graph V2.
-- PREPARATION ONLY. Depends on migrations 001, 007 and 008.
-- This creates isolated identity tables and a pixel-inbox projection RPC.
-- It does not modify legacy customers/sessions/checkouts/canonical events,
-- and does not connect the new graph to recovery, delivery, attribution or billing.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_identity_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  external_customer_reference text NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_customer_identity_v2_external_ref_nonempty
    CHECK (length(btrim(external_customer_reference)) BETWEEN 1 AND 200),
  CONSTRAINT shopify_customer_identity_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_identity_v2_connection_external_uidx
    UNIQUE (shopify_connection_id, external_customer_reference),
  CONSTRAINT shopify_customer_identity_v2_id_tenant_connection_uidx
    UNIQUE (id, tenant_id, shopify_connection_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_session_identity_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  session_reference text NOT NULL,
  customer_identity_id uuid,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_session_identity_v2_reference_nonempty
    CHECK (length(btrim(session_reference)) BETWEEN 1 AND 160),
  CONSTRAINT shopify_session_identity_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_session_identity_v2_customer_same_connection_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE SET NULL (customer_identity_id),
  CONSTRAINT shopify_session_identity_v2_connection_reference_uidx
    UNIQUE (shopify_connection_id, session_reference),
  CONSTRAINT shopify_session_identity_v2_tenant_connection_reference_uidx
    UNIQUE (tenant_id, shopify_connection_id, session_reference),
  CONSTRAINT shopify_session_identity_v2_id_tenant_connection_uidx
    UNIQUE (id, tenant_id, shopify_connection_id)
);

CREATE TABLE IF NOT EXISTS henvalt.shopify_session_alias_identity_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  alias_reference text NOT NULL,
  session_reference text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_session_alias_identity_v2_alias_nonempty
    CHECK (length(btrim(alias_reference)) BETWEEN 1 AND 300),
  CONSTRAINT shopify_session_alias_identity_v2_connection_alias_uidx
    UNIQUE (shopify_connection_id, alias_reference),
  CONSTRAINT shopify_session_alias_identity_v2_session_same_connection_fkey
    FOREIGN KEY (tenant_id, shopify_connection_id, session_reference)
    REFERENCES henvalt.shopify_session_identity_v2(tenant_id, shopify_connection_id, session_reference)
    ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT shopify_session_alias_identity_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- Checkout identity is deliberately separate from the legacy checkouts table.
-- Its source receipt FK ensures a future writer can only project a verified
-- webhook from the same exact connection.
CREATE UNIQUE INDEX IF NOT EXISTS shopify_webhook_deliveries_id_tenant_connection_uidx
  ON henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_checkout_identity_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  shopify_checkout_id text NOT NULL,
  checkout_token text,
  session_reference text,
  customer_identity_id uuid,
  source_delivery_id uuid NOT NULL,
  checkout_status text NOT NULL DEFAULT 'OPEN'
    CHECK (checkout_status IN ('OPEN', 'COMPLETED', 'CANCELLED', 'UNKNOWN')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_checkout_identity_v2_checkout_id_nonempty
    CHECK (length(btrim(shopify_checkout_id)) BETWEEN 1 AND 200),
  CONSTRAINT shopify_checkout_identity_v2_connection_tenant_fkey
    FOREIGN KEY (shopify_connection_id, tenant_id)
    REFERENCES henvalt.shopify_connections(id, tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_checkout_identity_v2_customer_same_connection_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE SET NULL (customer_identity_id),
  CONSTRAINT shopify_checkout_identity_v2_session_same_connection_fkey
    FOREIGN KEY (tenant_id, shopify_connection_id, session_reference)
    REFERENCES henvalt.shopify_session_identity_v2(tenant_id, shopify_connection_id, session_reference)
    ON UPDATE RESTRICT ON DELETE SET NULL (session_reference),
  CONSTRAINT shopify_checkout_identity_v2_verified_source_fkey
    FOREIGN KEY (source_delivery_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id, tenant_id, connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_checkout_identity_v2_connection_checkout_uidx
    UNIQUE (shopify_connection_id, shopify_checkout_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS shopify_checkout_identity_v2_connection_token_uidx
  ON henvalt.shopify_checkout_identity_v2(shopify_connection_id, checkout_token)
  WHERE checkout_token IS NOT NULL;

CREATE INDEX IF NOT EXISTS shopify_checkout_identity_v2_connection_updated_idx
  ON henvalt.shopify_checkout_identity_v2(shopify_connection_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS shopify_session_identity_v2_customer_idx
  ON henvalt.shopify_session_identity_v2(customer_identity_id)
  WHERE customer_identity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS shopify_session_alias_identity_v2_session_idx
  ON henvalt.shopify_session_alias_identity_v2(shopify_connection_id, session_reference);

ALTER TABLE henvalt.shopify_customer_identity_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_session_identity_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_session_alias_identity_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE henvalt.shopify_checkout_identity_v2 ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON henvalt.shopify_customer_identity_v2 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.shopify_session_identity_v2 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.shopify_session_alias_identity_v2 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON henvalt.shopify_checkout_identity_v2 FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE henvalt.shopify_customer_identity_v2 IS
  'Pseudonymous Shopify customer identity keyed by exact connection. No email-based fallback and no direct client access.';
COMMENT ON TABLE henvalt.shopify_session_identity_v2 IS
  'Exact-connection session identity graph. Reused browser references in another store remain separate.';
COMMENT ON TABLE henvalt.shopify_session_alias_identity_v2 IS
  'Exact-connection aliases (including checkout aliases) bound to a session in the same installation.';
COMMENT ON TABLE henvalt.shopify_checkout_identity_v2 IS
  'Isolated exact-store checkout identity. Future writer must project only a verified same-connection webhook receipt; no legacy recovery reader consumes this table yet.';

CREATE OR REPLACE FUNCTION henvalt.project_shopify_pixel_identity_v2(p_inbox_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'pg_catalog', 'henvalt', 'pg_temp'
AS $function$
DECLARE
  v_event henvalt.shopify_pixel_event_inbox_v2%ROWTYPE;
  v_customer_id uuid;
  v_session_id uuid;
  v_existing_customer_id uuid;
  v_existing_session text;
  v_connection_active boolean;
  v_tenant_active boolean;
BEGIN
  IF p_inbox_id IS NULL THEN
    RAISE EXCEPTION 'PIXEL_INBOX_ID_REQUIRED';
  END IF;

  SELECT * INTO v_event
  FROM henvalt.shopify_pixel_event_inbox_v2
  WHERE id = p_inbox_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PIXEL_INBOX_EVENT_NOT_FOUND';
  END IF;

  IF v_event.status = 'PROCESSED' THEN
    RETURN jsonb_build_object('accepted', true, 'duplicate', true, 'identity_projected', true);
  END IF;

  IF v_event.status <> 'PENDING_ADAPTER' THEN
    RAISE EXCEPTION 'PIXEL_INBOX_EVENT_NOT_PENDING';
  END IF;

  SELECT sc.active, t.status = 'ACTIVE'
    INTO v_connection_active, v_tenant_active
  FROM henvalt.shopify_connections sc
  JOIN henvalt.tenants t ON t.id = sc.tenant_id
  WHERE sc.id = v_event.shopify_connection_id
    AND sc.tenant_id = v_event.tenant_id;

  IF v_connection_active IS DISTINCT FROM true OR v_tenant_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SHOPIFY_CONNECTION_OR_TENANT_INACTIVE';
  END IF;

  -- Consent denial is a terminal no-identity outcome. Do not create a
  -- customer, session, alias, or checkout identity from marketing consent.
  IF v_event.analytics_processing_allowed IS NOT TRUE
     OR v_event.client_reference IS NULL THEN
    UPDATE henvalt.shopify_pixel_event_inbox_v2
       SET status = 'PROCESSED', processed_at = now()
     WHERE id = v_event.id;
    RETURN jsonb_build_object(
      'accepted', true,
      'duplicate', false,
      'identity_projected', false,
      'reason', 'ANALYTICS_CONSENT_NOT_GRANTED'
    );
  END IF;

  IF v_event.customer_reference IS NOT NULL THEN
    INSERT INTO henvalt.shopify_customer_identity_v2 (
      tenant_id, shopify_connection_id, external_customer_reference
    )
    VALUES (
      v_event.tenant_id, v_event.shopify_connection_id, v_event.customer_reference
    )
    ON CONFLICT (shopify_connection_id, external_customer_reference)
    DO UPDATE SET last_seen_at = greatest(
      henvalt.shopify_customer_identity_v2.last_seen_at, now()
    )
    RETURNING id INTO v_customer_id;
  END IF;

  INSERT INTO henvalt.shopify_session_identity_v2 (
    tenant_id, shopify_connection_id, session_reference, customer_identity_id
  )
  VALUES (
    v_event.tenant_id, v_event.shopify_connection_id,
    v_event.client_reference, v_customer_id
  )
  ON CONFLICT (shopify_connection_id, session_reference)
  DO UPDATE SET last_seen_at = greatest(
    henvalt.shopify_session_identity_v2.last_seen_at, now()
  )
  RETURNING id, customer_identity_id INTO v_session_id, v_existing_customer_id;

  IF v_customer_id IS NOT NULL
     AND v_existing_customer_id IS NOT NULL
     AND v_existing_customer_id <> v_customer_id THEN
    RAISE EXCEPTION 'SESSION_CUSTOMER_IDENTITY_CONFLICT';
  END IF;

  IF v_customer_id IS NOT NULL AND v_existing_customer_id IS NULL THEN
    UPDATE henvalt.shopify_session_identity_v2
       SET customer_identity_id = v_customer_id
     WHERE id = v_session_id
       AND tenant_id = v_event.tenant_id
       AND shopify_connection_id = v_event.shopify_connection_id;
  END IF;

  IF v_event.checkout_reference IS NOT NULL THEN
    INSERT INTO henvalt.shopify_session_alias_identity_v2 (
      tenant_id, shopify_connection_id, alias_reference, session_reference
    )
    VALUES (
      v_event.tenant_id, v_event.shopify_connection_id,
      v_event.checkout_reference, v_event.client_reference
    )
    ON CONFLICT (shopify_connection_id, alias_reference) DO NOTHING;

    SELECT session_reference INTO v_existing_session
    FROM henvalt.shopify_session_alias_identity_v2
    WHERE shopify_connection_id = v_event.shopify_connection_id
      AND alias_reference = v_event.checkout_reference;

    IF v_existing_session IS DISTINCT FROM v_event.client_reference THEN
      RAISE EXCEPTION 'SESSION_ALIAS_ALREADY_BOUND_TO_DIFFERENT_SESSION';
    END IF;
  END IF;

  UPDATE henvalt.shopify_pixel_event_inbox_v2
     SET status = 'PROCESSED', processed_at = now()
   WHERE id = v_event.id;

  RETURN jsonb_build_object(
    'accepted', true,
    'duplicate', false,
    'identity_projected', true,
    'customer_identity_created', v_customer_id IS NOT NULL,
    'session_identity_created', true,
    'alias_created', v_event.checkout_reference IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_shopify_pixel_identity_v2(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_shopify_pixel_identity_v2(uuid)
  TO service_role;

COMMIT;
