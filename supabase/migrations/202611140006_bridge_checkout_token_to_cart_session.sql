-- Bridge Shopify checkout tokens to the tenant-scoped browser session already
-- associated with the cart token on the same canonical event.
-- This is intentionally tenant-scoped and conflict-safe: an existing checkout-token
-- alias is never overwritten, and a cart alias is used only when its session exists.

CREATE OR REPLACE FUNCTION henvalt.resolve_identity(p_event_id uuid)
RETURNS TABLE(customer_id uuid, checkout_id uuid, session_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'henvalt', 'public'
AS $function$
DECLARE
  v_tenant_id uuid;
  v_email text;
  v_customer_reference text;
  v_session_reference text;
  v_anonymous_reference text;
  v_resolved_session_reference text;
  v_cart_session_reference text;
  v_existing_alias_reference text;
  v_resolved_customer_id uuid;
BEGIN
  SELECT tenant_id, email, customer_reference, session_reference, anonymous_reference
    INTO v_tenant_id, v_email, v_customer_reference, v_session_reference, v_anonymous_reference
  FROM henvalt.canonical_events
  WHERE id = p_event_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Canonical event not found: %', p_event_id;
  END IF;

  customer_id := NULL;
  checkout_id := NULL;
  session_id := NULL;
  v_resolved_session_reference := v_session_reference;

  IF v_customer_reference IS NOT NULL THEN
    SELECT c.id INTO customer_id
    FROM henvalt.customers c
    WHERE c.tenant_id = v_tenant_id
      AND c.shopify_customer_id = v_customer_reference
    LIMIT 1;
  END IF;

  IF customer_id IS NULL AND v_email IS NOT NULL THEN
    SELECT c.id INTO customer_id
    FROM henvalt.customers c
    WHERE c.tenant_id = v_tenant_id
      AND lower(c.email) = lower(v_email)
    ORDER BY c.created_at ASC
    LIMIT 1;
  END IF;

  v_resolved_customer_id := customer_id;

  IF v_session_reference IS NOT NULL THEN
    -- Preserve a previously established checkout-token mapping first.
    SELECT sa.session_reference
      INTO v_existing_alias_reference
    FROM henvalt.session_aliases sa
    WHERE sa.tenant_id = v_tenant_id
      AND sa.alias_reference = v_session_reference
    LIMIT 1;

    IF v_existing_alias_reference IS NOT NULL THEN
      v_resolved_session_reference := v_existing_alias_reference;
    ELSIF v_anonymous_reference IS NOT NULL
      AND v_anonymous_reference <> v_session_reference THEN
      -- Shopify checkout events can carry a checkout token as session_reference
      -- and the originating cart token as anonymous_reference. Resolve the cart
      -- token only inside this tenant, and only bridge if its target session exists.
      SELECT sa.session_reference
        INTO v_cart_session_reference
      FROM henvalt.session_aliases sa
      WHERE sa.tenant_id = v_tenant_id
        AND sa.alias_reference = v_anonymous_reference
      LIMIT 1;

      IF v_cart_session_reference IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM henvalt.sessions s
          WHERE s.tenant_id = v_tenant_id
            AND s.session_reference = v_cart_session_reference
        ) THEN
        INSERT INTO henvalt.session_aliases (
          tenant_id, alias_reference, session_reference
        )
        VALUES (
          v_tenant_id, v_session_reference, v_cart_session_reference
        )
        ON CONFLICT (tenant_id, alias_reference) DO NOTHING;

        -- Re-read after insert to handle concurrent or pre-existing mappings
        -- without ever overwriting another session's alias.
        SELECT sa.session_reference
          INTO v_resolved_session_reference
        FROM henvalt.session_aliases sa
        WHERE sa.tenant_id = v_tenant_id
          AND sa.alias_reference = v_session_reference
        LIMIT 1;
      END IF;
    END IF;

    SELECT s.id INTO session_id
    FROM henvalt.sessions s
    WHERE s.tenant_id = v_tenant_id
      AND s.session_reference = v_resolved_session_reference
    LIMIT 1;

    IF session_id IS NULL THEN
      INSERT INTO henvalt.sessions (
        tenant_id, customer_id, session_reference, first_seen_at, last_seen_at
      )
      VALUES (
        v_tenant_id, customer_id, v_resolved_session_reference, now(), now()
      )
      ON CONFLICT (tenant_id, session_reference)
      DO UPDATE SET
        customer_id = coalesce(henvalt.sessions.customer_id, excluded.customer_id),
        last_seen_at = now()
      RETURNING id INTO session_id;
    ELSIF customer_id IS NOT NULL THEN
      UPDATE henvalt.sessions s
      SET customer_id = coalesce(v_resolved_customer_id, s.customer_id),
          last_seen_at = now()
      WHERE s.id = session_id;
    END IF;
  END IF;

  IF v_email IS NOT NULL THEN
    SELECT co.id INTO checkout_id
    FROM henvalt.checkouts co
    WHERE co.tenant_id = v_tenant_id
      AND lower(co.email) = lower(v_email)
      AND (
        v_session_reference IS NULL
        OR co.session_reference = v_session_reference
      )
    ORDER BY co.created_at DESC
    LIMIT 1;
  END IF;

  RETURN NEXT;
END;
$function$;
