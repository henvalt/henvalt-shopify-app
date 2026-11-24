# Integrated staging execution plan — 24 November 2026

**Status: PREPARATION / NOT STAGING-EXECUTED / NO-GO.**  
**Candidate base:** `56358cfd922b343240231614af44a40aaea527c8`  
**Work branch:** `work/integrated-staging-no-send-2026-11-24`

This plan closes the gap between individually passing PostgreSQL/Node/Deno checks and a real integrated environment. It does not claim that disposable PostgreSQL is equivalent to Supabase staging.

## Hard safety boundary

- Never point a candidate workflow, Edge Function, Shopify app, or test harness at production.
- Do not create a paid Supabase project or other billable resource as part of this preparation.
- No production SQL, migration, Edge Function/Worker deployment, n8n workflow mutation, Shopify release, provider credential claim, email, or charge.
- Candidate delivery remains no-send. The provider boundary must be a network-denied stub, not merely a fake HTTP response in a live workflow.
- A missing staging resource or missing proof is a failed gate, not an assumed pass.

## Twenty-batch execution ledger

| Batch | Engineering work | Required evidence | State |
|---:|---|---|---|
| 01 | Pin candidate commit and PR lineage | exact SHA and branch recorded | DONE |
| 02 | Reconfirm active workflow identity | sanitized 2026-11-24 recovery snapshot | DONE |
| 03 | Preserve three-workflow topology | no fourth workflow; candidate IDs isolated | STATIC |
| 04 | Verify retry enqueue tenant binding | tenant + intervention + source job | STATIC |
| 05 | Verify source worker lease fencing | claimed status, worker ID, unexpired lease | STATIC |
| 06 | Verify expected request/attempt binding | stale request and attempt rejected | STATIC |
| 07 | Verify generation monotonicity | only current generation can resume | STATIC |
| 08 | Verify retry eligibility evidence | exact pre-provider marker + RELEASED reservation | STATIC |
| 09 | Verify ambiguous provider outcomes | no retry after uncertain egress/acceptance | STATIC |
| 10 | Verify bounded retries | generations 1–3; terminal dead-letter | STATIC |
| 11 | Verify immutable content envelope | same message, recipient and tracking token | STATIC |
| 12 | Verify recovery routing | retry job uses existing recovery worker | STATIC |
| 13 | Verify delivery lease propagation | job, worker and generation reach final gate | STATIC |
| 14 | Verify quota reservation behavior | released reservation is not double-consumed | CI |
| 15 | Verify lifecycle lock ordering | intervention → request → reservation/job | CI |
| 16 | Verify retry-wins race | late acceptance cannot overwrite newer generation | CI |
| 17 | Verify late-acceptance-wins race | no retry after provider acceptance wins | CI |
| 18 | Verify egress/late-acceptance race | final provider boundary is fenced | CI |
| 19 | Build isolated staging inventory and runbook | distinct Supabase, n8n, Shopify and provider identities | BLOCKED |
| 20 | Execute full integrated lifecycle | persisted state + zero provider egress + evidence bundle | BLOCKED |

**Interpretation:** DONE/STATIC/CI are repository-level preparation evidence. They are not staging acceptance. Batches 19–20 require a genuinely isolated environment and cannot be marked complete by source assertions.

## Integrated execution sequence

1. Establish a distinct Supabase staging project/branch and prove its project reference differs from production `ocyplckdojdubyrsxcxa`. If no free isolated environment is available, stop here; do not create a paid resource.
2. Record the exact candidate commit and ordered migration checksums. Apply migrations only to that isolated database, using a disposable snapshot of the required schema and synthetic tenant/customer/message records.
3. Deploy candidate Edge Functions only to the isolated project. Replace every external endpoint with an allowlisted staging endpoint. Do not copy production secrets or provider tokens.
4. Import the sanitized INGEST, RECOVERY and DELIVERY candidates into a separate n8n instance/workspace. Verify distinct workflow IDs, inactive state, no credential objects, no production URLs and no live provider nodes.
5. Enforce outbound network denial at the staging runtime/container boundary. A fake response node alone is insufficient evidence that an alternate route cannot reach MailerSend.
6. Run one synthetic checkout through durable ingest, recovery eligibility, intervention creation, delivery generation 1, pre-provider failure, quota release, retry job enqueue, generation 2 claim and completion.
7. Inject a worker crash after claim; prove lease expiry and reclaim do not permit the stale worker to enqueue or deliver.
8. Inject crash after generation creation but before source-job completion; prove idempotent retry command mapping returns the same retry job and does not create generation 3 accidentally.
9. Inject delayed provider acceptance and run both race orderings: retry wins first; late acceptance wins first. Also test acceptance after egress has begun.
10. Cancel billing / revoke delivery entitlement between queue and claim, between claim and authorization, and between authorization and final egress. Every later boundary must deny safely; no new credential may be released.
11. Assert tenant A cannot read, claim, load, retry, settle or complete tenant B's job, request, attempt, reservation or provider event.
12. Reconcile all durable records: source job, retry command, retry mapping, retry job, request generation, attempt, reservation event, provider event and intervention terminal state.
13. Export an evidence bundle containing exact IDs, state transitions, SQLSTATEs, timestamps, workflow versions, Edge Function versions, outbound network-denial logs and test results. Use synthetic identifiers only.

## Required stop conditions

- Any staging endpoint resolves to production.
- Any workflow is active before the no-send tests pass.
- Any provider credential is available to the runtime.
- Any test causes a real external provider request.
- A stale worker can mutate a newer generation.
- A delayed acceptance can create a second deliverable request.
- A cancelled tenant can cross the final egress boundary.
- Tenant mismatch, missing lease, malformed generation or missing billing state fails open.
- Any expected database transition is missing or duplicated.

## Acceptance decision

The new static regression test `tests/integrated-staging-readiness.test.mjs` checks that the repository's staging contract remains tied to the exact three-workflow topology and existing retry/race/reservation acceptance artifacts. It is deliberately not a claim that staging has run.

The final gate is **NO-GO** until batches 19 and 20 have real environment evidence. The current connected production project has no verified isolated development branch, so this branch must not attempt to substitute production for staging.
