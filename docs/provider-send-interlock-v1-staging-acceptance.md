# Provider-send interlock V1 — staging acceptance

**Scope:** isolated staging database only. Never run this procedure against production as part of preparation.  
**Expected default:** `provider_sending_enabled = false`.

## Preconditions
- Apply `202611210001_provider_send_interlock_v1.sql` to a disposable staging project.
- Confirm no production migration has been applied.
- Use synthetic tenant/customer/message/provider fixtures and a provider sandbox or a network-denied test double.
- Capture migration checksum, database migration version, and test output.

## Static checks
1. The singleton control row exists with `provider_sending_enabled = false`.
2. The table has RLS enabled and no grants to `anon`, `authenticated`, or `service_role`.
3. `provider_sending_is_enabled()` returns false if the row is absent (test in a disposable transaction/schema fixture).
4. Only the privileged database owner/operator can call `henvalt.set_provider_sending_enabled(boolean, text)`; clients and n8n service-role credentials cannot execute it or update the control tables directly.
5. Every setting change is recorded in `henvalt.provider_send_control_events` with previous/new value, timestamp, database session actor and reason.
5. Trigger `delivery_requests_provider_send_interlock` is enabled on `henvalt.delivery_requests`.

## Negative-path matrix (must all deny while interlock is closed)
| Case | Action | Expected |
|---|---|---|
| Ordinary recovery | authorize a due, otherwise eligible PENDING request | SQLSTATE 42501 / `HENVALT_PROVIDER_SENDING_DISABLED`; no request claim |
| Provider credential RPC | call `get_mailersend_token_for_delivery` for a correctly claimed synthetic request | SQLSTATE 42501; no credential returned |
| Manual one-off test route | execute the one-off test authorization + credential route, including a direct INSERT already in UNKNOWN state | same deny; no credential returned |
| Already-UNKNOWN request | attempt first `provider_claimed_at` stamp | same deny |
| Missing singleton row | evaluate the gate | false; deny |
| Client access | attempt SELECT/UPDATE through authenticated and service_role roles | permission denied |
| n8n retries | repeat ordinary authorization and credential claim | every attempt denied; no duplicate provider attempt |

## Positive-path control test (staging only)
- With a dedicated test operator explicitly enabling the singleton in staging, a synthetic eligible request may pass the guard.
- Use a non-delivering provider stub/network deny. Do not use a real merchant recipient or a live provider credential.
- Turn the control back off and verify the negative matrix again.

## Non-send route regression
Verify these continue to work while sending is disabled:
- Shopify webhook intake and idempotency.
- Shopify privacy requests and redaction.
- Unsubscribe token processing and suppression cascade.
- Tracking link/event handling.
- MailerSend signed event ingestion (does not send).
- Inbound reply ingestion (does not send).

## Concurrency / race checks
- Run two concurrent claims for one synthetic request: at most one claim may succeed when enabled.
- Close the interlock between authorization and credential claim: credential RPC must deny.
- Close the interlock before a repeated/retried delivery: no provider credential may be released.
- A credential already released to an in-flight edge request cannot be recalled by this database gate. Before any live release, also establish a provider-side emergency revocation procedure and test the response.

## Acceptance evidence
Record:
- exact commit SHA and migration checksum;
- staging project identifier (not production);
- trigger/function definitions and ACL snapshots;
- test IDs, timestamps, SQLSTATEs and results;
- proof that no provider request was made;
- non-send regression results;
- provider-side credential revocation owner/procedure.

**Fail closed:** any missing evidence, unexpected credential release, or non-send regression is a NO-GO.
