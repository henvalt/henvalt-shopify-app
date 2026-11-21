# Exact-store privacy lineage preflight

Run `docs/sql/exact-store-privacy-lineage-preflight-read-only.sql` against the HENVALT Supabase project to re-check the schema-level lineage gate. It reports only table/column presence and aggregate connection counts. It does not expose customer data, payloads, secrets, or shop domains, and it performs no writes.

The production snapshot from 2026-11-16 found that none of the listed core business tables carried `shopify_connection_id` or `app_key`; the existing legacy privacy request table had shop domain and Shopify shop ID but no connection/app foreign key. The new V2 privacy inbox remains separate and review-gated until this gap is resolved.

The preflight safety test is part of the branch CI suite; it checks metadata-only column presence and aggregate counts without selecting personal data fields.
