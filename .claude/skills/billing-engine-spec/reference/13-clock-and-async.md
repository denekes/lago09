# 13 — Clock and asynchronous work (BE-CK)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies the engine's time-driven work: the clock schedule (which jobs
run when, under which deployment settings), how the hourly design maps onto customer-local days, the selection
condition of each job (pointing to the chapter that owns the effect), the termination-alert job, the asynchronous job
model and the idempotency records that guard a few operations. The test-build clock used by the scenario tier is
specified in `reimplementation-kit/reference/scenario-tier.md` section 6.

Reading guide: rules are numbered `BE-CK-n`; every rule line ends with `[vec: …]` naming the vectors that pin it
(file `billing-engine-spec/vectors/clock.jsonl`) or a prose-only marker with the reason. Op schemas:
`reimplementation-kit/schemas/ops/clock.*.schema.json`. All clock times are UTC wall-clock times of the clock process.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Job model

- **BE-CK-1** Work triggered by the API, by events or by the clock runs as asynchronous jobs on named queues (webhooks, clock, billing, events, wallets, alerts, payments, documents, default, low priority). A failed job is not retried by the queue system; only failures explicitly marked retriable are retried by the job layer (up to 20 attempts, polynomial back-off). Clock jobs are unique while enqueued or running (a second enqueue is dropped; some locks expire after 4 hours), so a slow run is never doubled by the next tick. [vec: none (prose only: queueing and uniqueness are infrastructure properties without a unit-level output)]

## 2. Schedule

- **BE-CK-2** Scheduling semantics: the clock process evaluates its schedule once per second, at its start instant and at every whole second after it (a tick). An **interval job** runs at the first tick and then at the first tick at least one period after its previous run, so its runs are aligned on the process start, not on wall-clock multiples; a period below one second runs it at every tick (BE-CK-12). A **minute-pinned job** runs at a tick whose UTC wall-clock minute (and hour, for a daily job) equals its pin and that is at least one period (one hour, or one day) after its previous run. The tick at which the clock starts counts, and the period is measured from the previous run, not from the pinned minute: a clock started at 00:05:30 runs the :05 jobs at 00:05:30 and next at 01:05:30, not at 01:05:00. A run "counts" only when the job's gate lets it enqueue work. [vec: clock.jobs_due.001, clock.jobs_due.005, clock.jobs_due.006, clock.jobs_due.007, clock.jobs_due.011, clock.jobs_due.012]
- **BE-CK-3** The schedule of the in-scope jobs is the table below (names as reported by `clock.jobs_due`). Out-of-scope jobs of the same clock (API-key last-used persistence at :15, daily usage analytics at :15, dunning at :45, scheduled orders at :45, order-form expiry at :40, inbound provider-webhook retry every 15 min and clean-up at 01:10, dedicated-worker variants) belong to chapter 14. [vec: clock.jobs_due.001, clock.jobs_due.002, clock.jobs_due.004, clock.jobs_due.005]

| Job | When | Effect (owning chapter) |
|---|---|---|
| `activate_subscriptions` | every 5 min | activate pending subscriptions (without predecessor) whose `subscription_at` date has come in the customer's zone (06) |
| `refresh_draft_invoices` | every 5 min | recompute drafts flagged for refresh that still have an active subscription (07) |
| `process_subscription_activity` | every 60 s (setting) | evaluate usage alerts and progressive-billing activity of subscriptions with new usage (10; premium) |
| `refresh_lifetime_usages` | every 300 s (setting) | recompute lifetime usages flagged for recalculation in organizations with progressive billing or lifetime usage (10; premium) |
| `refresh_wallets_ongoing_balance` | every 300 s (setting), gated (BE-CK-4) | recompute ongoing balances of customers flagged for wallet refresh with no tax error (09; premium) |
| `refresh_flagged_subscriptions` | every 10 s, gated (BE-CK-10) | drain the set of subscriptions flagged by the events-processor and refresh their wallets / lifetime usage |
| `retry_failed_invoices` | every 15 min | retry failed invoices whose tax error mentions a provider API limit (14) |
| `terminate_ended_subscriptions` | hourly at :05 | terminate active subscriptions whose `ending_at` falls on today's **customer-local** date (06) |
| `post_validate_events` | hourly at :05, gated | validate last hour's relational-store events of organizations with an endpoint → `events.errors` (02) |
| `bill_customers` | hourly at :10 | per organization, bill subscriptions whose billing day is today in the customer's zone; rotate scheduled downgrades (06, 07) |
| `expire_incomplete_subscriptions` | hourly at :20 | expire incomplete subscriptions whose activation rules timed out (14 boundary) |
| `finalize_invoices` | hourly at :20 | finalize drafts whose expected finalization date (else issuing date) is ≤ the clock's UTC date (07) |
| `mark_invoices_as_payment_overdue` | hourly at :25 | flag finalized, unpaid, undisputed invoices whose due date is before now; `invoice.payment_overdue` (07) |
| `retry_generating_subscription_invoices` | hourly at :30 | re-bill subscription invoices stuck in `generating` for more than one day without a generation error (except pay-in-advance-charge invoices) (07) |
| `terminate_coupons` | hourly at :30 | terminate active coupons past their expiration (07) |
| `bill_ended_trial_subscriptions` | hourly at :35 | bill pay-in-advance plans whose trial ended (06) |
| `terminate_wallets` | hourly at :45 | terminate active wallets whose `expiration_at`, rounded to whole seconds, is ≤ now (09) |
| `termination_alert` | hourly at :50 | BE-CK-6 |
| `terminate_expired_wallet_transaction_rules` | hourly at :50 | terminate active recurring rules whose `expiration_at` ≤ now (09) |
| `top_up_wallet_interval_credits` | hourly at :55 | create due interval top-ups (09) |
| `clean_webhooks` | daily at 01:00 | delete webhook delivery rows not updated for 90 days (12) |

- **BE-CK-4** Deployment gates: the wallet ongoing-balance refresh is scheduled only when a cache backend is configured (memcache servers or a Redis cache URL) and the wallet-refresh switch is not on (RBD-79: the corrected profile proposes to drop the cache condition and schedule it whatever the cache configuration; the switch still turns it off in both profiles); the activity, lifetime-usage and wallet-refresh periods are deployment settings (seconds); the lifetime-usage refresh can be switched off (the job still ticks but enqueues nothing); event post-validation can be switched off (not scheduled). How each setting is read is BE-CK-12. [vec: clock.jobs_due.001, clock.jobs_due.001x, clock.jobs_due.002, clock.jobs_due.003, clock.jobs_due.009]
- **BE-CK-12** Deployment settings are read as listed below (every value is text; an unset variable and an empty text are the same; the readings are the same in both profiles). [vec: clock.jobs_due.003, clock.jobs_due.008, clock.jobs_due.009, clock.jobs_due.010, clock.jobs_due.011, clock.jobs_due.012]
  - the switches `LAGO_DISABLE_LIFETIME_USAGE_REFRESH` and `LAGO_DISABLE_WALLET_REFRESH` are on only for the exact text `true` (`TRUE`, `1`, and `true` with a leading space leave the job running);
  - `LAGO_DISABLE_EVENTS_VALIDATION` is on for any non-empty text except `0`, `f`, `F`, `false`, `FALSE`, `off` and `OFF` (so `1`, `t`, `no`, `False` and a lone space switch validation off);
  - `LAGO_MEMCACHE_SERVERS`, `LAGO_REDIS_CACHE_URL`, `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` count as configured when they hold any text that is not blank (whitespace only is blank), whatever it says: `LAGO_CLICKHOUSE_ENABLED=false` enables the hand-off of BE-CK-10;
  - the period settings `LAGO_SUBSCRIPTION_ACTIVITY_PROCESSING_INTERVAL_SECONDS` (default 60), `LAGO_LIFETIME_USAGE_REFRESH_INTERVAL_SECONDS` and `LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS` (default 300 each) take their default when blank, otherwise the leading integer of the text after leading whitespace (spaces, tabs, line breaks), with an optional sign, in which a single underscore between two digits is skipped (` 90` → 90, `+30` → 30, `240.9` → 240, `120s` → 120, `1_20` → 120, `1_5_0` → 150, `12_0_` → 120, `3__0` → 3, `_30` → 0, `abc` → 0, `-5` → −5); a period below one second runs the job at every tick (BE-CK-2).
- **BE-CK-5** Local days from an hourly clock (RBD-94): date conditions are evaluated per customer at the run instant (customer zone, else billing-entity zone, else UTC), so each customer is served by the first matching run after its local midnight; billing and termination are therefore judged at local-day granularity, not minute. A rebuild may run them at other minutes or more often provided every local day is served exactly once (each job is idempotent for a given local day, chapter 06). [vec: none (prose only: local-day evaluation is pinned by the periods.billing_days vectors of chapter 06 and the scenario tier's ticks)]

### 2.1 Scenario-tier ticks

The scenario tier (`reimplementation-kit/reference/scenario-tier.md` section 6) names the effects of the clock as tick
jobs that a test build runs on demand (BE-CK-11). Each tick corresponds to these jobs of the schedule above, in this
order:

| Tick | Clock jobs (BE-CK-3) |
|---|---|
| `billing` | `bill_customers`, then `bill_ended_trial_subscriptions`, then the jobs of `usage_update` |
| `usage_update` | the daily usage analytics (out of scope, chapter 14), `refresh_lifetime_usages`, `process_subscription_activity` |
| `lifetime_usage` | `refresh_lifetime_usages` |
| `subscription_activity` | `process_subscription_activity` |
| `refresh_drafts` | `refresh_draft_invoices` |
| `finalize_drafts` | `finalize_invoices` |
| `wallet_refresh` | `refresh_wallets_ongoing_balance` (run whatever the deployment gate of BE-CK-4) |
| `overdue` | `mark_invoices_as_payment_overdue` |
| `terminate_ended` | `terminate_ended_subscriptions` |
| `activate_subscriptions` | `activate_subscriptions` |
| `terminate_coupons` | `terminate_coupons` |
| `terminate_wallets` | `terminate_wallets` |
| `interval_topups` | `top_up_wallet_interval_credits` |
| `termination_alerts` | `termination_alert` |

The other in-scope jobs (`refresh_flagged_subscriptions`, `retry_failed_invoices`, `post_validate_events`,
`expire_incomplete_subscriptions`, `retry_generating_subscription_invoices`,
`terminate_expired_wallet_transaction_rules`, `clean_webhooks`) have no tick: no scenario depends on them.

## 3. Termination alerts

- **BE-CK-6** At each run (hourly, :50) with instant `now`, for each day offset `d` of the configured list (default `15, 45`; deployment setting, comma-separated integers), every **active** subscription whose `ending_at` has the same **UTC** calendar date as `now + d days` gets `subscription.termination_alert`, unless a termination-alert delivery row for that subscription was created on the UTC date of `now` (whatever its delivery status). Pending, terminated and canceled subscriptions and subscriptions without `ending_at` never get it. Nothing is emitted for an organization without webhook endpoints, and because the de-duplication relies on delivery rows, an organization whose endpoints all filter the type out is re-evaluated at every run of that day (each run a no-op; RBD-92). [vec: clock.termination_alert_due.*]

## 4. Other selection conditions

- **BE-CK-7** Per-job selection conditions not covered by another chapter: drafts are finalized on the clock's **UTC** date reaching their expected finalization date, while subscriptions are terminated on the **customer-local** date of `ending_at`, and termination alerts compare **UTC** dates — three different date bases; a stuck `generating` invoice is retried only after one day; overdue marking works in batches and ignores invoices already overdue or with a lost dispute. [vec: none (prose only: no unit op and no shipped scenario exercises these selections: the scenario tier defines the ticks `finalize_drafts`, `overdue` and `refresh_drafts` but no shipped scenario uses them; read at the pin, see Provenance)]

## 5. Idempotency records

- **BE-CK-8** Key derivation: the guarded operation names key parts `{name: value}`; the key is SHA-256 of `v1|` followed by the parts sorted by name, each written as the name immediately followed by the value's text (integers in decimal, `true`/`false`, null as nothing), joined with `|` without escaping. The 32 raw bytes are stored. [vec: clock.idempotency_key.*]
- **BE-CK-9** Semantics: an idempotent operation collects key parts per guarded record during its database transaction (several calls for the same record merge their parts) and, before committing, inserts one idempotency record per guarded record; a key that already exists aborts the whole transaction. Progressive-billing invoices are guarded by `{organization_id, external_subscription_id, invoiced_usage, threshold_amount}` plus `previous_progressive_billing_invoice_id` for recurring thresholds (chapter 10). [vec: none (prose only: the transaction semantics and the progressive-billing key parts have no unit op; clock.idempotency_key.001 pins only the derivation of BE-CK-8 for such parts; read at the pin, see Provenance)]

## 6. Hand-offs

- **BE-CK-10** When the deployment runs the event store variant with the events-processor (Redis store URL and ClickHouse settings present), every 10 s the clock drains the set of subscriptions the events-processor flagged (events-processor-spec, "refresh flag") and refreshes their wallets' ongoing balances and lifetime usages. [vec: clock.jobs_due.002, clock.jobs_due.008]
- **BE-CK-11** Test builds expose the clock to conformance runs as explicit ticks of named jobs at a controllable instant (`system.tick`, `POST /__kit/tick`, `scenario-tier.md` section 6); a tick must drain every follow-up job before answering. [vec: none (prose only: kit convention, pinned by the scenario tier)]

## 7. Rebuild decisions touching this chapter

| RBD | Subject | Compat | Corrected | Vectors |
|---|---|---|---|---|
| RBD-79 | wallet ongoing-balance refresh scheduled only with a cache configured | as today | scheduled whatever the cache configuration; the wallet-refresh switch still turns it off (proposed) | clock.jobs_due.001/001x, clock.jobs_due.009 |
| RBD-92 | termination-alert de-duplication through delivery rows | keep | keep | clock.termination_alert_due.003 |
| RBD-94 | hourly polling, customer-local days | equivalence at local-day granularity | same | clock.jobs_due.* |

## 8. Edge cases (people get these wrong)

- Interval jobs run at clock start, not at :00/:05… (clock.jobs_due.001: 6 activation runs between 00:01 and 00:31).
- A clock started inside a pinned minute runs that job at once, and the next run waits a full hour from it: started at 00:05:30, the :05 jobs run at 00:05:30 and 01:05:30, never at 01:05:00 (clock.jobs_due.006, clock.jobs_due.007).
- The switches are not read alike: the two refresh switches need exactly `true`, while event validation is switched off by `1`, `no` or `False` too; `LAGO_CLICKHOUSE_ENABLED=false` counts as set (clock.jobs_due.008).
- A period setting is not a plain number parse: `240.9` is 240 s, `abc` runs the job every second, and `1_20` is 120 s (clock.jobs_due.010, clock.jobs_due.011, clock.jobs_due.012).
- A disabled lifetime-usage refresh still ticks but enqueues nothing (clock.jobs_due.003).
- Termination alerts use UTC dates even for customers in other zones; `2026-06-16T01:00+02:00` is a 06-15 ending (clock.termination_alert_due.004).
- An alert sent yesterday at 23:50 UTC does not block today's (clock.termination_alert_due.003).
- Idempotency pre-images use null as empty text and do not escape `|` (clock.idempotency_key.003).

## 9. Vectors

| Op | Vectors | Rules |
|---|---|---|
| `clock.termination_alert_due` | clock.termination_alert_due.001-004 | BE-CK-6 |
| `clock.jobs_due` | clock.jobs_due.001-012 (+001x) | BE-CK-2..4, BE-CK-10, BE-CK-12, BE-WH-23 |
| `clock.idempotency_key` | clock.idempotency_key.001-003 | BE-CK-8 |

## Provenance (maintainers)

Executed 2026-10-02 on the pinned toolchain (Ruby 4.0.6, database `lago_api_test_a9`): `spec/clockwork_spec.rb`,
`spec/jobs/clock/**`, `spec/services/idempotency_spec.rb`, `spec/services/idempotency_records/**` are part of the
1384-example set of chapter 11's provenance (all green). kitrun of `clock.jsonl` against `oracle.sh adapter` → 12/12
compat PASS. Oracle module `reimplementation-kit/scripts/maintainer/oracle-adapter/ops/clock.rb`: `clock.jobs_due`
loads the reference clock file into the clockwork test harness (1-second ticks, environment set per vector, each
job's block invoked once to see whether it enqueues); `clock.termination_alert_due` runs the reference job at the
vector's instant over factory subscriptions and recorded delivery rows.

| Rules | Reference code @591ae90 |
|---|---|
| BE-CK-1 | `$API/app/jobs/application_job.rb:3-30`, `$API/app/jobs/clock_job.rb` |
| BE-CK-2..5, BE-CK-12 | `$API/clock.rb:19-216`, `$API/spec/clockwork_spec.rb:31-120`, `$API/app/jobs/clock/refresh_wallets_ongoing_balance_job.rb`, `$API/app/jobs/clock/refresh_lifetime_usages_job.rb`, `$API/app/jobs/clock/terminate_ended_subscriptions_job.rb:5-30` |
| BE-CK-6 | `$API/app/jobs/clock/subscriptions_to_be_terminated_job.rb:7-40`, `$API/spec/jobs/clock/subscriptions_to_be_terminated_job_spec.rb:20-444` |
| BE-CK-7 | `$API/app/models/invoice.rb:143-144`, `$API/app/jobs/clock/retry_generating_subscription_invoices_job.rb:7-28`, `$API/app/jobs/clock/mark_invoices_as_payment_overdue_job.rb`, `$API/app/models/wallet.rb:66` |
| BE-CK-8, BE-CK-9 | `$API/app/services/idempotency_records/key_service.rb:7-23`, `$API/app/support/idempotency.rb:12-106`, `$API/app/services/invoices/progressive_billing_service.rb:16-34` |
| BE-CK-10 | `$API/clock.rb:209-216`, `$API/app/jobs/clock/consume_subscription_refreshed_queue_job.rb` |
| Section 2.1 | the tick-to-job map of the oracle's scenario module (`reimplementation-kit/scripts/maintainer/oracle-adapter/ops/system.rb`, `JOBS`) against the class of each entry of `$API/clock.rb:21-212` |

Fix round of 2026-10-02: BE-CK-7 no longer claims coverage by the scenario tier (no shipped scenario runs
`finalize_drafts`, `overdue` or `refresh_drafts`), BE-CK-9 is marked prose only (its vector pins the derivation only),
and section 2.1 mirrors the scenario tier's tick vocabulary; kitrun of `clock.jsonl` against `oracle.sh adapter`
(database `lago_api_test_fr4`) unchanged.

Fix round of 2026-10-05 (database `lago_api_test_fr2g5`, same toolchain): new vectors `clock.jobs_due.006` to `.011`
executed through `oracle.sh adapter` (PASS). Further `clock.jobs_due` calls through the same adapter (not shipped)
confirmed each reading of BE-CK-12: `LAGO_DISABLE_EVENTS_VALIDATION` set to `f`, `F`, `0`, `false`, `FALSE`, `off`,
`OFF` or empty keeps post-validation scheduled, while `1`, `t`, `true`, `no`, `False`, `0.0` and a lone space remove
it; `TRUE`, `1` and `true` with a leading space leave both refresh switches off (the job runs); whitespace-only
cache, store and ClickHouse settings count as unset; whitespace-only periods take the default; `+30` reads 30. The
readings are those of `$API/clock.rb:33-72`, `$API/clock.rb:175-183` and `$API/clock.rb:209-216` (exact text
comparison, a boolean cast, presence tests and an integer prefix). The tick semantics of BE-CK-2 are those of the
clock library at the pin (one-second sleep, a run requires one full period since the previous run of the same job).

Independent verification the same day (database `lago_api_test_v2g5`): the new vectors re-run through `oracle.sh
adapter` (PASS); further unshipped `clock.jobs_due` calls showed that the integer prefix of the period settings skips
a single underscore between digits (`1_20` → 120 s, `1_5_0` → 150 s, `2_0` → 20 s) while a doubled, leading or
post-sign underscore ends the number (`3__0` → 3 s, `_30` and `-_5` → every tick), and that a leading tab or line
break is skipped like a space; vector `clock.jobs_due.012` executed through `oracle.sh adapter` (PASS).

Update triggers: a pin bump (re-run the oracle over `clock.jsonl`), any change of `clock.rb` or a clock job, an
owner ruling on RBD-79.
