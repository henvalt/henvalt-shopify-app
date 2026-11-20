# Exact-head CI evidence — 2026-11-20

Commit under validation: `cb3149fd154b61548fc9d18139dcdbd0910e0643`

Branch: `prep/public-app-hardening-2026-11-15`

## Results

- GitHub Actions run `44779289176` — Shopify app configuration checks and deployment: **success**.
  - Disposable PostgreSQL migration validation: success.
  - Static validation: success.
  - Shopify deployment job: **skipped** (no deployment performed).
- GitHub Actions run `44779289161` — HENVALT exact-store identity V2 validation: **success**.
  - Repository secret scan: success.
  - Complete repository Node regression suite: success.
  - Edge Function type checks: success.
  - Candidate checkout/pixel readiness and exact-store runtime tests: success.
  - Legacy V1 MailerSend fail-closed-by-default runtime test: success.
  - Disposable PostgreSQL migrations 001–060 and database/privacy/attribution/cost/recovery contract tests: success.

## Scope and limitations

These are CI results for repository candidates and disposable test infrastructure. The Shopify deployment job was skipped. This evidence does not establish that production n8n workflows, Supabase Edge Functions, secrets, or provider settings have been changed or disabled. No production stop action is approved by this record. Production remains untouched and the live V1 MailerSend sender must still be treated as send-capable until an explicitly approved deployment is independently verified.

Retention/redaction settings in the live n8n account remain unverified; workflow API metadata alone is insufficient evidence. Isolated staging is not established by these CI runs.
