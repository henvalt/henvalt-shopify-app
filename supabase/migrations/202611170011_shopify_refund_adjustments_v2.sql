-- HENVALT exact-store Shopify refund adjustment projection V2.
-- PREPARATION ONLY. Depends on candidate migrations 001, 002, 011 and 021.
-- Refund amounts are taken only from successful refund transactions in the
-- exact order currency. Ambiguous/malformed payloads remain retryable.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS shopify_order_identity_v2_id_tenant_connection_uidx
  ON henvalt.shopify_order_identity_v2(id,tenant_id,shopify_connection_id);

CREATE TABLE IF NOT EXISTS henvalt.shopify_order_refund_adjustments_v2 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  shopify_connection_id uuid NOT NULL,
  order_identity_id uuid NOT NULL,
  shopify_refund_id text NOT NULL,
  refund_amount numeric(18,4) NOT NULL CHECK (refund_amount > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  refunded_at timestamptz NOT NULL,
  source_delivery_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shopify_order_refund_adjustments_v2_refund_id_nonempty
    CHECK (length(btrim(shopify_refund_id)) BETWEEN 1 AND 200),
  CONSTRAINT shopify_order_refund_adjustments_v2_connection_fkey
    FOREIGN KEY (shopify_connection_id,tenant_id)
    REFERENCES henvalt.shopify_connections(id,tenant_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_order_refund_adjustments_v2_order_fkey
    FOREIGN KEY (order_identity_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_order_identity_v2(id,tenant_id,shopify_connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_order_refund_adjustments_v2_receipt_fkey
    FOREIGN KEY (source_delivery_id,tenant_id,shopify_connection_id)
    REFERENCES henvalt.shopify_webhook_deliveries(id,tenant_id,connection_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT shopify_order_refund_adjustments_v2_store_refund_uidx
    UNIQUE (shopify_connection_id,shopify_refund_id)
);

CREATE INDEX IF NOT EXISTS shopify_order_refund_adjustments_v2_order_idx
  ON henvalt.shopify_order_refund_adjustments_v2(shopify_connection_id,order_identity_id,refunded_at);

ALTER TABLE henvalt.shopify_order_refund_adjustments_v2 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON henvalt.shopify_order_refund_adjustments_v2 FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE henvalt.shopify_order_refund_adjustments_v2 IS
  'Exact-store refund amounts from successful Shopify refund transactions. No raw payload, customer email or direct contact data is stored.';

CREATE OR REPLACE FUNCTION henvalt.project_verified_shopify_refund_v2(
  p_route_token text,
  p_delivery_id text,
  p_raw_body_base64 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_route record;
  v_body bytea;
  v_payload jsonb;
  v_body_digest text;
  v_refund_id text;
  v_order_id text;
  v_refunded_at timestamptz;
  v_total_tx_count integer:=0;
  v_valid_tx_count integer:=0;
  v_amount numeric(18,4);
  v_currency_min text;
  v_currency_max text;
  v_currency text;
  v_order henvalt.shopify_order_identity_v2%rowtype;
  v_adjustment_id uuid;
  v_existing record;
  v_total_refunded numeric(18,4);
BEGIN
  IF p_route_token IS NULL OR length(p_route_token)<40 OR length(p_route_token)>128
     OR p_delivery_id IS NULL OR length(btrim(p_delivery_id))=0
     OR p_raw_body_base64 IS NULL OR length(p_raw_body_base64)>2800000 THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','INVALID_REQUEST');
  END IF;

  BEGIN
    v_body:=pg_catalog.decode(p_raw_body_base64,'base64');
    v_payload:=pg_catalog.convert_from(v_body,'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','INVALID_BODY');
  END;

  IF pg_catalog.octet_length(v_body)=0 OR pg_catalog.octet_length(v_body)>2097152 THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','INVALID_BODY_SIZE');
  END IF;

  SELECT rt.tenant_id,rt.connection_id,rt.app_key,sc.shop_domain,
    sc.active AS connection_active,ar.lifecycle_status AS app_status,
    t.status::text AS tenant_status,d.id AS receipt_id,d.topic,
    d.raw_body_sha256,d.received_at
  INTO v_route
  FROM henvalt.shopify_webhook_route_tokens rt
  JOIN henvalt.shopify_connections sc
    ON sc.id=rt.connection_id AND sc.tenant_id=rt.tenant_id AND sc.app_key=rt.app_key
  JOIN henvalt.shopify_app_registry ar ON ar.app_key=rt.app_key
  JOIN henvalt.tenants t ON t.id=rt.tenant_id
  JOIN henvalt.shopify_webhook_deliveries d
    ON d.connection_id=rt.connection_id AND d.tenant_id=rt.tenant_id AND d.app_key=rt.app_key
  WHERE rt.token_hash=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_route_token,'UTF8'),'sha256'),'hex')
    AND rt.revoked_at IS NULL
    AND (rt.expires_at IS NULL OR rt.expires_at>pg_catalog.now())
    AND d.shopify_delivery_id=p_delivery_id
  FOR UPDATE OF d;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','VERIFIED_RECEIPT_NOT_FOUND');
  END IF;
  IF v_route.connection_active IS DISTINCT FROM true OR v_route.app_status<>'active'
     OR v_route.tenant_status<>'ACTIVE' THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','APP_CONNECTION_OR_TENANT_INACTIVE');
  END IF;
  IF v_route.topic<>'refunds/create' THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','UNSUPPORTED_REFUND_TOPIC');
  END IF;

  v_body_digest:=pg_catalog.encode(extensions.digest(v_body,'sha256'),'hex');
  IF v_body_digest IS DISTINCT FROM v_route.raw_body_sha256 THEN
    RETURN jsonb_build_object('accepted',false,'status','REJECTED','code','RECEIPT_BODY_MISMATCH');
  END IF;

  v_refund_id:=NULLIF(pg_catalog.btrim(v_payload->>'id'),'');
  v_order_id:=NULLIF(pg_catalog.btrim(v_payload->>'order_id'),'');
  IF v_refund_id IS NULL OR length(v_refund_id)>200 OR v_order_id IS NULL OR length(v_order_id)>200 THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status='REJECTED',failure_code='REFUND_OR_ORDER_ID_MISSING'
     WHERE id=v_route.receipt_id;
    RETURN jsonb_build_object('accepted',true,'status','REVIEW_REQUIRED','code','REFUND_OR_ORDER_ID_MISSING');
  END IF;

  SELECT * INTO v_order
  FROM henvalt.shopify_order_identity_v2
  WHERE tenant_id=v_route.tenant_id
    AND shopify_connection_id=v_route.connection_id
    AND shopify_order_id=v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status='RETRYABLE',failure_code='REFUND_ORDER_NOT_PROJECTED'
     WHERE id=v_route.receipt_id;
    RETURN jsonb_build_object('accepted',false,'status','RETRYABLE','code','REFUND_ORDER_NOT_PROJECTED');
  END IF;

  IF pg_catalog.jsonb_typeof(v_payload->'transactions')<>'array' THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status='RETRYABLE',failure_code='REFUND_TRANSACTIONS_UNAVAILABLE'
     WHERE id=v_route.receipt_id;
    RETURN jsonb_build_object('accepted',false,'status','RETRYABLE','code','REFUND_TRANSACTIONS_UNAVAILABLE');
  END IF;

  SELECT
    count(*) FILTER (WHERE pg_catalog.lower(tx->>'kind')='refund')::integer,
    count(*) FILTER (
      WHERE pg_catalog.lower(tx->>'kind')='refund'
        AND pg_catalog.lower(tx->>'status')='success'
        AND (tx->>'amount') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$'
        AND pg_catalog.upper(COALESCE(tx->>'currency','')) ~ '^[A-Z]{3}$'
    )::integer,
    sum(CASE
      WHEN pg_catalog.lower(tx->>'kind')='refund'
       AND pg_catalog.lower(tx->>'status')='success'
       AND (tx->>'amount') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$'
       AND pg_catalog.upper(COALESCE(tx->>'currency','')) ~ '^[A-Z]{3}$'
      THEN (tx->>'amount')::numeric
      ELSE NULL
    END)::numeric(18,4),
    min(pg_catalog.upper(tx->>'currency')) FILTER (
      WHERE pg_catalog.lower(tx->>'kind')='refund'
        AND pg_catalog.lower(tx->>'status')='success'
        AND (tx->>'amount') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$'
        AND pg_catalog.upper(COALESCE(tx->>'currency','')) ~ '^[A-Z]{3}$'
    ),
    max(pg_catalog.upper(tx->>'currency')) FILTER (
      WHERE pg_catalog.lower(tx->>'kind')='refund'
        AND pg_catalog.lower(tx->>'status')='success'
        AND (tx->>'amount') ~ '^[0-9]{1,12}([.][0-9]{1,4})?$'
        AND pg_catalog.upper(COALESCE(tx->>'currency','')) ~ '^[A-Z]{3}$'
    )
  INTO v_total_tx_count,v_valid_tx_count,v_amount,v_currency_min,v_currency_max
  FROM pg_catalog.jsonb_array_elements(v_payload->'transactions') tx;

  IF v_total_tx_count=0 OR v_valid_tx_count<>v_total_tx_count
     OR v_amount IS NULL OR v_amount<=0
     OR v_currency_min IS NULL OR v_currency_min<>v_currency_max
     OR v_order.currency IS NULL
     OR v_currency_min<>pg_catalog.upper(v_order.currency) THEN
    UPDATE henvalt.shopify_webhook_deliveries
       SET processing_status='RETRYABLE',failure_code='REFUND_AMOUNT_OR_CURRENCY_UNVERIFIED'
     WHERE id=v_route.receipt_id;
    RETURN jsonb_build_object('accepted',false,'status','RETRYABLE','code','REFUND_AMOUNT_OR_CURRENCY_UNVERIFIED');
  END IF;

  v_currency:=v_currency_min;
  BEGIN
    v_refunded_at:=NULLIF(v_payload->>'created_at','')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_refunded_at:=NULL;
  END;
  v_refunded_at:=COALESCE(v_refunded_at,v_route.received_at);

  INSERT INTO henvalt.shopify_order_refund_adjustments_v2(
    tenant_id,shopify_connection_id,order_identity_id,shopify_refund_id,
    refund_amount,currency,refunded_at,source_delivery_id,updated_at
  ) VALUES(
    v_route.tenant_id,v_route.connection_id,v_order.id,v_refund_id,
    v_amount,v_currency,v_refunded_at,v_route.receipt_id,pg_catalog.now()
  )
  ON CONFLICT(shopify_connection_id,shopify_refund_id) DO NOTHING
  RETURNING id INTO v_adjustment_id;

  -- A Shopify refund ID is immutable in this projection. Exact financial
  -- replays are idempotent; changed facts for an existing ID are rejected.
  IF v_adjustment_id IS NULL THEN
    SELECT id,tenant_id,order_identity_id,refund_amount,currency,refunded_at
    INTO v_existing
    FROM henvalt.shopify_order_refund_adjustments_v2
    WHERE shopify_connection_id=v_route.connection_id
      AND shopify_refund_id=v_refund_id
    FOR UPDATE;

    IF NOT FOUND THEN
      UPDATE henvalt.shopify_webhook_deliveries
         SET processing_status='RETRYABLE',failure_code='REFUND_ID_CONFLICT_ROW_UNAVAILABLE'
       WHERE id=v_route.receipt_id;
      RETURN jsonb_build_object('accepted',false,'status','RETRYABLE','code','REFUND_ID_CONFLICT_ROW_UNAVAILABLE');
    END IF;

    IF v_existing.tenant_id IS DISTINCT FROM v_route.tenant_id
       OR v_existing.order_identity_id IS DISTINCT FROM v_order.id
       OR v_existing.currency IS DISTINCT FROM v_currency
       OR v_existing.refund_amount IS DISTINCT FROM v_amount
       OR v_existing.refunded_at IS DISTINCT FROM v_refunded_at THEN
      UPDATE henvalt.shopify_webhook_deliveries
         SET processing_status='REJECTED',failure_code='REFUND_ID_PAYLOAD_CONFLICT'
       WHERE id=v_route.receipt_id;
      RETURN jsonb_build_object('accepted',true,'status','REJECTED','code','REFUND_ID_PAYLOAD_CONFLICT');
    END IF;

    v_adjustment_id:=v_existing.id;
  END IF;

  SELECT COALESCE(sum(refund_amount),0) INTO v_total_refunded
  FROM henvalt.shopify_order_refund_adjustments_v2
  WHERE tenant_id=v_route.tenant_id
    AND shopify_connection_id=v_route.connection_id
    AND order_identity_id=v_order.id
    AND currency=v_currency;

  IF v_order.total_value IS NOT NULL AND v_order.total_value>0
     AND pg_catalog.upper(v_order.currency)=v_currency
     AND COALESCE(v_order.financial_status,'') NOT IN ('voided','cancelled') THEN
    UPDATE henvalt.shopify_order_identity_v2
       SET financial_status=CASE
         WHEN v_total_refunded>=v_order.total_value THEN 'refunded'
         ELSE 'partially_refunded'
       END,
       updated_at=pg_catalog.now()
     WHERE id=v_order.id AND tenant_id=v_route.tenant_id
       AND shopify_connection_id=v_route.connection_id;
  END IF;

  UPDATE henvalt.shopify_webhook_deliveries
     SET processing_status='PROCESSED',processed_at=pg_catalog.now(),
         failure_code=NULL,
         metadata=COALESCE(metadata,'{}'::jsonb)||jsonb_build_object(
           'refund_projection','PROCESSED',
           'refund_adjustment_id',v_adjustment_id,
           'total_refunded',v_total_refunded,
           'currency',v_currency
         )
   WHERE id=v_route.receipt_id;

  RETURN jsonb_build_object('accepted',true,'status','PROCESSED',
    'refund_adjustment_id',v_adjustment_id,'total_refunded',v_total_refunded,'currency',v_currency);
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.project_verified_shopify_refund_v2(text,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.project_verified_shopify_refund_v2(text,text,text)
  TO service_role;

COMMIT;
