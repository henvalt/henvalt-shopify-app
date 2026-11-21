# Production no-send interlock audit — 2026-11-21

## Scope and safety

Read-only inspection of the live Supabase project and the published n8n delivery workflow. No production rows, functions, secrets, workflow definitions, or provider settings were changed. No provider request or email was sent.

This document is a release blocker record and implementation contract, not authorization to deploy.

## Verified live findings

1. The published `HENVALT_DELIVERY` workflow is active (workflow ID `CvVyybGJZSnklxiZ`, active version `621ae6ce-a006-4fed-a70e-acf774c360fb`).
2. It has two distinct outbound provider call nodes:
   - `MailerSend Send` on the ordinary internal-delivery webhook path.
   - `MailerSend One-Off Test Email` on the manual-trigger path.
   Both call the `henvalt-mailersend-delivery` Edge Function.
3. The live `henvalt.get_mailersend_token_for_delivery(uuid, uuid)` SECURITY DEFINER function claims an eligible delivery and returns the MailerSend token. Its authorization predicate includes a hard-coded one-off exception tied to a single tenant, opportunity, recipient, idempotency key, and test-only message metadata.
4. That hard-coded exception is a special-case authorization bypass, not a global no-send interlock. The function has no global release/kill-switch predicate.
5. Live `henvalt.provider_configs` contains 2 rows, both active. This count is metadata only; no credential values were read.
6. Live `henvalt.delivery_requests` currently contains 2 ACCEPTED and 1 DELIVERED rows (from the read-only status aggregation). These are historical states, not evidence of a current send in progress.
7. No verified global no-send control was found in the live database function or published workflow graph.

## Required interlock contract

The global stop must be enforced at the final credential-release boundary, not merely in the dashboard, n8n routing, or Edge Function UI.

- Default state is **NO SEND** when the control is absent, malformed, or unreadable.
- The credential-release RPC must check the global release state before claiming a delivery or reading a provider secret.
- Every exception path, including the legacy one-off test exception, must remain subordinate to the global stop.
- The Edge Function must fail closed if the RPC denies release or returns an unexpected shape.
- Both n8n outbound nodes must remain unable to send when the interlock is closed; manual execution is not an exemption.
- Opening the interlock requires an explicit release decision and a separately tested policy; it must not be the default.
- The stop must be independently verifiable using a non-secret read-only status surface and a controlled denial test that cannot reach the provider.

## Candidate implementation and acceptance requirements

1. Design a single authoritative global send-control record with a fail-closed default. Avoid a second, divergent control in n8n.
2. Amend the credential-release function so the control is checked before the delivery claim and before any Vault secret read. Remove the hard-coded one-off authorization exception; do not replace it with another recipient-specific exception.
3. Add PostgreSQL acceptance tests for:
   - control row absent => denied;
   - control disabled => denied;
   - control malformed/unreadable => denied;
   - ordinary eligible delivery with control disabled => denied and no provider credential returned;
   - legacy one-off delivery with control disabled => denied and no provider credential returned;
   - enabled state still requires every existing tenant, consent, suppression, opportunity, verified-domain, idempotency, and delivery-claim check;
   - non-service roles cannot read or mutate the control;
   - function execution grants remain least-privilege.
4. Add an Edge Function acceptance test proving denied authorization cannot call MailerSend.
5. Add a workflow graph test proving every provider-send node is downstream of the same authorization boundary and no manual route bypasses it.
6. Independently inspect the published workflow version after any approved cutover; a draft-only change is not sufficient.

## Release decision

**BLOCKED — do not enable sending.** The current production credential-release boundary has no global no-send interlock and contains a hard-coded one-off exception. Do not apply candidate migrations, deploy Edge Functions, publish n8n changes, or enable any send path until the interlock is implemented, independently tested, and explicitly approved.
