# Pixel attempt outcome reconciliation V2

Migration 037 tightens the pixel send-attempt state writer. SUBMITTED now requires a non-empty provider message reference; FAILED and AMBIGUOUS cannot carry a provider reference. This prevents a send attempt from being marked as confirmed without a stable provider receipt. Ambiguous outcomes retain their cost reservation and may only reconcile to SUBMITTED or FAILED; they cannot be blindly re-marked ambiguous or retried.
