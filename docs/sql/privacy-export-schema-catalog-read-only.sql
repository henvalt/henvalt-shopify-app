-- HENVALT privacy-export schema catalog — READ-ONLY ONLY.
-- Run in Supabase SQL editor during a controlled schema review.
-- Emits schema metadata only: no row counts, customer values, payloads, emails,
-- tokens, secret material, DDL, DML, or function calls with side effects.
--
-- Purpose: discover every henvalt table that may carry customer/session/
-- checkout/order/event/recovery/delivery/consent data, then show exact lineage
-- columns and declared FK edges. This does not prove historical rows satisfy
-- NOT VALID constraints or establish that an unlinked row belongs to a store.

WITH candidate_tables AS (
  SELECT
    c.oid AS relation_oid,
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relkind AS relation_kind
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'henvalt'
    AND c.relkind IN ('r', 'p')
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = c.oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND (
          a.attname IN (
            'tenant_id', 'shopify_connection_id', 'connection_id', 'app_key',
            'customer_id', 'customer_identity_id', 'shopify_customer_id',
            'external_customer_reference', 'email', 'email_normalized',
            'phone', 'session_id', 'session_reference', 'alias_reference',
            'checkout_id', 'checkout_identity_id', 'checkout_token',
            'shopify_checkout_id', 'order_id', 'order_identity_id',
            'shopify_order_id', 'source_event_id', 'event_id',
            'opportunity_id', 'intervention_id', 'recovery_id',
            'send_attempt_id', 'delivery_attempt_id', 'payload',
            'metadata', 'recipient', 'recipient_email', 'consent_state'
          )
          OR c.relname ~* '(customer|session|checkout|order|event|opportun|recover|interven|deliver|message|consent|suppress|attribut|refund|privacy|pixel|webhook|email)'
        )
    )
),
columns_by_table AS (
  SELECT
    a.attrelid AS relation_oid,
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'name', a.attname,
        'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
        'nullable', NOT a.attnotnull,
        'has_default', a.atthasdef,
        'identity', a.attidentity <> ''
      )
      ORDER BY a.attnum
    ) AS columns
  FROM pg_catalog.pg_attribute a
  JOIN candidate_tables t ON t.relation_oid = a.attrelid
  WHERE a.attnum > 0
    AND NOT a.attisdropped
  GROUP BY a.attrelid
),
foreign_keys AS (
  SELECT
    fk.conrelid AS relation_oid,
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'constraint', fk.conname,
        'references', parent_ns.nspname || '.' || parent.relname,
        'from_columns', (
          SELECT pg_catalog.jsonb_agg(child_att.attname ORDER BY k.ordinality)
          FROM pg_catalog.unnest(fk.conkey) WITH ORDINALITY AS k(attnum, ordinality)
          JOIN pg_catalog.pg_attribute child_att
            ON child_att.attrelid = fk.conrelid
           AND child_att.attnum = k.attnum
        ),
        'to_columns', (
          SELECT pg_catalog.jsonb_agg(parent_att.attname ORDER BY k.ordinality)
          FROM pg_catalog.unnest(fk.confkey) WITH ORDINALITY AS k(attnum, ordinality)
          JOIN pg_catalog.pg_attribute parent_att
            ON parent_att.attrelid = fk.confrelid
           AND parent_att.attnum = k.attnum
        ),
        'validated', fk.convalidated,
        'deferrable', fk.condeferrable,
        'on_delete', CASE fk.confdeltype
          WHEN 'a' THEN 'NO ACTION'
          WHEN 'r' THEN 'RESTRICT'
          WHEN 'c' THEN 'CASCADE'
          WHEN 'n' THEN 'SET NULL'
          WHEN 'd' THEN 'SET DEFAULT'
          ELSE 'UNKNOWN'
        END
      )
      ORDER BY fk.conname
    ) AS constraints
  FROM pg_catalog.pg_constraint fk
  JOIN candidate_tables child ON child.relation_oid = fk.conrelid
  JOIN pg_catalog.pg_class parent ON parent.oid = fk.confrelid
  JOIN pg_catalog.pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  WHERE fk.contype = 'f'
  GROUP BY fk.conrelid
)
SELECT pg_catalog.jsonb_build_object(
  'read_only', true,
  'scope', 'henvalt schema tables with customer or operational data indicators',
  'historical_rows_proven', false,
  'tables', COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'table', t.schema_name || '.' || t.table_name,
        'relation_kind', CASE t.relation_kind WHEN 'p' THEN 'partitioned' ELSE 'table' END,
        'columns', c.columns,
        'foreign_keys', COALESCE(f.constraints, '[]'::jsonb)
      )
      ORDER BY t.table_name
    ),
    '[]'::jsonb
  )
) AS privacy_export_schema_catalog
FROM candidate_tables t
JOIN columns_by_table c ON c.relation_oid = t.relation_oid
LEFT JOIN foreign_keys f ON f.relation_oid = t.relation_oid;
