# Exact-head CI result — no-send interlock — 20 November 2026

**Candidate commit:** `a1d9b68fc334609f848ab3255428e27819911cfa`  
**Branch:** `prep/public-app-hardening-2026-11-15`  
**PR:** #6 — open, draft, unmerged

## Verified workflow runs

- Identity V2 validation: [run 44772879896](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44772879896) — completed, **success**, run #2313, exact `head_sha` matches the candidate commit above.
- Shopify app configuration checks: [run 44772880046](https://github.com/henvalt/henvalt-shopify-app/actions/runs/44772880046) — completed, **success**, run #1353, exact `head_sha` matches the candidate commit above.

The Identity V2 run's completed job steps include:
- Complete repository Node regression suite — success.
- Secret scan — success.
- Identity/cost/privacy contract tests — success.
- Repository Edge Function type checks — success.
- Checkout/pixel delivery authorization/readiness tests with outbound network blocked — success.
- Legacy V1 MailerSend sender fails-closed-by-default runtime test — success.
- Legacy V1 MailerSend Edge Function type check — success.
- Candidate migrations 001–060 applied to disposable PostgreSQL and lifecycle/contract tests — success.

The Shopify configuration run completed static validation and disposable database migration validation; the Shopify deployment job was **skipped**.

## Scope and limits

This is candidate CI evidence only. It does not prove that production has the interlock, that production sends are disabled, that n8n execution retention/redaction is configured correctly, or that every active production caller is contained. The live production V1 Edge Function remains the previously inspected active version 1 without the candidate readiness check.

No production Edge Function, secret, database, n8n workflow, Shopify app, Cloudflare Worker, MailerSend setting, or customer delivery was changed by these CI runs. PR #6 remains draft and unmerged.
