BEGIN;
CREATE OR REPLACE FUNCTION henvalt.resolve_shopify_customer_contact_lookup_context_v2(p_connection_id uuid,p_customer_identity_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v record; v_token text; v_gid text;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
 IF p_connection_id IS NULL OR p_customer_identity_id IS NULL THEN RETURN jsonb_build_object('ready',false,'code','IDENTITY_REQUIRED'); END IF;
 SELECT sc.id connection_id,sc.tenant_id,sc.shop_domain,sc.active,sc.access_token_secret_ref,sc.access_token_expires_at,sc.token_type,sc.reauth_required_at,sc.scopes,ar.lifecycle_status,t.status::text tenant_status,ci.id customer_identity_id,ci.external_customer_reference
 INTO v FROM henvalt.shopify_connections sc
 JOIN henvalt.shopify_app_registry ar ON ar.app_key=sc.app_key
 JOIN henvalt.tenants t ON t.id=sc.tenant_id
 JOIN henvalt.shopify_customer_identity_v2 ci ON ci.tenant_id=sc.tenant_id AND ci.shopify_connection_id=sc.id AND ci.id=p_customer_identity_id
 WHERE sc.id=p_connection_id FOR SHARE OF sc,ci;
 IF NOT FOUND OR v.active IS DISTINCT FROM true OR v.tenant_status<>'ACTIVE' OR v.lifecycle_status<>'active' THEN RETURN jsonb_build_object('ready',false,'code','STORE_APP_OR_TENANT_INACTIVE'); END IF;
 IF v.shop_domain !~ '^[a-z0-9][a-z0-9-]*[.]myshopify[.]com$' OR v.token_type<>'offline_expiring' OR v.reauth_required_at IS NOT NULL OR NOT coalesce('read_customers'=ANY(v.scopes),false) THEN RETURN jsonb_build_object('ready',false,'code','CUSTOMER_SCOPE_OR_TOKEN_UNAVAILABLE'); END IF;
 IF v.access_token_secret_ref IS NULL OR v.access_token_secret_ref !~* '^[0-9a-f-]{36}$' OR v.access_token_expires_at IS NULL OR v.access_token_expires_at<=pg_catalog.now()+interval '2 minutes' THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_REFRESH_REQUIRED'); END IF;
 v_gid:=CASE WHEN v.external_customer_reference LIKE 'gid://shopify/Customer/%' THEN v.external_customer_reference WHEN v.external_customer_reference ~ '^[0-9]{1,30}$' THEN 'gid://shopify/Customer/'||v.external_customer_reference ELSE NULL END;
 IF v_gid IS NULL THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_CUSTOMER_REFERENCE_INVALID'); END IF;
 SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE id=v.access_token_secret_ref::uuid;
 IF v_token IS NULL OR length(v_token)<20 THEN RETURN jsonb_build_object('ready',false,'code','SHOPIFY_TOKEN_SECRET_UNAVAILABLE'); END IF;
 RETURN jsonb_build_object('ready',true,'connection_id',v.connection_id,'customer_identity_id',v.customer_identity_id,'shop_domain',v.shop_domain,'customer_gid',v_gid,'access_token',v_token);
END; $$;
REVOKE ALL ON FUNCTION henvalt.resolve_shopify_customer_contact_lookup_context_v2(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION henvalt.resolve_shopify_customer_contact_lookup_context_v2(uuid,uuid) TO service_role;
COMMIT;