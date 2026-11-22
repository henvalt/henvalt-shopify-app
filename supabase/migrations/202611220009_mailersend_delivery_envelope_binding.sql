-- Bind every provider message field to the database-authorized delivery request.
-- Recheck current tenant, consent, suppression, conversion and event eligibility
-- immediately before provider egress. Candidate migration only.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.assert_mailersend_delivery_envelope(
  p_tenant_id uuid,
  p_delivery_request_id uuid,
  p_to text,
  p_from_email text,
  p_from_name text,
  p_reply_to text,
  p_subject text,
  p_html_body text,
  p_text_body text
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
      pc.configuration,
      t.settings AS tenant_settings,
      m.recipient AS message_recipient,
      m.subject AS message_subject,
      m.body AS message_body
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
    JOIN henvalt.messages m
      ON m.id = dr.message_reference
     AND m.tenant_id = dr.tenant_id
     AND m.intervention_id = dr.intervention_id
    JOIN henvalt.opportunities o
      ON o.id = dr.opportunity_id
     AND o.tenant_id = dr.tenant_id
    JOIN henvalt.customers c
      ON c.id = o.customer_id
     AND c.tenant_id = o.tenant_id
    JOIN henvalt.recovery_interventions ri
      ON ri.id = dr.intervention_id
     AND ri.tenant_id = dr.tenant_id
     AND ri.opportunity_id = o.id
    JOIN henvalt.recovery_sequences rs
      ON rs.id = dr.recovery_id
     AND rs.tenant_id = dr.tenant_id
     AND rs.opportunity_id = o.id
    LEFT JOIN henvalt.checkouts ck
      ON ck.id = o.checkout_id
     AND ck.tenant_id = o.tenant_id
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
      AND o.status = 'ELIGIBLE'
      AND c.email_consent IS TRUE
      AND lower(COALESCE(c.email, '')) = lower(dr.recipient_reference)
      AND COALESCE(
        (henvalt.evaluate_opportunity_communication_eligibility(dr.tenant_id, o.id)->>'allowed')::boolean,
        false
      )
      AND ri.status = 'SENDING'
      AND rs.status IN ('SCHEDULED', 'ACTIVE')
      AND (
        o.opportunity_type::text IN ('BROWSE_ABANDONMENT', 'ABANDONED_CART')
        OR (o.checkout_id IS NOT NULL AND ck.id IS NOT NULL)
      )
      AND EXISTS (
        SELECT 1
        FROM henvalt.shopify_connections sc
        WHERE sc.tenant_id = o.tenant_id
          AND sc.active IS TRUE
          AND lower(sc.shop_domain) = lower(COALESCE(
            o.metadata->>'shop_domain',
            ck.metadata->>'shop_domain',
            ''
          ))
      )
      AND (
        CASE o.opportunity_type::text
          WHEN 'BROWSE_ABANDONMENT' THEN
            NOT henvalt.browse_opportunity_advanced(
              o.tenant_id,
              o.metadata->>'session_reference',
              o.source_event_id,
              NULLIF(o.metadata->>'last_activity_at', '')::timestamptz
            )
          WHEN 'ABANDONED_CART' THEN
            o.customer_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1
              FROM henvalt.checkouts cart_checkout
              WHERE cart_checkout.tenant_id = o.tenant_id
                AND cart_checkout.customer_id = o.customer_id
                AND cart_checkout.updated_at >= COALESCE(
                  NULLIF(o.metadata->>'last_activity_at', '')::timestamptz,
                  o.created_at
                )
                AND NULLIF(o.metadata->>'cart_token', '') IS NOT NULL
                AND cart_checkout.metadata->>'cart_token' = o.metadata->>'cart_token'
            )
          ELSE true
        END
      )
      AND NOT EXISTS (
        SELECT 1
        FROM henvalt.orders ord
        WHERE ord.tenant_id = o.tenant_id
          AND ord.cancelled_at IS NULL
          AND lower(COALESCE(ord.financial_status, '')) = 'paid'
          AND (
            (
              o.opportunity_type::text = 'ABANDONED_CART'
              AND ord.customer_id = o.customer_id
              AND ord.ordered_at >= COALESCE(
                NULLIF(o.metadata->>'last_activity_at', '')::timestamptz,
                o.created_at
              )
            )
            OR (
              o.opportunity_type::text = 'BROWSE_ABANDONMENT'
              AND ord.customer_id = o.customer_id
              AND ord.ordered_at >= o.created_at
            )
            OR (
              o.opportunity_type::text NOT IN ('ABANDONED_CART', 'BROWSE_ABANDONMENT')
              AND ord.checkout_id = o.checkout_id
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM henvalt.email_suppressions es
        WHERE es.tenant_id = o.tenant_id
          AND es.active IS TRUE
          AND (es.customer_id = c.id OR lower(es.email_normalized) = lower(dr.recipient_reference))
      )
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
        AND lower(COALESCE(s.message_recipient, '')) = lower(COALESCE(p_to, ''))
        AND lower(COALESCE(s.sender_reference, '')) = lower(COALESCE(p_from_email, ''))
        AND COALESCE(
          NULLIF(CASE
            WHEN COALESCE((s.tenant_settings #>> '{messaging_compliance,sender_profile,merchant_confirmed}')::boolean, false)
            THEN s.tenant_settings #>> '{messaging_compliance,sender_profile,legal_business_name}'
          END, ''),
          NULLIF(s.tenant_settings #>> '{messaging_compliance,sender_profile_suggestion,shop_name}', ''),
          NULLIF(s.metadata->>'from_name', ''),
          'HENVALT'
        ) = COALESCE(p_from_name, '')
        AND (
          lower(COALESCE(NULLIF(s.metadata->>'reply_to', ''), s.sender_reference, '')) =
            lower(COALESCE(p_reply_to, ''))
          OR EXISTS (
            SELECT 1
            FROM henvalt.customer_conversations cc
            WHERE cc.tenant_id = p_tenant_id
              AND cc.delivery_request_id = p_delivery_request_id
              AND cc.status NOT IN ('OPTED_OUT', 'CLOSED')
              AND p_reply_to ~* '^reply\+[0-9a-f]{64}@inbound\.henvalt\.com$'
              AND cc.reply_token_hash = encode(
                extensions.digest(
                  convert_to(
                    substring(p_reply_to FROM '(?i)^reply\+([0-9a-f]{64})@inbound\.henvalt\.com$'),
                    'UTF8'
                  ),
                  'sha256'
                ),
                'hex'
              )
          )
        )
        AND s.message_subject = p_subject
        AND henvalt.render_sender_identity_footer(p_tenant_id, s.message_body) = p_html_body
        AND henvalt.render_email_plain_text(
          henvalt.render_sender_identity_footer(p_tenant_id, s.message_body)
        ) = p_text_body
    ),
    false
  );
$function$;

REVOKE ALL ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text, text, text, text)
  TO service_role;

COMMENT ON FUNCTION henvalt.assert_mailersend_delivery_envelope(uuid, uuid, text, text, text, text, text, text, text) IS
  'Returns true only when the provider HTTP envelope matches the claimed tenant delivery, authorized message, current communication eligibility, and verified sender identity.';

COMMIT;
