-- HENVALT exact-store customer redaction send guard V2.
-- PREPARATION ONLY. Establishes a fail-closed per-customer guard and prevents
-- new delivery permits/send attempts while privacy work is active. It does not
-- delete customer data, rewrite suppression evidence, or alter financial facts.

BEGIN;

CREATE TABLE IF NOT EXISTS henvalt.shopify_customer_redaction_guards_v2 (
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  customer_identity_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  state text NOT NULL DEFAULT 'ACTIVE'
    CHECK (state IN ('ACTIVE', 'REVIEW_REQUIRED', 'RELEASED')),
  policy_version text NOT NULL DEFAULT 'UNAPPROVED',
  activated_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  release_reason text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, shopify_connection_id, customer_identity_id),
  CONSTRAINT shopify_customer_redaction_guards_v2_customer_fkey
    FOREIGN KEY (customer_identity_id, tenant_id, shopify_connection_id)
    REFERENCES henvalt.shopify_customer_identity_v2(id, tenant_id, shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_redaction_guards_v2_receipt_fkey
    FOREIGN KEY (receipt_id)
    REFERENCES henvalt.shopify_privacy_webhook_deliveries(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_customer_redaction_guards_v2_release_pair
    CHECK ((state = 'RELEASED') = (released_at IS NOT NULL)),
  CONSTRAINT shopify_customer_redaction_guards_v2_release_reason
    CHECK ((state = 'RELEASED') = (release_reason IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS shopify_customer_redaction_guards_v2_receipt_idx
  ON henvalt.shopify_customer_redaction_guards_v2 (receipt_id);

ALTER TABLE henvalt.shopify_customer_redaction_guards_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_customer_redaction_guards_v2
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.enforce_shopify_customer_redaction_guard_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  -- Serialize new delivery material against guard activation. The guard
  -- activator takes FOR UPDATE on this same identity row before inserting.
  PERFORM 1
  FROM henvalt.shopify_customer_identity_v2 c
  WHERE c.id = NEW.customer_identity_id
    AND c.tenant_id = NEW.tenant_id
    AND c.shopify_connection_id = NEW.shopify_connection_id
  FOR KEY SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'exact-store customer identity missing for delivery material'
      USING ERRCODE = '23503';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id = NEW.tenant_id
      AND g.shopify_connection_id = NEW.shopify_connection_id
      AND g.customer_identity_id = NEW.customer_identity_id
      AND g.state IN ('ACTIVE', 'REVIEW_REQUIRED')
  ) THEN
    RAISE EXCEPTION 'customer delivery blocked by active privacy redaction guard'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS shopify_delivery_permits_redaction_guard_v2
  ON henvalt.shopify_delivery_permits_v2;
CREATE TRIGGER shopify_delivery_permits_redaction_guard_v2
BEFORE INSERT ON henvalt.shopify_delivery_permits_v2
FOR EACH ROW
EXECUTE FUNCTION henvalt.enforce_shopify_customer_redaction_guard_v2();

DROP TRIGGER IF EXISTS shopify_send_attempts_redaction_guard_v2
  ON henvalt.shopify_recovery_send_attempt_v2;
CREATE TRIGGER shopify_send_attempts_redaction_guard_v2
BEFORE INSERT ON henvalt.shopify_recovery_send_attempt_v2
FOR EACH ROW
EXECUTE FUNCTION henvalt.enforce_shopify_customer_redaction_guard_v2();

REVOKE ALL ON FUNCTION henvalt.enforce_shopify_customer_redaction_guard_v2()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION henvalt.begin_shopify_customer_redaction_guard_v2(
  p_receipt_id uuid,
  p_claim_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt henvalt.shopify_privacy_webhook_deliveries%ROWTYPE;
  v_customer henvalt.shopify_customer_identity_v2%ROWTYPE;
  v_claim_hash text;
  v_pending_permits integer := 0;
  v_pending_interventions integer := 0;
  v_unresolved_attempts integer := 0;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('guarded', false, 'code', 'INVALID_CLAIM');
  END IF;

  v_claim_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'),
    'hex'
  );

  SELECT r.* INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  JOIN henvalt.shopify_privacy_processing_jobs_v2 j
    ON j.receipt_id = r.id
  JOIN henvalt.shopify_connections sc
    ON sc.id = r.connection_id
   AND sc.tenant_id = r.tenant_id
   AND sc.app_key = r.app_key
   AND sc.shop_domain = r.shop_domain
  WHERE r.id = p_receipt_id
    AND r.topic = 'customers/redact'
    AND r.connection_id IS NOT NULL
    AND r.tenant_id IS NOT NULL
    AND r.customer_id IS NOT NULL
    AND j.state = 'CLAIMED'
    AND j.lease_until > pg_catalog.now()
    AND j.claim_token_sha256 = v_claim_hash
  FOR UPDATE OF j, r;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('guarded', false, 'code', 'CLAIM_OR_STORE_BINDING_INVALID');
  END IF;

  SELECT c.* INTO v_customer
  FROM henvalt.shopify_customer_identity_v2 c
  WHERE c.tenant_id = v_receipt.tenant_id
    AND c.shopify_connection_id = v_receipt.connection_id
    AND c.external_customer_reference = v_receipt.customer_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'guarded', false,
      'code', 'NO_EXACT_STORE_CUSTOMER_IDENTITY',
      'legacy_scope_review_required', true
    );
  END IF;

  INSERT INTO henvalt.shopify_customer_redaction_guards_v2 (
    tenant_id, shopify_connection_id, customer_identity_id, receipt_id,
    state, policy_version, activated_at, released_at, release_reason, updated_at
  ) VALUES (
    v_receipt.tenant_id, v_receipt.connection_id, v_customer.id, v_receipt.id,
    'ACTIVE', 'UNAPPROVED', pg_catalog.now(), NULL, NULL, pg_catalog.now()
  )
  ON CONFLICT (tenant_id, shopify_connection_id, customer_identity_id)
  DO UPDATE SET
    receipt_id = EXCLUDED.receipt_id,
    state = 'ACTIVE',
    policy_version = 'UNAPPROVED',
    activated_at = pg_catalog.now(),
    released_at = NULL,
    release_reason = NULL,
    updated_at = pg_catalog.now()
  WHERE henvalt.shopify_customer_redaction_guards_v2.state = 'RELEASED';

  IF NOT FOUND AND NOT EXISTS (
    SELECT 1 FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id = v_receipt.tenant_id
      AND g.shopify_connection_id = v_receipt.connection_id
      AND g.customer_identity_id = v_customer.id
      AND g.state IN ('ACTIVE', 'REVIEW_REQUIRED')
  ) THEN
    RETURN jsonb_build_object('guarded', false, 'code', 'GUARD_STATE_CONFLICT');
  END IF;

  -- Do not mutate permits/interventions in this transaction. A concurrent
  -- consume may already hold a permit row while waiting for the customer lock;
  -- changing permit rows here would create a lock-order deadlock. The guard is
  -- committed first. A second claim-bound RPC performs cleanup without taking
  -- the customer identity lock; new consumes will see the guard and abort.

  SELECT count(*) INTO v_pending_permits
  FROM henvalt.shopify_delivery_permits_v2 p
  WHERE p.tenant_id = v_receipt.tenant_id
    AND p.shopify_connection_id = v_receipt.connection_id
    AND p.customer_identity_id = v_customer.id
    AND p.consumed_at IS NULL
    AND p.expires_at > pg_catalog.now();

  SELECT count(*) INTO v_pending_interventions
  FROM henvalt.shopify_recovery_intervention_v2 i
  WHERE i.tenant_id = v_receipt.tenant_id
    AND i.shopify_connection_id = v_receipt.connection_id
    AND i.customer_identity_id = v_customer.id
    AND i.status = 'READY_FOR_AUTHORIZATION'
    AND NOT EXISTS (
      SELECT 1
      FROM henvalt.shopify_recovery_send_attempt_v2 a
      WHERE a.intervention_id = i.id
        AND a.tenant_id = i.tenant_id
        AND a.shopify_connection_id = i.shopify_connection_id
    );

  SELECT count(*) INTO v_unresolved_attempts
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id = v_receipt.tenant_id
    AND a.shopify_connection_id = v_receipt.connection_id
    AND a.customer_identity_id = v_customer.id
    AND a.status IN ('AUTHORIZED', 'AMBIGUOUS');

  RETURN jsonb_build_object(
    'guarded', true,
    'operation', 'EXACT_STORE_CUSTOMER_SEND_GUARD',
    'customer_identity_found', true,
    'exact_store_scope_confirmed', true,
    'new_delivery_material_blocked', true,
    'unconsumed_permits_pending_expiry', v_pending_permits,
    'untouched_interventions_pending_cancellation', v_pending_interventions,
    'unresolved_send_attempts_require_reconciliation', v_unresolved_attempts,
    'suppression_records_mutated', false,
    'provider_audit_records_mutated', false,
    'cost_reservations_mutated', false,
    'order_refund_attribution_fee_records_mutated', false,
    'customer_data_deleted', false,
    'safe_to_complete_privacy_request', false,
    'retention_policy_approved', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.begin_shopify_customer_redaction_guard_v2(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.begin_shopify_customer_redaction_guard_v2(uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION henvalt.prepare_shopify_customer_redaction_send_stop_v2(
  p_receipt_id uuid,
  p_claim_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt henvalt.shopify_privacy_webhook_deliveries%ROWTYPE;
  v_customer_id uuid;
  v_claim_hash text;
  v_expired_permits integer := 0;
  v_cancelled_interventions integer := 0;
  v_unresolved_attempts integer := 0;
BEGIN
  IF p_receipt_id IS NULL
     OR p_claim_token IS NULL
     OR p_claim_token !~ '^[0-9a-f]{64}
  'Exact-store per-customer fail-closed send guard during Shopify customers/redact processing. Does not implement a retention policy or data deletion.';
COMMENT ON FUNCTION henvalt.begin_shopify_customer_redaction_guard_v2(uuid, text) IS
  'Activates a claim-bound exact-store customer send guard. It commits the serialization lock before cleanup to avoid lock-order deadlocks. Never deletes customer data.';
COMMENT ON FUNCTION henvalt.prepare_shopify_customer_redaction_send_stop_v2(uuid, text) IS
  'After guard activation, expires unconsumed permits and cancels only interventions with no send attempt. Preserves unresolved attempts and all suppression/provider/cost/financial records.';

COMMIT;
 THEN
    RETURN jsonb_build_object('prepared', false, 'code', 'INVALID_CLAIM');
  END IF;

  v_claim_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_claim_token, 'UTF8'), 'sha256'),
    'hex'
  );

  SELECT r.* INTO v_receipt
  FROM henvalt.shopify_privacy_webhook_deliveries r
  JOIN henvalt.shopify_privacy_processing_jobs_v2 j
    ON j.receipt_id = r.id
  JOIN henvalt.shopify_connections sc
    ON sc.id = r.connection_id
   AND sc.tenant_id = r.tenant_id
   AND sc.app_key = r.app_key
   AND sc.shop_domain = r.shop_domain
  WHERE r.id = p_receipt_id
    AND r.topic = 'customers/redact'
    AND r.connection_id IS NOT NULL
    AND r.tenant_id IS NOT NULL
    AND r.customer_id IS NOT NULL
    AND j.state = 'CLAIMED'
    AND j.lease_until > pg_catalog.now()
    AND j.claim_token_sha256 = v_claim_hash;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('prepared', false, 'code', 'CLAIM_OR_STORE_BINDING_INVALID');
  END IF;

  SELECT c.id INTO v_customer_id
  FROM henvalt.shopify_customer_identity_v2 c
  WHERE c.tenant_id = v_receipt.tenant_id
    AND c.shopify_connection_id = v_receipt.connection_id
    AND c.external_customer_reference = v_receipt.customer_id;

  IF v_customer_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM henvalt.shopify_customer_redaction_guards_v2 g
    WHERE g.tenant_id = v_receipt.tenant_id
      AND g.shopify_connection_id = v_receipt.connection_id
      AND g.customer_identity_id = v_customer_id
      AND g.receipt_id = v_receipt.id
      AND g.state IN ('ACTIVE', 'REVIEW_REQUIRED')
  ) THEN
    RETURN jsonb_build_object('prepared', false, 'code', 'ACTIVE_EXACT_STORE_GUARD_REQUIRED');
  END IF;

  -- The guard is already committed. Do not lock the customer identity here:
  -- insert triggers can now fail fast on the guard without a lock cycle.
  UPDATE henvalt.shopify_delivery_permits_v2 p
     SET expires_at = LEAST(p.expires_at, pg_catalog.now())
   WHERE p.tenant_id = v_receipt.tenant_id
     AND p.shopify_connection_id = v_receipt.connection_id
     AND p.customer_identity_id = v_customer_id
     AND p.consumed_at IS NULL
     AND p.expires_at > pg_catalog.now();
  GET DIAGNOSTICS v_expired_permits = ROW_COUNT;

  UPDATE henvalt.shopify_recovery_intervention_v2 i
     SET status = 'CANCELLED',
         updated_at = pg_catalog.now()
   WHERE i.tenant_id = v_receipt.tenant_id
     AND i.shopify_connection_id = v_receipt.connection_id
     AND i.customer_identity_id = v_customer_id
     AND i.status = 'READY_FOR_AUTHORIZATION'
     AND NOT EXISTS (
       SELECT 1
       FROM henvalt.shopify_recovery_send_attempt_v2 a
       WHERE a.intervention_id = i.id
         AND a.tenant_id = i.tenant_id
         AND a.shopify_connection_id = i.shopify_connection_id
     );
  GET DIAGNOSTICS v_cancelled_interventions = ROW_COUNT;

  SELECT count(*) INTO v_unresolved_attempts
  FROM henvalt.shopify_recovery_send_attempt_v2 a
  WHERE a.tenant_id = v_receipt.tenant_id
    AND a.shopify_connection_id = v_receipt.connection_id
    AND a.customer_identity_id = v_customer_id
    AND a.status IN ('AUTHORIZED', 'AMBIGUOUS');

  RETURN jsonb_build_object(
    'prepared', true,
    'exact_store_scope_confirmed', true,
    'unconsumed_permits_expired', v_expired_permits,
    'not_yet_authorized_interventions_cancelled', v_cancelled_interventions,
    'unresolved_send_attempts_require_reconciliation', v_unresolved_attempts,
    'suppression_records_mutated', false,
    'provider_audit_records_mutated', false,
    'cost_reservations_mutated', false,
    'order_refund_attribution_fee_records_mutated', false,
    'customer_data_deleted', false,
    'safe_to_complete_privacy_request', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.prepare_shopify_customer_redaction_send_stop_v2(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.prepare_shopify_customer_redaction_send_stop_v2(uuid, text)
  TO service_role;

COMMENT ON TABLE henvalt.shopify_customer_redaction_guards_v2 IS
  'Exact-store per-customer fail-closed send guard during Shopify customers/redact processing. Does not implement a retention policy or data deletion.';
COMMENT ON FUNCTION henvalt.begin_shopify_customer_redaction_guard_v2(uuid, text) IS
  'Activates a claim-bound exact-store customer send guard, expires unconsumed permits, cancels only interventions with no send attempt, and reports unresolved attempts. Never deletes suppression, provider, cost or financial records.';

COMMIT;
