-- HENVALT exact-store customer redaction FK dependency inventory V2.
-- Read-only catalog metadata; no customer data, DML, or retention policy.

BEGIN;

CREATE OR REPLACE FUNCTION henvalt.shopify_customer_redaction_fk_dependency_map_v2()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH RECURSIVE descendants(relid, depth, path) AS (
    SELECT
      pg_catalog.to_regclass('henvalt.shopify_customer_identity_v2')::oid,
      0,
      ARRAY[pg_catalog.to_regclass('henvalt.shopify_customer_identity_v2')::oid]
    UNION ALL
    SELECT
      fk.conrelid,
      d.depth + 1,
      d.path || fk.conrelid
    FROM descendants d
    JOIN pg_catalog.pg_constraint fk
      ON fk.contype = 'f'
     AND fk.confrelid = d.relid
    WHERE d.depth < 12
      AND NOT fk.conrelid = ANY(d.path)
  ),
  edges AS (
    SELECT DISTINCT ON (fk.oid)
      fk.oid,
      fk.conname,
      fk.conrelid,
      fk.confrelid,
      fk.conkey,
      fk.confkey,
      fk.confdeltype,
      fk.convalidated,
      fk.condeferrable,
      fk.condeferred,
      d.depth
    FROM descendants d
    JOIN pg_catalog.pg_constraint fk
      ON fk.contype = 'f'
     AND fk.confrelid = d.relid
    ORDER BY fk.oid, d.depth
  )
  SELECT pg_catalog.jsonb_build_object(
    'root_table', 'henvalt.shopify_customer_identity_v2',
    'read_only', true,
    'depth_limit', 12,
    'dependency_count', (SELECT count(*) FROM edges),
    'dependencies', COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'constraint', e.conname,
          'referencing_table', child_ns.nspname || '.' || child.relname,
          'referenced_table', parent_ns.nspname || '.' || parent.relname,
          'referencing_columns', (
            SELECT pg_catalog.array_agg(child_att.attname ORDER BY k.ordinality)
            FROM pg_catalog.unnest(e.conkey) WITH ORDINALITY AS k(attnum, ordinality)
            JOIN pg_catalog.pg_attribute child_att
              ON child_att.attrelid = e.conrelid
             AND child_att.attnum = k.attnum
          ),
          'referenced_columns', (
            SELECT pg_catalog.array_agg(parent_att.attname ORDER BY k.ordinality)
            FROM pg_catalog.unnest(e.confkey) WITH ORDINALITY AS k(attnum, ordinality)
            JOIN pg_catalog.pg_attribute parent_att
              ON parent_att.attrelid = e.confrelid
             AND parent_att.attnum = k.attnum
          ),
          'on_delete', CASE e.confdeltype
            WHEN 'a' THEN 'NO ACTION'
            WHEN 'r' THEN 'RESTRICT'
            WHEN 'c' THEN 'CASCADE'
            WHEN 'n' THEN 'SET NULL'
            WHEN 'd' THEN 'SET DEFAULT'
            ELSE 'UNKNOWN'
          END,
          'validated', e.convalidated,
          'deferrable', e.condeferrable,
          'initially_deferred', e.condeferred,
          'depth_from_customer_identity', e.depth + 1
        )
        ORDER BY child_ns.nspname, child.relname, e.conname
      )
      FROM edges e
      JOIN pg_catalog.pg_class child ON child.oid = e.conrelid
      JOIN pg_catalog.pg_namespace child_ns ON child_ns.oid = child.relnamespace
      JOIN pg_catalog.pg_class parent ON parent.oid = e.confrelid
      JOIN pg_catalog.pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
    ), '[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION henvalt.shopify_customer_redaction_fk_dependency_map_v2()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION henvalt.shopify_customer_redaction_fk_dependency_map_v2()
  TO service_role;

COMMENT ON FUNCTION henvalt.shopify_customer_redaction_fk_dependency_map_v2() IS
  'Read-only recursive PostgreSQL FK dependency inventory rooted at exact-store customer identity V2. Does not inspect customer rows or mutate data.';

COMMIT;
