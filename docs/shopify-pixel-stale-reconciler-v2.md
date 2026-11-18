# Pixel stale-attempt reconciler V2

Migration 038 adds a bounded service-role RPC for process crashes after a pixel permit has been consumed. It locks up to 500 attempts older than two minutes using `FOR UPDATE SKIP LOCKED` and moves only `AUTHORIZED` attempts to `AMBIGUOUS`. The existing status trigger retains the merchant cost reservation. It never marks a send failed, releases cost, retries delivery, or contacts MailerSend.

The RPC is not scheduled or wired into n8n by this change. The recovery worker can call it during an explicitly approved workflow update; until then, stale attempts remain safe but may require manual reconciliation.
