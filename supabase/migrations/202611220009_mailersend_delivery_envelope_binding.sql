-- Bind the provider HTTP envelope to the database-authorized delivery request.
-- Candidate migration only: do not apply to production without isolated staging acceptance.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.assert_mailersend_delivery_envelope(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_to text,
  p_from_email text,
  p_from_name text,
  p_reply_to text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, henvalt, pg_temp
AS $function$
  WITH selected_identity AS (
    SELECT
      dr.recipient_reference,
      si.sender_reference,
      si.metadata,
      pc.configuration
    FROM henvalt.delivery_requests dr
    JOIN henvalt.sending_identities si
      ON si.tenant_id = dr.tenant_id
     AND si.channel = dr.channel
     AND si.delivery_mode = dr.delivery_mode
     AND si.active IS TRUE
    JOIN henvalt.provider_configs pc
      ON pc.id = si.provider_config_id
     AND pc.tenant_id = dr.tenant_id
     AND pc.channel = dr.channel
     AND pc.active IS TRUE
     AND lower(pc.provider) = lower(si.provider)
    JOIN henvalt.tenants t
      ON t.id = dr.tenant_id
     AND t.status = 'ACTIVE'
    WHERE dr.id = p_delivery_request_id
      AND dr.tenant_id = p_tenant_id
      AND dr.status = 'UNKNOWN'
      AND dr.provider_claimed_at IS NOT NULL
      AND dr.channel = 'EMAIL'
      AND lower(COALESCE(dr.provider, '')) = 'mailersend'
      AND lower(si.provider) = 'mailersend'
      AND pc.configuration->>'credential_validated' = 'true'
      AND NULLIF(btrim(pc.configuration->>'verified_domain'), '') IS NOT NULL
      AND (
        lower(split_part(si.sender_reference, '@', 2)) = lower(pc.configuration->>'verified_domain')
        OR lower(split_part(si.sender_reference, '@', 2)) LIKE '%.' || lower(pc.configuration->>'verified_domain')
      )
    ORDER BY si.updated_at DESC NULLS LAST, si.created_at DESC
    LIMIT 1
  )
  SELECT COALESCE(
    EXISTS (
      SELECT 1
      FROM selected_identity s
      WHERE lower(COALESCE(s.recipient_reference, '')) = lower(COALESCE(p_to, ''))
        AND lower(COALESCE(s.sender_reference, '')) = lower(COALESCE(p_from_email, ''))
        AND COALESCE(s.metadata->>'from_name', '') = COALESCE(p_from_name, '')
        AND lower(COALESCE(s.metadata->>'reply_to', s.sender_reference, '')) =
            lower(COALESCE(p_reply_to, ''))
    ),
    false
  );
$function$;

REVOKE ALL ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text)
  TO service_role;

COMMENT ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text) IS
  'Returns true only when the HTTP recipient and sender headers exactly match the claimed tenant delivery request and its active verified MailerSend identity.';

COMMIT;
