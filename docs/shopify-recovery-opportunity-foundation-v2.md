# Exact-store checkout recovery opportunity foundation V2

Status: candidate migration on the preparation branch; not applied or deployed.

## What it does

The service-only promotion function converts eligible exact-store checkout candidates into one opportunity record per candidate. It rechecks the active app, connection, tenant, open checkout, eligibility time and absence of a same-store order.

Every opportunity carries app, connection, tenant, candidate, checkout, optional customer identity and verified source-receipt lineage. Composite foreign keys prevent those records from crossing stores.

A candidate with no exact-store customer identity or missing value/currency is retained as REVIEW_REQUIRED. A candidate with the required minimum identity/value metadata becomes CONTACT_RESOLUTION_PENDING. This is not permission to send.

## What it deliberately does not do

- Store email, phone, address or raw webhook payload.
- Resolve a contact or infer marketing consent.
- Create a sequence or intervention.
- Enqueue the existing n8n recovery worker.
- Create a delivery request or authorize a send.
- Attribute an order or create a billable revenue entry.

The function is bounded, idempotent and service_role-only. Its response always reports delivery_authorized=false.

## Next dependency

Implement exact-store contact resolution and current consent checks. Only after those checks succeed should a later stage create a recovery sequence/intervention and a short-lived delivery authorization.
