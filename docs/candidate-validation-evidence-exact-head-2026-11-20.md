# Candidate validation evidence — exact head 2026-11-20

## Scope

This report records GitHub Actions evidence for the current preparation branch head. It is candidate CI evidence only; it is not production runtime proof and does not authorize deployment, PR merge, n8n workflow publication, Shopify app release, or email sending.

Repository: henvalt/henvalt-shopify-app  
Branch: prep/public-app-hardening-2026-11-15  
Exact candidate HEAD: 89b64bfce7fa282ab9ff7451915644bc338059b2

## Exact-head workflow results

All referenced checks report the exact HEAD SHA above.

### Identity V2 validation

- Run 44775942533: completed successfully.
- Job: identity-v2-validation — success.
- Job steps independently inspected; all required steps completed successfully.
- Gitleaks repository secret scan passed.
- Complete repository Node regression suite: 464 tests, 464 passed, 0 failed.
- Additional exact-store uninstall / checkout provider gate / ambiguous reconciliation contracts: 15 tests, 15 passed, 0 failed.
- Identity, cost reservation, and privacy contract tests: 231 tests, 231 passed, 0 failed.
- Deno Edge Function type checks passed.
- Checkout and pixel readiness/auth runtime tests passed with outbound provider network blocked.
- Legacy V1 MailerSend sender fail-closed-by-default runtime test passed.
- Legacy V1 MailerSend Edge Function type-check passed.
- Pixel and checkout delivery, dashboard, and MailerSend webhook type checks passed.
- Candidate migrations 001–060 applied successfully to disposable PostgreSQL.
- Candidate SQL contract tests for store isolation, privacy processing/export/purge, consent, attribution, cost reservation, provider suppression, uninstall/redact stops and concurrent n8n work claims passed.

Run URL: https://github.com/henvalt/henvalt-shopify-app/actions/runs/44775942533

### Static and database validation

Run 44775954908 completed:
- static-validation: success.
- shopify-database-migration-validation: success.
- deploy-shopify-version: skipped.

Run URL: https://github.com/henvalt/henvalt-shopify-app/actions/runs/44775954908

The skipped deployment job is intentional for this preparation run. No Shopify app release was performed by this job.

## Non-blocking maintenance note

The identity validation log emitted a GitHub Actions warning that some actions target Node.js 20 and were forced to run on Node.js 24 due runner deprecation. This did not fail the run. Pinning/updating compatible action versions should be tracked as CI maintenance, not confused with a product test failure.

## What this evidence does not prove

- It does not prove production Edge Function source has the candidate interlock. The live production V1 sender remains a separate deployment target.
- It does not prove production n8n workflows are blocked. The three live workflows remain active and their sender paths require isolated runtime testing.
- It does not establish the n8n Cloud account's effective execution retention or data-redaction policy.
- It does not prove a real Shopify merchant install, eligible event, provider delivery, paid order, attribution or billing transaction.
- It does not authorize merging PR #6 or deploying any candidate code.

## Production safety status

PR #6 remains draft/open/unmerged at the time of this report. No production n8n workflow, Supabase function, secret, provider configuration, Shopify app release, or live email send was changed or authorized by these CI checks.

Production remains HOLD pending owner-approved cutover controls and separately approved change window.
