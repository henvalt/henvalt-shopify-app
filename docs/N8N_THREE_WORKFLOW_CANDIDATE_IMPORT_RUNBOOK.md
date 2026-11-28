# HENVALT three-workflow candidate import runbook

Status: offline candidate package only. The exports are inactive, credential-free and have not been imported or published.

## Candidate package

The GitHub Actions workflow `Build isolated three-workflow n8n candidates` generates:

- `HENVALT_INGEST_CANDIDATE_NO_SEND.json` — inactive replay-entry and durable-ack candidate.
- `HENVALT_RECOVERY_CANDIDATE_NO_SEND.json` — inactive candidate that preserves the existing intervention branch and adds lease-fenced Shopify replay and delivery-retry-generation handling.

The existing `HENVALT_DELIVERY` workflow is intentionally not exported or modified. The system remains exactly three logical workflows.

## Required binding after importing into an isolated n8n draft

1. Import the INGEST candidate and keep it inactive.
2. Import the RECOVERY candidate and keep it inactive.
3. Bind the RECOVERY candidate's `Call HENVALT_INGEST Replay Entry` node to the imported INGEST candidate ID (the export uses the reserved placeholder ID `00000000-0000-4000-8000-999999999999`).
4. Bind the RECOVERY candidate's existing `Call HENVALT_DELIVERY` node to the already-existing HENVALT_DELIVERY workflow ID (the export uses the reserved placeholder ID `00000000-0000-4000-8000-999999999996`). Do not create or clone a fourth workflow.
5. Rebind every removed Supabase credential to a staging-only credential. Replace every `supabase-staging.invalid` endpoint with the verified staging Supabase URL. Never paste a production service-role key into a staging workflow.
6. Re-run the full graph and credential audit. Confirm no credential references, webhook IDs, production Supabase URLs, production tokens, live MailerSend credentials, or active flags remain.
7. Execute only in an isolated staging n8n instance with provider egress blocked and staging send control disabled.

## Do not activate yet

The offline graph tests do not prove the imported nodes work in a live n8n runtime. Before activation, complete:

- Real owner-authenticated OAuth install on the approved Shopify development store.
- Signed Shopify webhook delivery through the staging Cloudflare ingress.
- Lease-fenced replay through every sequential business-write stage.
- Recovery candidate creation and scheduled intervention generation.
- Delivery worker authorization and negative provider-egress test.
- Order projection, attribution and ledger idempotency.
- Repeated-run idempotency and tenant-isolation acceptance.

The exports are not permission to publish workflows, create cron schedules, enable provider sending, or touch production.
