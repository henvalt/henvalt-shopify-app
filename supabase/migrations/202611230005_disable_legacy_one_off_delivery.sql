-- Disable the legacy one-off test email path before immutable-generation cutover.
-- The old reauthorization RPC resets a FAILED row to PENDING, clears its claim,
-- and temporarily mutates tenant recovery settings. The token RPC also embeds a
-- hard-coded test-only exception. Neither behavior is valid for production retries.
-- Candidate only; apply only with the corresponding n8n route removed/replaced.

BEGIN;

DO $patch$
DECLARE
  v_oid regprocedure;
  v_definition text;
  v_patched text;
BEGIN
  v_oid := to_regprocedure('henvalt.get_mailersend_token_for_delivery_legacy_v1(uuid,uuid)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'LEGACY_ONE_OFF_TOKEN_RPC_MISSING'; END IF;
  v_definition := pg_get_functiondef(v_oid);
  IF position('6d769024-cd44-4da4-be1d-a25a3dca0660' IN v_definition) = 0
     OR position('henvalt-one-off-email-test-2026-11-14-v1' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'LEGACY_ONE_OFF_TOKEN_ALLOWLIST_NOT_FOUND';
  END IF;
  v_patched := regexp_replace(
    v_definition,
    $re$OR\s+\(\s+dr\.tenant_id = '6d769024-cd44-4da4-be1d-a25a3dca0660'::uuid\s+AND dr\.opportunity_id = '871ad489-d120-4771-9164-db32fe7015b6'::uuid\s+AND dr\.recipient_reference = 'urmuhammadrehan18@gmail\.com'\s+AND dr\.idempotency_key = 'henvalt-one-off-email-test-2026-11-14-v1'\s+AND EXISTS \(SELECT 1 FROM henvalt\.messages tm WHERE tm\.id = dr\.message_reference AND tm\.tenant_id = dr\.tenant_id AND tm\.metadata->>'test_only' = 'true'\)\s+\)$re$,
    '',
    'n'
  );
  IF v_patched = v_definition
     OR position('6d769024-cd44-4da4-be1d-a25a3dca0660' IN v_patched) > 0
     OR position('henvalt-one-off-email-test-2026-11-14-v1' IN v_patched) > 0 THEN
    RAISE EXCEPTION 'LEGACY_ONE_OFF_TOKEN_ALLOWLIST_PATCH_FAILED';
  END IF;
  EXECUTE v_patched;
END;
$patch$;

CREATE OR REPLACE FUNCTION henvalt.reauthorize_one_off_test_delivery(
  p_delivery_request_id uuid,
  p_recipient text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO henvalt, public, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'LEGACY_ONE_OFF_DELIVERY_DISABLED_FOR_IMMUTABLE_GENERATIONS'
    USING ERRCODE = '55000';
END;
$function$;

CREATE OR REPLACE FUNCTION henvalt.prepare_one_off_test_delivery(
  p_opportunity_id uuid,
  p_recipient text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO henvalt, public, extensions, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'LEGACY_ONE_OFF_DELIVERY_DISABLED_FOR_IMMUTABLE_GENERATIONS'
    USING ERRCODE = '55000';
END;
$function$;

REVOKE ALL ON FUNCTION henvalt.reauthorize_one_off_test_delivery(uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION henvalt.prepare_one_off_test_delivery(uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION henvalt.reauthorize_one_off_test_delivery(uuid,text) IS
  'Disabled: legacy in-place FAILED -> PENDING reset violates immutable delivery generations.';
COMMENT ON FUNCTION henvalt.prepare_one_off_test_delivery(uuid,text) IS
  'Disabled: legacy test sender temporarily mutates tenant recovery settings and bypasses production onboarding.';

COMMIT;
