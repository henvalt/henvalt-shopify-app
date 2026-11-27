-- Cover foreign-key lookups with leading FK columns. Existing composite
-- tenant-scoped indexes do not cover FK checks that probe only the referenced
-- parent key when a parent row is updated or deleted.
create index if not exists billing_measurement_credit_offsets_charge_measurement_fk_idx
  on henvalt.billing_measurement_credit_offsets (charge_measurement_id);

create index if not exists billing_measurement_credit_offsets_credit_measurement_fk_idx
  on henvalt.billing_measurement_credit_offsets (credit_measurement_id);

create index if not exists delivery_generation_incidents_delivery_request_fk_idx
  on henvalt.delivery_generation_incidents (delivery_request_id);

create index if not exists delivery_generation_incidents_intervention_fk_idx
  on henvalt.delivery_generation_incidents (intervention_id);

create index if not exists delivery_retry_commands_intervention_fk_idx
  on henvalt.delivery_retry_commands (intervention_id);

create index if not exists email_usage_reservation_events_reservation_fk_idx
  on henvalt.email_usage_reservation_events (reservation_id);
