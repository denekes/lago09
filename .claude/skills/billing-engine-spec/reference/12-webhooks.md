# 12 — Webhooks (BE-WH)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies outbound webhooks: endpoints and their event-type filter, the
event catalogue, the payload envelope, the exact body bytes, the two signature schemes, delivery, retries and
back-off, and the quirks a receiver must know. Which business operation emits which event is listed in the catalogue
(section 3) and specified in the owning chapter; the REST endpoints that manage webhook endpoints are in chapter 11.

Reading guide: rules are numbered `BE-WH-n`; every rule line ends with `[vec: …]` naming the vectors that pin it
(file `billing-engine-spec/vectors/webhooks.jsonl`) or a prose-only marker with the reason. Op schemas:
`reimplementation-kit/schemas/ops/webhooks.*.schema.json`. Vectors tagged `test-key` carry the kit's **test-only**
RSA private key (PEM in the vector input); it exists only to make RS256 signatures reproducible and must never be
used outside conformance runs.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Endpoints and filters

- **BE-WH-1** An organization has at most 10 webhook endpoints; creating an 11th fails validation with `error_details` `{"base":["Maximum number of webhook endpoints was reached"]}` (a sentence, not a code). [vec: none (prose only: endpoint CRUD is outside the unit tier; observed through the oracle while authoring)]
- **BE-WH-2** `webhook_url` is required, must parse as an `http` or `https` URL with a host (`url_is_invalid`) and is unique within the organization (`value_already_exist`); `name` is optional. [vec: none (prose only: as BE-WH-1)]
- **BE-WH-3** `signature_algo` is `jwt` (default when absent) or `hmac`; an update without `signature_algo` keeps the current one. [vec: none (prose only: endpoint settings have no unit op; the default was observed through the reference and the keep-on-update read at the pin, see Provenance; what each algorithm sends is pinned under BE-WH-13 to BE-WH-15)]
- **BE-WH-4** `event_types` normalisation on create and update: a non-empty array has each element turned into text, trimmed and lower-cased; null and blank elements are dropped; duplicates are removed keeping the first occurrence; if the result is exactly `["*"]` it is stored as **null**. Null (or absent) means "no filter"; an array that is empty — given empty or emptied by normalisation — is stored as `[]` (RBD-90). [vec: webhooks.normalize_event_types.001, webhooks.normalize_event_types.002, webhooks.normalize_event_types.006, webhooks.normalize_event_types.007, webhooks.normalize_event_types.011]
- **BE-WH-5** Non-array values, then validation: a string value is first parsed as a PostgreSQL array literal: when that yields at least one element (`"{customer.created}"`, `"{a,b}"`) the list is normalised and validated as an array, when it yields none (`""`, `"wrong"`, `"{}"`) → `{"event_types":["must_be_array"]}`; a JSON number or boolean is an unhandled failure (HTTP 500) at the pin; any element that is not one of the configured event names (section 3) → `{"event_types":["contains invalid types: [\"a\", \"b\"]"]}` listing the offending normalised elements in that bracketed, quoted, comma-and-space separated form. `"*"` next to other names is therefore invalid. [vec: webhooks.normalize_event_types.003, webhooks.normalize_event_types.004, webhooks.normalize_event_types.005, webhooks.normalize_event_types.012, webhooks.normalize_event_types.013]
- **BE-WH-6** Delivery filter at emission time: an endpoint with a null filter receives every webhook; with `[]` none; otherwise exactly the webhooks whose emitted `webhook_type` string is an element of its list. [vec: webhooks.endpoint_receives.*]
- **BE-WH-7** Configured names (accepted in filters) and emitted `webhook_type` strings are the same for every event except the refund failure: it is configured as `credit_note.provider_refund_failure` but emitted as `credit_note.refund_failure`, which is not a valid filter value; an endpoint with an explicit filter can never receive it, only unfiltered endpoints do (RBD-83; corrected proposal: emit the configured name). [vec: webhooks.type_info.001, webhooks.type_info.001x, webhooks.endpoint_receives.005]

## 2. Emission

- **BE-WH-8** An emission is requested with an event name and the object it is about. If the organization has no endpoint nothing is recorded. An emission is requested only after the database transaction that wrote its object has committed (the request is deferred to the commit or placed after the transaction), so a change that is rolled back never emits (RBD-85). [vec: none (prose only: commit timing is not observable through a unit op)]
- **BE-WH-9** Payload envelope, keys in exactly this order: `{"webhook_type": <emitted type>, "object_type": <object type>, "organization_id": <organization id>, <object type>: <serialized object>}` — the object sits under the key named by `object_type`, which is not always the event's resource name (section 3). [vec: webhooks.payload_envelope.001, webhooks.payload_envelope.002]
- **BE-WH-10** The object is serialised once, when the emission is processed, and the body POSTed is that stored payload (the envelope of BE-WH-9 around it). [vec: webhooks.payload_envelope.001]
- **BE-WH-27** Delivery bookkeeping: one delivery row per receiving endpoint is created (status `pending`, retries 0, the endpoint URL recorded as a snapshot) and the same stored payload is used for that endpoint's every attempt — a later change of the object never changes a pending webhook. [vec: none (prose only: delivery rows have no unit op; read at the pin and covered by the reference's green delivery specs, see Provenance)]
- **BE-WH-11** Catalogue lookup: the configured event names are exactly the 75 names of section 3 (40 in scope, section 3.1; 35 at the chapter 14 boundary, section 3.2). Every configured name is emittable and every emittable name is configured (an emission is requested under its configured name; only `credit_note.provider_refund_failure` is then sent under another `webhook_type`, BE-WH-7); for each, the emitted type and the payload's object key are those of its table row. The object key is the part of the name before the first dot unless the row names another one (16 names do, for example `alert.triggered` → `triggered_alert`, `integration.provider_error` → `provider_error`). Any other name is unknown: it is not emittable and not a valid filter value (BE-WH-5). [vec: webhooks.type_info.*]

## 3. Catalogue (all configured events)

The configured list has exactly 75 names: the 40 of section 3.1 and the 35 of section 3.2. Only `event.error` is
marked deprecated in it. No in-scope behaviour depends on the order of the list.

### 3.1 In-scope events

Columns: configured name (= emitted `webhook_type` unless noted) → `object_type` key → emitted when (owning chapter).

| Event | object_type | Emitted when |
|---|---|---|
| `billable_metric.created` / `.updated` / `.deleted` | `billable_metric` | metric created / updated / deleted (05) |
| `plan.created` / `plan.updated` | `plan` (with charges, usage thresholds, taxes, minimum commitment) | plan created / updated (05) |
| `plan.deleted` | `plan` | deletion requested (before the asynchronous removal) |
| `customer.created` / `customer.updated` | `customer` | upsert created / updated the customer (11) |
| `subscription.started` | `subscription` (with plan and customer) | activation (06) |
| `subscription.updated` | `subscription` | update, downgrade scheduling, the previous subscription when its pending successor is canceled (06) |
| `subscription.terminated` | `subscription` | termination, including the cancellation of a pending subscription and the replacement on upgrade (06, RBD-66) |
| `subscription.canceled` / `subscription.incomplete` | `subscription` | activation-rule outcome (chapter 14 boundary) |
| `subscription.trial_ended` | `subscription` | trial end billing (06) |
| `subscription.termination_alert` | `subscription` | 15 / 45 days before `ending_at` (13, BE-CK-6) |
| `subscription.usage_threshold_reached` | `subscription` (with the reached threshold) | progressive-billing threshold crossed (10) |
| `invoice.drafted` | `invoice` (with customer, subscriptions, billing periods, fees, credits, applied taxes) | subscription invoice created in a grace period (07) |
| `invoice.created` | `invoice` | invoice finalized (periodic without grace period, draft finalized, pay-in-advance, progressive-billing, advance-charges invoices) (07) |
| `invoice.one_off_created` | `invoice` | one-off invoice created (07) |
| `invoice.paid_credit_added` | `invoice` | wallet paid top-up invoice (09) |
| `invoice.ready_to_finalize` | `invoice` | draft whose taxes are resolved (07) |
| `invoice.voided` / `invoice.deleted` | `invoice` | void / draft deletion (07) |
| `invoice.payment_status_updated` | `invoice` | payment status changed through the API (07) |
| `invoice.payment_overdue` | `invoice` | overdue job (13) |
| `invoice.payment_dispute_lost` | `payment_dispute_lost` | dispute lost (chapter 14 boundary) |
| `invoice.generated` / `credit_note.generated` | `invoice` / `credit_note` | document generated (chapter 14 boundary) |
| `fee.created` | `fee` | each pay-in-advance fee and non-invoiceable fee (05) |
| `credit_note.created` | `credit_note` (with items, applied taxes) | credit note created or finalized with its draft invoice (08) |
| `credit_note.provider_refund_failure` (emitted `credit_note.refund_failure`) | `credit_note_payment_provider_refund_error` | provider refund failed (chapter 14 boundary; BE-WH-7) |
| `wallet.created` / `.updated` / `.terminated` | `wallet` (with recurring rules) | wallet created / updated or balance changed / terminated (09) |
| `wallet.depleted_ongoing_balance` | `wallet` | ongoing balance reached ≤ 0 (09) |
| `wallet_transaction.created` / `.updated` | `wallet_transaction` | transaction created / settled or failed (09) |
| `alert.triggered` | `triggered_alert` | usage alert crossed (10) |
| `events.errors` | `events_errors` | hourly event post-validation (02) |
| `event.error` (deprecated) | `event_error` | event post-processing error (02) |

### 3.2 Boundary events (chapter 14)

These names are configured (valid filter values, BE-WH-5) and emitted by features outside the kit; a rebuild that
does not implement those features never emits them but must still accept them in filters. Every name is emitted
unchanged.

| Event | object_type | Boundary (chapter 14) |
|---|---|---|
| `customer.accounting_provider_created` / `customer.crm_provider_created` / `customer.payment_provider_created` | `customer` | integrations, payment providers (BE-IF-1, BE-IF-5) |
| `customer.accounting_provider_error` | `accounting_provider_customer_error` | integrations (BE-IF-5) |
| `customer.crm_provider_error` | `crm_provider_customer_error` | integrations (BE-IF-5) |
| `customer.payment_provider_error` | `payment_provider_customer_error` | payment providers (BE-IF-1) |
| `customer.checkout_url_generated` | `payment_provider_customer_checkout_url` | payment providers (BE-IF-1) |
| `customer.tax_provider_error` | `tax_provider_customer_error` | tax providers (BE-IF-3) |
| `customer.vies_check` | `customer` | VAT-number checks (BE-IF-4) |
| `fee.tax_provider_error` | `tax_provider_fee_error` | tax providers (BE-IF-3) |
| `integration.provider_error` | `provider_error` | integrations (BE-IF-5) |
| `invoice.payment_failure` | `payment_provider_invoice_payment_error` | payment providers (BE-IF-1) |
| `invoice.resynced` | `invoice` | integrations (BE-IF-5) |
| `payment.succeeded` / `payment.requires_action` | `payment` | payment providers (BE-IF-1) |
| `payment_provider.error` | `payment_provider_error` | payment providers (BE-IF-1) |
| `payment_receipt.created` / `payment_receipt.generated` | `payment_receipt` | payment providers, documents (BE-IF-1, BE-IF-6) |
| `payment_request.created` / `payment_request.payment_status_updated` | `payment_request` | dunning (BE-IF-8) |
| `payment_request.payment_failure` | `payment_provider_payment_request_payment_error` | dunning, payment providers (BE-IF-1, BE-IF-8) |
| `wallet_transaction.payment_failure` | `payment_provider_wallet_transaction_payment_error` | payment providers (BE-IF-1) |
| `dunning_campaign.finished` | `dunning_campaign` | dunning (BE-IF-8) |
| `feature.created` / `feature.updated` / `feature.deleted` | `feature` | entitlements (BE-IF-9) |
| `quote.created` / `quote.approved` / `quote.voided` | `quote` | product catalogue (BE-IF-9) |
| `order.created` / `order.executed` | `order` | product catalogue (BE-IF-9) |
| `order_form.created` / `order_form.signed` / `order_form.expired` / `order_form.voided` | `order_form` | product catalogue (BE-IF-9) |

## 4. Body bytes

- **BE-WH-12** The POSTed body is the compact JSON encoding of the stored payload (keys in stored order, no whitespace), with the exact rules listed below. [vec: webhooks.encode.*]
  - strings: `"` and `\` escaped as `\"` `\\`; U+0008, U+000C, U+000A, U+000D, U+0009 as `\b` `\f` `\n` `\r` `\t`; every other character below U+0020 as `\u00XX` (lower-case hex); `<` `>` `&` as `\u003c` `\u003e` `\u0026`; U+2028 and U+2029 as `\u2028` `\u2029`; everything else raw UTF-8 (U+007F, non-ASCII, emoji); `/` is not escaped;
  - integers in decimal, exactly (no binary64 rounding);
  - binary floating-point numbers: take the shortest decimal digit string D (n digits) that round-trips, with value D × 10^K and E = K + n − 1. If K ≥ 0 and |E| < 15: D followed by K zeros and `.0` (`20.0`, `100000000000000.0`). Else if K < 0 and (K > −7 or |E| < 10): plain decimal notation with a leading `0.` when below 1 (`1.1`, `123456789012345.6`, `0.000000001`). Otherwise scientific: first digit, then `.` and the remaining digits when n > 1, then `e`, the sign `+` or `-`, and |E| without padding (`1e+15`, `1.234567890123456e+15`, `1e-10`, `5e-324`). Negative zero is `-0.0`;
  - `true`, `false`, `null`, `[]`, `{}` as such.

Values arrive in the payload already serialised by the object's representation (chapter 11 field catalogue): money in
minor units is an integer, exact decimals are strings, rates are numbers, instants are strings. A receiver that
re-serialises a parsed body will generally not reproduce these bytes; signatures are over the bytes as received.

## 5. Signatures and headers

- **BE-WH-13** Each delivery POSTs the body with the headers `Content-Type: application/json`, `X-Lago-Signature`, `X-Lago-Signature-Algorithm` (`jwt` or `hmac`, the endpoint's setting) and `X-Lago-Unique-Key` (the delivery row id: the same for every attempt of that delivery, different for each endpoint receiving the same event). [vec: webhooks.sign.001, webhooks.sign.003]
- **BE-WH-14** HMAC: `X-Lago-Signature = Base64(HMAC-SHA256(key, body))` with the standard Base64 alphabet, padding, no line breaks; the key is the organization's HMAC key (a random UUID text generated when the organization is created, used as its UTF-8 bytes); the message is the exact body bytes. [vec: webhooks.sign.001, webhooks.sign.002]
- **BE-WH-15** JWT: `X-Lago-Signature` is a compact JWS: protected header exactly `{"alg":"RS256"}` (no `typ`); claims `{"data": <the body as a JSON string>, "iss": <issuer>}` with keys in this order, encoded as compact JSON where only `"`, `\` and characters below U+0020 are escaped (the body's own `\u003c` text becomes `\\u003c`; non-ASCII and `/` stay raw); each part base64url without padding; signature RSASSA-PKCS1-v1_5 with SHA-256 over `header.claims` (deterministic for a given key). The issuer is the API's public base URL (deployment setting). [vec: webhooks.sign.003, webhooks.sign.004]
- **BE-WH-16** One RSA key pair signs the webhooks of every organization of an installation (RBD-93); the installation refuses to start without a private key. Its public key is published by two endpoints: `GET /api/v1/webhooks/public_key` answers `text/plain` with the MIME Base64 encoding (60-character lines, each ending with a line feed, the last one too) of the PEM public key (SubjectPublicKeyInfo, `-----BEGIN PUBLIC KEY-----`, 64-character lines, final newline); `GET /api/v1/webhooks/json_public_key` answers `{"webhook":{"public_key":"<the same text>"}}`. [vec: webhooks.public_key.001]
- **BE-WH-17** Receiver verification recipe: read the raw body bytes; for `hmac` compare (constant time) `Base64(HMAC-SHA256(hmac_key, raw))` with the header; for `jwt` fetch the public key once (decode the Base64 text, load the PEM), verify the RS256 token and its `iss`, then require `claims.data` to equal the raw body text; de-duplicate deliveries on `X-Lago-Unique-Key`. [vec: none (prose only: receiver-side guidance; the signing side is pinned by webhooks.sign.*)]

## 6. Delivery, retries, back-off

- **BE-WH-18** Each attempt POSTs to the endpoint's **current** URL (an edited URL applies to pending retries), with open, read and write timeouts of 30 s (deployment setting) and no redirect following and no retry inside the attempt. Deleting an endpoint deletes its delivery rows, so its pending retries die. [vec: webhooks.retry_step.004, webhooks.retry_step.011]
- **BE-WH-19** Success iff the response status is 200, 201, 202 or 204 (any other status, including 203 and every 3xx, is a failure). On success the row becomes `succeeded` with the status and response body (or `{}` when empty) recorded; the retry counter is unchanged. [vec: webhooks.retry_step.001, webhooks.retry_step.002, webhooks.retry_step.003, webhooks.retry_step.004]
- **BE-WH-20** On failure (non-success status, timeout, refused, reset or dropped connection, TLS, DNS or unreachable-host error): the status (if any, otherwise left as it was) and the response body or error message are recorded, `retries` is incremented, `last_retried_at` set, and the row becomes `retrying` when `retries_before + 1 < attempts` (attempts = 3 by default, deployment setting) and a new attempt is scheduled, otherwise `failed` with no further attempt. With the default: attempt 1 → retrying; attempt 2 → retrying; attempt 3 → failed (`retries = 3`). An attempt on a row already failed (manual retry) fails again without scheduling. [vec: webhooks.retry_step.003, webhooks.retry_step.005, webhooks.retry_step.006, webhooks.retry_step.007, webhooks.retry_step.010, webhooks.retry_step.011]
- **BE-WH-21** Back-off: the next attempt waits `(r⁴ + ((u × r⁴) × 0.15)) + 2` seconds (binary floating point, in that order; `r⁴` is an integer) where `r` is the retry counter after the increment and `u` is uniform in [0, 1); the delay is random, so the kit grades only its bounds, as exact decimals `r⁴ + 2` and `1.15 × r⁴ + 2`: r = 1 → [3, 3.15), r = 2 → [18, 20.4), r = 3 → [83, 95.15), r = 4 → [258, 296.4) (RBD-91). [vec: webhooks.retry_step.005, webhooks.retry_step.006]
- **BE-WH-22** Row statuses: `pending` → `succeeded` | `retrying` → … → `succeeded` | `failed`. A manual retry (administration surface, chapter 14) re-attempts any row except a succeeded one. A failure of the payload storage itself (throttling) is not counted as a delivery failure: the attempt is retried by the job system without incrementing `retries`. [vec: none (prose only: administration surface and storage faults are outside the unit tier)]
- **BE-WH-23** Delivery rows are cleaned up by a daily clock job at 01:00 UTC (chapter 13 BE-CK-3). [vec: clock.jobs_due.004]
- **BE-WH-28** The clean-up deletes, in batches of 1,000, the delivery rows whose last update is more than 90 days old; the stored payload and response blobs are left to the object store's own expiry policy. [vec: none (prose only: retention has no unit op; pinned by the reference's green clean-up job spec, see Provenance)]
- **BE-WH-24** Ordering is not guaranteed: deliveries are independent jobs and retries are delayed, so a receiver may see `invoice.created` before the `fee.created` of the same billing run, or an update before a creation; receivers must be idempotent on `X-Lago-Unique-Key` and order by the object's own timestamps. [vec: none (prose only: concurrency property)]

## 7. Payload quirks a receiver must know

- **BE-WH-25** The `events.errors` webhook carries its report under the object key `events_errors`. [vec: webhooks.type_info.003]
- **BE-WH-29** The `events_errors` object is `{"invalid_code": [transaction ids], "missing_aggregation_property": [...], "missing_group_key": null, "invalid_filter_values": [...]}` with keys in that order; `missing_group_key` is always null (RBD-92). [vec: none (prose only: the hourly post-validation report has no unit op; read at the pin, see Provenance)]
- **BE-WH-26** Cross-chapter quirks: terminating a pending subscription cancels it yet emits `subscription.terminated`, and terminating again re-sends it (RBD-66, chapter 06); five instants have millisecond precision (wallet `terminated_at`, subscription `started_at`, event `timestamp`, invoice `payment_dispute_lost_at`, lifetime-usage `reached_at`) and fee `from_date` / `to_date` end in `+00:00`, while other instants have whole seconds and `Z` (RBD-87, chapter 11 BE-API-12); zero-amount invoices that end `closed` emit nothing (RBD-70, chapter 07). [vec: none (prose only: pinned by the owning chapters' vectors and scenarios)]

## 8. Rebuild decisions touching this chapter

| RBD | Subject | Compat | Corrected | Vectors |
|---|---|---|---|---|
| RBD-83 | refund-failure configured vs emitted name | keep | one name (proposed: the configured one) | webhooks.type_info.001/001x, webhooks.endpoint_receives.005 |
| RBD-84 | body escaping, key order, signature over exact bytes | keep (MUST) | keep | webhooks.encode.*, webhooks.sign.* |
| RBD-85 | emissions requested after the commit (no defect at the pin) | keep | keep | — |
| RBD-90 | `[]` silences, null / `["*"]` = all, `["*", x]` invalid | keep | keep | webhooks.normalize_event_types.*, webhooks.endpoint_receives.* |
| RBD-91 | 3 attempts, `r⁴ + U[0, 0.15 r⁴) + 2` s, success on 200/201/202/204 | keep | keep | webhooks.retry_step.* |
| RBD-93 | one installation RSA key, claims `{data, iss}`, header without `typ` | keep | keep | webhooks.sign.003, webhooks.sign.004, webhooks.public_key.001 |

## 9. Edge cases (people get these wrong)

- Signing a re-serialised body instead of the exact bytes (webhooks.sign.002, webhooks.encode.001).
- `[]` is not "all events": it silences the endpoint; `["  "]` does too (webhooks.normalize_event_types.006, webhooks.normalize_event_types.007).
- The refund-failure type cannot be filtered (webhooks.endpoint_receives.005).
- 3xx and 203 are failures (webhooks.retry_step.003, webhooks.retry_step.004); the wait uses the counter after the increment (webhooks.retry_step.005).
- Floats: `1e+15` but `100000000000000.0`; `0.000000001` but `1e-10` (webhooks.encode.004).
- The JWT `data` claim is the body as a string, not an object (webhooks.sign.003).
- A string such as `"{customer.created}"` is accepted as a list; a JSON number or boolean crashes the request (webhooks.normalize_event_types.012, webhooks.normalize_event_types.013).
- The payload's object key is not always the name's prefix: `alert.triggered` carries `triggered_alert`, and every provider or integration error has a key of its own (webhooks.type_info.005, webhooks.type_info.007, webhooks.type_info.014); the 35 boundary names of section 3.2 are valid filter values even for a rebuild that never emits them.

## 10. Vectors

| Op | Vectors | Rules |
|---|---|---|
| `webhooks.encode` | webhooks.encode.001-005 | BE-WH-12 |
| `webhooks.payload_envelope` | webhooks.payload_envelope.001-002 | BE-WH-9..11 (BE-WH-27 is prose only) |
| `webhooks.sign` | webhooks.sign.001-004 | BE-WH-13..15 |
| `webhooks.public_key` | webhooks.public_key.001 | BE-WH-16 |
| `webhooks.retry_step` | webhooks.retry_step.001-011 | BE-WH-18..21 |
| `webhooks.normalize_event_types` | webhooks.normalize_event_types.001-013 | BE-WH-4, BE-WH-5, BE-WH-7 |
| `webhooks.endpoint_receives` | webhooks.endpoint_receives.001-005 | BE-WH-6, BE-WH-7 |
| `webhooks.type_info` | webhooks.type_info.001-021 (+001x) | BE-WH-7, BE-WH-11, BE-WH-25 |

## Provenance (maintainers)

Executed 2026-10-02 on the pinned toolchain (Ruby 4.0.6, database `lago_api_test_a9`): the spec set listed in
chapter 11's provenance (1384/1384 green) includes `spec/models/webhook_spec.rb`,
`spec/models/webhook_endpoint_spec.rb`,
`spec/services/webhooks/**`, `spec/jobs/send_webhook_job_spec.rb`, `spec/jobs/send_http_webhook_job_spec.rb`,
`spec/requests/api/v1/webhook_endpoints_controller_spec.rb` and `spec/requests/api/v1/webhooks_controller_spec.rb`.
kitrun of `webhooks.jsonl` against `oracle.sh adapter` → 43/43 compat PASS. Oracle module
`reimplementation-kit/scripts/maintainer/oracle-adapter/ops/webhook.rb`: delivery ops run the real storage round trip
and the real HTTP delivery service against a one-shot local TCP endpoint that records the request bytes; the RS256
vectors swap the installation key for the kit test key; back-off bounds read with randomness pinned to 0 and 1.
Probe of 2026-10-02 (not shipped): the 11th endpoint and the URL/uniqueness messages of BE-WH-1/2 through the
endpoint-creation service.

| Rules | Reference code @591ae90 |
|---|---|
| BE-WH-1..5 | `$API/app/models/webhook_endpoint.rb:3-71`, `$API/config/locales/en/webhook_endpoint.yml:9`, `$API/config/locales/en.yml:55`, `$API/app/services/webhook_endpoints/create_service.rb:14-30`, `$API/app/controllers/api/v1/webhook_endpoints_controller.rb:74-102` |
| BE-WH-6, BE-WH-7, BE-WH-11 | `$API/app/services/webhooks/base_service.rb:41-44`, `$API/app/jobs/send_webhook_job.rb:19-95`, `$API/config/webhook_event_types.yml`, `$API/app/services/webhooks/credit_notes/payment_provider_refund_failure_service.rb:20-26` |
| BE-WH-8..10, BE-WH-27 | `$API/app/jobs/send_webhook_job.rb:104-122`, `$API/app/services/webhooks/base_service.rb:13-73`, `$API/app/models/webhook.rb:38-139`, `$API/app/services/customers/upsert_from_api_service.rb:47-162`, `$API/app/services/credit_notes/create_service.rb:95-98`, `$API/app/services/invoices/refresh_draft_and_finalize_service.rb:44-58`, `$API/app/jobs/application_job.rb:24-28` |
| BE-WH-12 | `$API/app/models/webhook.rb:111-123`, `$API/lib/lago_http_client/lago_http_client/client.rb:54-63`; ActiveSupport 8.0.5.1 JSON escaping and json 2.21.2 float output observed through the oracle |
| BE-WH-13..17 | `$API/app/models/webhook.rb:57-90`, `$API/config/initializers/rsa_keys.rb:3-18`, `$API/app/controllers/api/v1/webhooks_controller.rb:6-18`, `$API/app/models/organization.rb:321-326` |
| BE-WH-18..24, BE-WH-28 | `$API/app/services/webhooks/send_http_service.rb:13-85`, `$API/lib/lago_http_client/lago_http_client/client.rb:9-63`, `$API/app/jobs/send_http_webhook_job.rb:3-23`, `$API/app/services/webhooks/retry_service.rb`, `$API/app/jobs/clock/webhooks_cleanup_job.rb`, `$API/clock.rb:163-167` |
| BE-WH-25, BE-WH-26, BE-WH-29 | `$API/app/serializers/v1/events_validation_errors_serializer.rb:9`, `$API/app/services/subscriptions/terminate_service.rb:20-68`, `$API/app/serializers/v1/wallet_serializer.rb:24` |

Commit-order probe of 2026-10-02 (BE-WH-8, RBD-85; database `lago_api_test_pre`, not shipped): a recorder loaded with
`oracle.sh run -r` noted at every webhook request whether an application transaction was open, over
`$API/spec/services/customers/upsert_from_api_service_spec.rb`, `$API/spec/services/credit_notes/create_service_spec.rb`
and `$API/spec/services/invoices/refresh_draft_and_finalize_service_spec.rb` plus four probe examples (181 examples,
all green). Of 70 customer requests from the upsert and 30 `credit_note.created` requests, one was inside a
transaction, and that transaction was the one the spec matcher `have_enqueued_job_after_commit` wraps around its block;
the positive control (a request inside a transaction) was detected, and a rollback forced inside the upsert stored
nothing and requested nothing. ActiveJob 8.0.5.1 enqueues at once inside a transaction (`enqueue_after_transaction_commit`
defaults to false), so the ordering comes from the call sites. A lexical scan of the request sites under `$API/app`
(85 immediate and 48 deferred-to-commit enqueues) found none inside a transaction block of its own method; callers
that wrap a service in an outer transaction were not audited one by one.

Spec examples behind explicit expectations (all green): `$API/spec/models/webhook_spec.rb:186`,
`$API/spec/models/webhook_spec.rb:206`, `$API/spec/models/webhook_endpoint_spec.rb:122`,
`$API/spec/models/webhook_endpoint_spec.rb:142`, `$API/spec/models/webhook_endpoint_spec.rb:152`,
`$API/spec/services/webhooks/base_service_spec.rb:101`, `$API/spec/services/webhooks/base_service_spec.rb:133`,
`$API/spec/services/webhooks/send_http_service_spec.rb:77`, `$API/spec/services/webhooks/send_http_service_spec.rb:101`,
`$API/spec/services/webhooks/credit_notes/payment_provider_refund_failure_service_spec.rb:14`,
`$API/spec/requests/api/v1/webhooks_controller_spec.rb:13`.

Fix round of 2026-10-02 (database `lago_api_test_fr4`): `webhooks.normalize_event_types.012` (a string holding an
array literal) and `.013` (a JSON number: the reference's own model code raises at
`$API/app/models/webhook_endpoint.rb:61`, which the oracle module now reports as `server_error`) executed through
`oracle.sh adapter` (PASS); an endpoint created over the API without `signature_algo` came back with `jwt`
(integration-session request); keep-on-update read at `$API/app/services/webhook_endpoints/update_service.rb:21`;
BE-WH-27 read at `$API/app/services/webhooks/base_service.rb:13-73`; the 90-day retention is asserted by
`$API/spec/jobs/clock/webhooks_cleanup_job_spec.rb:31` and `:40` (green) with the period at
`$API/app/jobs/clock/webhooks_cleanup_job.rb:7-8`; the report keys of BE-WH-29 at
`$API/app/serializers/v1/events_validation_errors_serializer.rb:6-11`. The rules whose `[vec: …]` tags overstated what
their vectors pin (BE-WH-3, BE-WH-10, BE-WH-23, BE-WH-25) were narrowed and the unpinned parts moved to the prose-only
rules BE-WH-27 to BE-WH-29.

Fix round of 2026-10-05 (database `lago_api_test_fr2g5`, same toolchain): the full configured list was read from
the endpoint model's list of configured names (75, loaded from `$API/config/webhook_event_types.yml`) and the job's
name-to-service map (`$API/app/jobs/send_webhook_job.rb:19-95`, 75 entries, the same names) through a scratch op of
the oracle adapter, with the emitted type and object type of each service; sections 3.1 and 3.2 were checked
against that output name by name (75 of 75, no mismatch). New vectors `webhooks.type_info.005` to `.021` (the 13
remaining names whose object key differs from the prefix, and four of the default rule) executed through
`oracle.sh adapter` (PASS). The back-off order of BE-WH-21 is read at `$API/app/services/webhooks/send_http_service.rb:81-85`;
it cannot be discriminated through the graded bounds.

Independent verification the same day (database `lago_api_test_v2g5`): the 75 names of sections 3.1 and 3.2,
expanded from the tables, were sent through the shipped `webhooks.type_info` op (emitted type, object key and
`configured` as tabled: 75 of 75) together with five unlisted names (`unknown_event_type`: 5 of 5); the configured
list and the job's name-to-service map were compared name by name (75 each, no difference, `event.error` the only
deprecated entry); vectors `webhooks.type_info.005` to `.021` re-ran through `oracle.sh adapter` (PASS).

Update triggers: a pin bump (re-run the oracle over `webhooks.jsonl`), a change of the webhook model, endpoint
model, delivery service, HTTP client or event-type list, a JSON library upgrade (float output), an owner ruling on
RBD-83, a change of where a webhook is requested relative to its transaction (RBD-85).
