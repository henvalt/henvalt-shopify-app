ALTER TYPE henvalt.opportunity_type ADD VALUE IF NOT EXISTS 'BROWSE_ABANDONMENT';

ALTER TABLE henvalt.opportunities
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS opportunities_browse_metadata_idx
  ON henvalt.opportunities (tenant_id, created_at DESC);
