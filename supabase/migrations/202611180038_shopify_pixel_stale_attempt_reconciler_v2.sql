-- HENVALT stale pixel attempt safety reconciler V2.
-- A process crash after permit consumption must never cause an automatic resend.
-- Stale AUTHORIZED attempts become AMBIGUOUS and keep their cost reservation.
BEGIN;
CREATE OR REPLACE FUNCTION henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(
 p_before timestamptz DEFAULT (pg_catalog.now()-interval '2 minutes'),
 p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_count integer:=0;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
 END IF;
 IF p_before IS NULL OR p_before>pg_catalog.now()-interval '2 minutes'
   OR p_before<pg_catalog.now()-interval '24 hours'
   OR p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
  RETURN jsonb_build_object('accepted',false,'code','INVALID_RECONCILIATION_WINDOW');
 END IF;
 WITH stale AS (
  SELECT id FROM henvalt.shopify_pixel_send_attempts_v2
  WHERE status='AUTHORIZED' AND created_at<=p_before
  ORDER BY created_at,id
  FOR UPDATE SKIP LOCKED
  LIMIT p_limit
 ), changed AS (
  UPDATE henvalt.shopify_pixel_send_attempts_v2 a
  SET status='AMBIGUOUS',updated_at=pg_catalog.now()
  FROM stale
  WHERE a.id=stale.id AND a.status='AUTHORIZED'
  RETURNING a.id
 )
 SELECT count(*)::integer INTO v_count FROM changed;
 RETURN jsonb_build_object('accepted',true,'marked_ambiguous',v_count,
  'provider_cost_reservation_released',false,'automatic_retry_performed',false);
END;
$function$;
REVOKE ALL ON FUNCTION henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(timestamptz,integer)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.mark_stale_shopify_pixel_send_attempts_ambiguous_v2(timestamptz,integer)
 TO service_role;
COMMIT;
