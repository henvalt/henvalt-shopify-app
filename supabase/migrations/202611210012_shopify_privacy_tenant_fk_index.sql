-- Cover the tenant_id foreign key on the Shopify privacy-request queue.
-- Candidate-only until the full isolated staging suite is approved.
CREATE INDEX IF NOT EXISTS shopify_privacy_requests_tenant_id_idx
  ON henvalt.shopify_privacy_requests (tenant_id);
