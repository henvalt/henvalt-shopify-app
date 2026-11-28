# HENVALT V1 whole-system staging acceptance matrix

**Target:** isolated staging only  
**Release mode:** no-send until all safety gates pass  
**Production:** do not apply migrations, publish workflows, deploy Edge Functions, release Shopify versions, or send provider messages as part of this matrix.

## Gate 0 — environment identity
- [ ] Staging Supabase project is distinct from production project `ocyplckdojdubyrsxcxa`.
- [ ] Staging n8n workflow copies have distinct IDs and isolated credentials.
- [ ] Shopify development store is explicitly identified; OAuth app and webhook URLs point only to staging.
- [ ] MailerSend uses a provider sandbox or network-denied stub; no live recipient or production API token is present.
- [ ] Exact commit, migration list, workflow version IDs, Edge Function versions and environment identifiers are recorded.

## Shopify OAuth and installation
| ID | Test | Expected evidence |
|---|---|---|
| AUTH-01 | Unauthenticated install initiation | Rejected; no OAuth state created |
| AUTH-02 | Valid owner-authenticated install start | One-time hashed state with bounded TTL |
| AUTH-03 | Invalid/expired/replayed state | Callback rejected; no connection activated |
| AUTH-04 | Invalid Shopify callback HMAC | Rejected; no token stored |
| AUTH-05 | Valid callback | Exact shop/tenant connection linked; only expected scopes stored |
| AUTH-06 | Webhook registration | All required topics registered and IDs recorded |
| AUTH-07 | Uninstall webhook | Exact connection deactivated; future sends denied |
| AUTH-08 | Expiring offline token refresh | Atomic claim, token pair rotation, persisted expiries, safe retry on persistence failure |

## Webhook ingestion and tenant isolation
| ID | Test | Expected evidence |
|---|---|---|
| EVT-01 | Valid signed Shopify webhook | HMAC verified before event processing |
| EVT-02 | Invalid signature | Rejected before any canonical event/customer/opportunity mutation |
| EVT-03 | Duplicate webhook ID/body | Idempotent acknowledgement; no duplicate opportunity |
| EVT-04 | Same event ID with different body | Rejected and audited |
| EVT-05 | Unknown shop | Rejected; no cross-tenant lookup fallback |
| EVT-06 | Consent update | Consent state updated and suppression cascade applied |
| EVT-07 | Paid order arrives before send | Opportunity/recovery suppressed before provider claim |
| EVT-08 | Refund/cancel adjustment | Ledger adjusted idempotently, never double-counted |

## Storefront pixel and consent
| ID | Test | Expected evidence |
|---|---|---|
| PIX-01 | Active key + allowed exact origin | Accepted into the intended tenant/connection scope |
| PIX-02 | Unknown/revoked key or wrong origin | Rejected; no inbox/canonical mutation |
| PIX-03 | Analytics consent false | No identity-bearing analytics/client/customer/checkout references persisted |
| PIX-04 | Marketing consent false | Must not be treated as permission for email recovery |
| PIX-05 | Event replay | Duplicate event accepted idempotently; body mismatch rejected |
| PIX-06 | Rate limit | Over-limit requests rejected without storefront blocking |
| PIX-07 | Pixel extension validation/release | Shopify CLI validation, app version release, pixel activation and real staging storefront event evidence |
| PIX-08 | V2 inbox adapter | Do not claim browse recovery until the connection-aware adapter and every downstream reader/writer are store-aware |
| PIX-09 | Existing browse opportunity after consent revocation / missing source event | Recovery context, authorization and provider-token claim all fail closed; no provider credential released |

## Recovery orchestration
| ID | Test | Expected evidence |
|---|---|---|
| REC-01 | Eligible checkout abandonment | One opportunity, one sequence, one intervention |
| REC-02 | Eligible cart abandonment | One opportunity after inactivity threshold; no duplicate on repeated webhook |
| REC-03 | Browse abandonment | Exact store/session scope and analytics consent; no email identity without permission |
| REC-04 | Payment failure | Valid payment event, customer communication eligibility and correct sequence policy |
| REC-05 | Job claim race | At most one worker claims a job |
| REC-06 | Worker crash/lease expiry | Stale job recovered once; retry bounded |
| REC-07 | Order arrives during recovery | No provider credential released |
| REC-08 | Customer unsubscribes or suppression event arrives | Pending sequence/interventions cancelled; all later claims denied |

## Delivery and global no-send
| ID | Test | Expected evidence |
|---|---|---|
| DEL-01 | Global interlock default | Missing row or false value denies |
| DEL-02 | Ordinary recovery authorization | Denied with SQLSTATE 42501 while closed |
| DEL-03 | Provider token RPC | Denied before token release while closed |
| DEL-04 | Manual one-off test path | Denied at the same DB boundary while closed |
| DEL-05 | Direct insert already in UNKNOWN | Denied while closed |
| DEL-06 | Provider claim timestamp update | Denied while closed |
| DEL-07 | Consent/suppression/order checks | Independently deny even when staging interlock is deliberately opened |
| DEL-08 | Idempotency and retries | No duplicate provider attempts |
| DEL-09 | Provider timeout ambiguity | State remains ambiguous; no unsafe automatic resend |
| DEL-10 | Provider emergency revocation | Documented and tested separately; database gate cannot recall a credential already released to an in-flight request |
| DEL-11 | Non-send routes while closed | Unsubscribe, tracking, privacy, signed provider events and inbound replies remain functional |
| DEL-12 | Shopify usage billing egress | `HENVALT_SHOPIFY_BILLING_EGRESS_ENABLED` is unset; worker refuses before database/token/provider calls; runtime firewall independently denies outbound Shopify GraphQL |

## Dashboard, attribution and billing
| ID | Test | Expected evidence |
|---|---|---|
| UI-01 | No session / invalid session | Dashboard returns 401; no data leaked |
| UI-02 | Zero or multiple memberships | Dashboard denies ambiguous tenant context |
| UI-03 | Zero or multiple active store connections | Dashboard denies ambiguous store context |
| UI-04 | Metrics | Tenant-scoped summary and activity only |
| REV-01 | Unconfirmed attribution | Excluded from recovered revenue |
| REV-02 | Confirmed order attribution | One ledger entry per eligible order, with correct currency/value |
| REV-03 | Refund/cancellation | Revenue ledger reversal/adjustment idempotent |
| REV-04 | Attribution confidence promotion | A prior PROBABLE ledger row is promoted in place to billable CONFIRMED after exact tracked-click evidence; no duplicate row and no downgrade on later weaker evidence |
| REV-05 | Net recovered revenue | Confirmed refund/cancellation adjustment rows reduce dashboard totals, event breakdowns, activity amounts and daily revenue series; negative daily net values remain visible |
| REV-06 | Shopify order edits | `current_total_price` wins over stale `total_price`; downward edits create only the incremental negative adjustment, reconcile with existing refunds, replay idempotently and never increase attributed value above the original recovery |
| BILL-01 | Fee measurement | Calculated only from confirmed recovered revenue |
| BILL-02 | Billing period/charge | No charge until a verified measurement and explicit billing policy |
| BILL-03 | Uninstall/cancel | Sending and billing entitlements stop; retained records follow documented policy |
| BILL-04 | Refund fee credit | Negative confirmed adjustment fees offset later positive Shopify usage charges exactly once; partial credits reduce charges, full credits void them, and retries preserve the original net amount |
| BILL-05 | Adjustment fee measurement | A negative fee measurement is created only when the original confirmed recovery has a positive measured fee; unmeasured recoveries cannot generate future credits |
| BILL-06 | No-send billing acceptance | Measure fees from confirmed ledger rows only; do not create a `billing_usage_charges` row or invoke `appUsageRecordCreate`; verify the billing worker default-deny flag and outbound network deny for MailerSend and Shopify Admin GraphQL |

## Privacy, retention and operations
| ID | Test | Expected evidence |
|---|---|---|
| PRIV-01 | Shopify customer data request | Correct tenant/store scope; export evidence |
| PRIV-02 | Erasure request | Identity-bearing data redacted/deleted per policy; non-identifying financial records retained only where lawful |
| PRIV-03 | Retention expiry | Purge job runs and evidence captured |
| PRIV-04 | n8n execution retention | Instance-level retention/pruning settings inspected; customer/message payload retention proven |
| PRIV-05 | Error logs | No tokens, credentials, full email bodies or unnecessary customer data |
| OPS-01 | Rollback | Exact rollback plan and restore evidence |
| OPS-02 | Monitoring | Alerts for provider errors, stuck jobs, webhook failures, token refresh failures and unexpected send attempts |

## Current live evidence gaps
- Production has no global provider-send interlock yet; candidate migration is in PR #7 only.
- The manual one-off test route historically reached MailerSend and a provider event confirmed delivery. Tenant-level recovery flags being false are not a global stop.
- No isolated Supabase staging project has been independently verified in the connected project inventory.
- n8n execution retention/pruning settings are not exposed by the connected n8n tools and remain unverified.
- Latest webhook-ingest and delivery workflow executions in the inspected history are dated 2026-11-14; no fresh end-to-end staging webhook-to-ledger proof exists.
- The Shopify Pixel V2 inbox migration is not applied to production; the live pixel proxy still uses the existing legacy RPC.
- Current billing snapshot has no billing periods, usage charges, measurements, confirmed attributions or confirmed recovery ledger rows.

**Release decision:** NO-GO until every required row has evidence from isolated staging and the exact reviewed candidate commit. A green scheduler execution, static CI pass, or successful historical one-off test is not whole-system acceptance.
