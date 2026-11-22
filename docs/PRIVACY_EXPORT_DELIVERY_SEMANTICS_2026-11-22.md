# Privacy export delivery semantics — candidate audit

Date: 2026-11-22  
Scope: candidate branch only. No production function, database, workflow, or Shopify configuration changed.

## Finding: the current export endpoint overstates delivery

The deployed v1 `henvalt-privacy-export` endpoint authenticates a Supabase user, requires exactly one OWNER/ADMIN tenant membership, reads an unexpired export for that tenant, then PATCHes `result_delivered_at` **before** constructing and returning the attachment response.

That timestamp proves only that the server authorized and attempted to begin a download response. It cannot prove that the merchant's browser received, saved, or opened the complete file. A connection failure after the PATCH leaves a false-positive delivery audit record.

The current field name `result_delivered_at` therefore has stronger semantics than the endpoint can establish.

## Safe remediation contract

1. Preserve the current deployed source under its audit-baseline path; never edit the baseline in place.
2. Rename the event semantically in a future schema/API version (for example, `download_response_started_at`) or record an append-only event such as `EXPORT_DOWNLOAD_RESPONSE_STARTED`.
3. Do not represent a response-start event as proof of receipt, download completion, or merchant review.
4. If stronger completion evidence is required, use an explicit client acknowledgement after the browser has received the complete payload; label that evidence as client-reported, not cryptographic proof of human receipt.
5. Keep export lookup tenant-scoped, owner/admin-gated, no-store, expiry-checked, and audited.
6. Add isolated tests for authorization, tenant isolation, expiry, response construction failure, and disconnect/acknowledgement semantics before replacing the deployed endpoint.
7. Keep Shopify privacy compliance topics disabled until the full request, redaction, export and delivery lifecycle is verified end-to-end.

## Current release effect

This is an additional privacy audit finding, not a remediation. The export endpoint remains an authenticated merchant download route; automatic Shopify delivery is not implemented or proven. Production remains NO-GO for public App Store privacy compliance.
