# HENVALT live n8n runtime audit — 17 November 2026

Read-only inspection only. No workflow, credential, execution or setting was changed.

## Active workflows

| Workflow | ID | Active nodes | State |
|---|---|---:|---|
| HENVALT_INGEST | VTpfGKNtu1CSQ4Rv | 51 | Active |
| HENVALT_RECOVERY | 3GEDoeCA4paXTaDF | 46 | Active |
| HENVALT_DELIVERY | CvVyybGJZSnklxiZ | 62 | Active |

The architecture remains exactly three workflows.

## Recent execution evidence

Window inspected: 14 November 2026 onward.

- Ingest: 15 executions, all successful; latest observed 14 November.
- Recovery: 4,586 executions in the queried window; latest 100 returned were successful. The workflow is scheduled approximately every minute.
- Delivery: 10 executions, 9 successful and 1 failed.

A sampled recovery execution on 17 November invoked browse, cart, checkout and deferred-payment discovery nodes. Its intervention loop had no work item to process. A successful scheduled run means the worker tick completed, not that a shopper email was sent.

## Delivery error isolated

Failed execution: manual execution 31256 on 14 November 2026.

Failing node: Record One-Off Test Result  
Operation: HTTP POST to the existing record_delivery_result RPC.  
Failure: Response body is not valid JSON. Change Response Format to Text.

The HTTP Request node expected JSON while the RPC response body was not valid JSON for that request. The observed error occurred in the one-off test-send result path. It is not evidence that the normal delivery node failed.

A later webhook execution 31277 completed successfully. Workflow success alone does not prove a provider accepted or delivered a customer email.

## Safe remediation

- Change the one-off result node's response format to Text in a separately approved n8n edit.
- Test the one-off path with an explicitly authorized test recipient and confirm the database delivery result.
- Verify the ordinary delivery path separately using provider response ID and subsequent provider event.
- Keep execution logs free of recipient email, message body, route tokens and credentials.
- Do not feed V2 candidates into legacy n8n until exact-store opportunity, consent and delivery authorization are complete.

## V2 integration boundary

The existing active workflows still use the legacy tenant-scoped pipeline. V2 verified inbox, checkout/order projections and recovery candidate queue exist only on the GitHub preparation branch and disposable CI database. They are not live and are not connected to n8n.
