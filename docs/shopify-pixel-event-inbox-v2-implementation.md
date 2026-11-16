# Shopify Web Pixel V2 intake implementation

## Status
- Candidate migration only; not applied to live Supabase.
- The V2 RPC is additive and leaves `henvalt.ingest_pixel_event` untouched.
- The RPC resolves the authoritative tenant and `shopify_connection_id` only from an active, unrevoked pixel key whose origin is allowlisted and whose Shopify connection and tenant are active.
- It writes to a new server-only `shopify_pixel_event_inbox_v2` table with a composite connection/tenant foreign key and per-connection event idempotency.
- Exact duplicate retries are acknowledged; reuse of the same event ID with a different payload digest is rejected.
- Analytics consent gates client, customer, and checkout references. Marketing consent is stored separately and never substitutes for analytics consent.
- The V2 intake does not create canonical events, customers, sessions, aliases, checkouts, opportunities, recovery interventions, delivery requests, attribution, or billing records.

## Why the inbox is intentionally isolated
The existing V1 canonical-event writer and downstream recovery readers still have tenant-only identity semantics. Writing into canonical events now could cause a V2 event to be picked up by those legacy tenant-wide workers before they can enforce store identity. The inbox is therefore an explicit holding boundary. A future adapter may move events into canonical processing only after every downstream query, identity resolver, and writer is connection-aware and has passed two-store collision tests.

## Required next gate
1. Inventory and implement connection-aware customer, session, alias, checkout, and canonical-event writers.
2. Replace every affected V1 tenant-only `ON CONFLICT` writer and consumer before removing old uniqueness constraints.
3. Add explicit analytics-consent and marketing-consent behavior to the adapter.
4. Verify inactive/revoked pixel key and inactive store rejection.
5. Keep this inbox disconnected from recovery, delivery, attribution, and billing until the adapter gate is approved.

No production DDL/DML, backfill, function replacement, Worker/Edge deployment, n8n change, Shopify configuration, or release is performed by this candidate.
