# Scenario tier: end-to-end scenarios over the REST API and the clock

> Licence note: the scenarios record observable behaviour of lago-api (AGPL-3.0) at pin `591ae90`, obtained by
> replaying each scenario on the reference. They are behavioural data (requests, clock ticks, resulting API
> representations), not source code. Read `legal-and-provenance.md` before using the kit for a proprietary rebuild.

The unit vectors (`vector-format.md`) grade one function at a time. A **scenario** grades the assembled engine: it
creates a tenant's catalogue over REST API v1, moves a test clock, sends events and other API calls, runs clock jobs,
and compares the resulting invoices, credit notes, wallets and (optionally) subscriptions with the reference.
Scenarios are the acceptance bar of component CRC-10 (`acceptance-and-grading.md`) and the place where cross-chapter
interactions are pinned (tax after coupon share, true-up fees, period boundaries on a real invoice, wallet
consumption at finalization, …). The machine-readable form is `schemas/scenario.schema.json`; the runner is
`scripts/scenario-replay.py`; the scenarios live in `billing-engine-spec/scenarios/` with a `MANIFEST.md`.

<!-- evidence-check: off normative spec; evidence = the scenario files themselves, each replayed on the reference (evidence.by replay-on-lago) -->

## 1. Files and ids

| Rule | Statement |
|---|---|
| ST-1 | One scenario per file `billing-engine-spec/scenarios/<id>.json`, UTF-8, pretty-printed (any whitespace). The id matches `^scn(\.[a-z0-9_]+)+\.[0-9]{3}x?$`; the second segment is the topic (`invoice`, `credit_note`, `subscription`, `usage`, `pay_in_advance`, `commitment`, `fixed_charge`, `wallet`, `alert`, `lifetime`, `events`, `plan`, `store_ch`; no `events` or `plan` scenario ships in this version: event ingestion and catalogue edits are graded by unit vectors only). |
| ST-2 | A scenario is at most 16 KB in compact JSON (target 12 KB; at most five scenarios up to 24 KB); the whole tier at most 0.60 MB (validator rule BUDGET). |
| ST-3 | Ids, profiles, rulings, pairs, `rules`, `rbd`, `tags` and `evidence` follow the unit-vector envelope (`vector-format.md` sections 2, 5-7); `area` is always `scn`. Every shipped scenario is EXECUTED: it was replayed on the reference and passed (`evidence.by` = `replay-on-lago`). A scenario of a rebuild decision whose corrected end state cannot be executed ships as an unpaired `compat` scenario with a note (`scn.subscription.downgrade.002`, RBD-59); a `--profile corrected` replay skips it. |
| ST-4 | `billing-engine-spec/scenarios/MANIFEST.md` lists every scenario: id, title, topic, rules, RBDs, size. |

## 2. The scenario document

| Field | Req. | Meaning |
|---|---|---|
| `kit_schema`, `id`, `area`, `title`, `profile`, `ruling`, `pair`, `rules`, `rbd`, `tags`, `evidence`, `notes` | yes (`notes` optional) | as for unit vectors |
| `setup` | yes | the tenant and its catalogue (section 3, 4) |
| `steps` | yes | ordered list of `api`, `tick` and `snapshot` steps (section 5) |
| `expect` | yes | subset of the final snapshot (section 7) |
| `compare` | no | comparison overrides for `expect` (section 8) |

Example (`scn.usage.standard.001`, three of its four identical event steps elided):

```json
{"kit_schema": 1, "id": "scn.usage.standard.001", "area": "scn", "title": "current usage, standard model",
 "profile": "both", "ruling": "decided", "pair": null, "rules": ["BE-PR-6", "BE-AG-11"], "rbd": [], "tags": ["core"],
 "evidence": {"kind": "EXECUTED", "by": "replay-on-lago", "ref": "$API/spec/scenarios/current_usage/by_charge_model/standard_spec.rb:16", "…": "…"},
 "setup": {"at": "2024-03-05T00:00:00Z", "organization": {"document_number_prefix": "ORG-0001"}, "premium": false, "store": "pg",
   "billable_metrics": [{"name": "metric_1", "code": "metric_1", "aggregation_type": "count_agg"}],
   "plans": [{"name": "plan_1", "code": "plan_1", "interval": "monthly", "amount_cents": 0, "amount_currency": "EUR", "pay_in_advance": false,
              "charges": [{"code": "charge_1", "billable_metric_id": "{{bm:metric_1}}", "charge_model": "standard", "properties": {"amount": "12.5"}}]}],
   "customers": [{"external_id": "cust_1", "currency": "EUR"}]},
 "steps": [
   {"op": "api", "method": "POST", "path": "/api/v1/subscriptions",
    "body": {"subscription": {"external_customer_id": "cust_1", "external_id": "cust_1", "plan_code": "plan_1"}}},
   {"at": "2024-03-06T00:00:00Z", "op": "api", "method": "POST", "path": "/api/v1/events",
    "body": {"event": {"code": "metric_1", "transaction_id": "tx_1", "external_subscription_id": "cust_1"}}},
   "… tx_2, tx_3, tx_4 …",
   {"op": "api", "method": "GET", "path": "/api/v1/customers/cust_1/current_usage", "query": {"external_subscription_id": "cust_1"},
    "expect": {"status": 200, "body": {"customer_usage": {"from_datetime": "2024-03-05T00:00:00Z", "to_datetime": "2024-03-31T23:59:59Z",
      "amount_cents": 5000, "charges_usage": [{"units": "4.0", "events_count": 4, "amount_cents": 5000,
      "charge": {"code": "charge_1", "charge_model": "standard"}, "billable_metric": {"code": "metric_1", "aggregation_type": "count_agg"}, "filters": []}]}}}}],
 "expect": {"invoices": []}}
```

## 3. Tenant settings (`system.reset`)

Every replay starts from an **empty tenant**: one organization with exactly one billing entity, an API key, no
catalogue, no customers, no webhook endpoints. `setup.organization` sets tenant-wide settings; they apply to the
organization and to its billing entity alike (`setup.billing_entity` may override a billing-entity setting). Absent
keys take these defaults:

| Setting | Default | Meaning (chapter) |
|---|---|---|
| `timezone` | `UTC` | billing-entity time zone, the fallback of every customer without one (BE-DM-10) |
| `default_currency` | `USD` | |
| `document_numbering` | `per_customer` | invoice numbering scheme (BE-DM-40, BE-DM-41) |
| `document_number_prefix` | (no portable default) | every kit scenario sets it (`ORG-0001`) so invoice numbers are deterministic (BE-DM-32) |
| `invoice_grace_period` | `0` | days a periodic invoice stays draft (chapter 07) |
| `net_payment_term` | `0` | days between issuing and payment due date (chapter 07) |
| `finalize_zero_amount_invoice` | `true` | chapter 07 |
| `premium_integrations` | `[]` | per-tenant feature switches; the scenarios use `progressive_billing` and `lifetime_usage` (chapter 10) |
| `max_wallets` | none | wallet limit per customer (chapter 09) |
| `clickhouse_deduplication_enabled` | `false` | columnar store only: re-sent events with the same transaction id and timestamp count once at query time (BE-AG-68, chapter 04); no shipped scenario sets it |
| `document_locale`, `eu_tax_management` | `en`, `false` | |
| `subscription_invoice_issuing_date_anchor` / `_adjustment` | `next_period_start` / `align_with_finalization_date` | issuing-date rules (chapter 07) |

`setup.premium` (boolean) switches on the licence-gated behaviour for the whole replay (RBD-97: graduated
percentage, per-transaction min/max, pricing units, charge minimums, progressive billing, alerts, wallet ongoing
balance refresh, grace periods and time zones set through the API, …). `setup.store` is `pg` (relational event
store, normative) or `ch` (columnar store variant, tag `store-ch`, optional; chapter 04 section on store variants).
For a `ch` tenant every accepted event must be visible to usage computation before `system.api` returns, exactly as
the events-processor would have enriched it (`events-processor-spec`): with value = the property named by the
metric's `field_name` (or `"1"` for a count metric) and, for a pay-in-advance charge, the in-advance fee computed.

## 4. Setup objects

`setup.at` is the clock for the whole setup. The runner creates the catalogue over REST, in this order, each object
with one `POST` whose body wraps the setup object under its root key, and requires HTTP 200 for each:

| Setup list | Endpoint | Root key | Auto-captured variable (value = the response's `lago_id`) |
|---|---|---|---|
| `taxes` | `POST /api/v1/taxes` | `tax` | `tax:<code>` |
| `billable_metrics` | `POST /api/v1/billable_metrics` | `billable_metric` | `bm:<code>` |
| `add_ons` | `POST /api/v1/add_ons` | `add_on` | `add_on:<code>` |
| `coupons` | `POST /api/v1/coupons` | `coupon` | `coupon:<code>` |
| `plans` | `POST /api/v1/plans` | `plan` | `plan:<code>`, and per charge / fixed charge in the response `charge:<plan code>:<charge code>`, `fixed_charge:<plan code>:<code>` |
| `customers` | `POST /api/v1/customers` | `customer` | `customer:<external_id>` |

Bodies are REST v1 create bodies (field catalogue in `billing-engine-spec` chapter 11) and may contain
placeholders (section 5.3); a plan's charges reference their metric with `"billable_metric_id": "{{bm:<code>}}"`,
a fixed charge its add-on with `"add_on_id": "{{add_on:<code>}}"`. Objects that the scenario creates later (a second
plan for an upgrade, a coupon applied mid-period) are ordinary `api` steps.

REST endpoints the shipped scenarios call (setup and steps; field catalogue in `billing-engine-spec` chapter 11):
`POST /api/v1/{taxes, billable_metrics, add_ons, coupons, plans, customers, subscriptions, events, applied_coupons,
wallets, wallet_transactions, invoices}`, `POST /api/v1/events/estimate_fees`, `GET /api/v1/customers/{external_id}/current_usage`
(query `external_subscription_id`), `DELETE /api/v1/subscriptions/{external_id}` (optional query
`on_termination_credit_note`, `on_termination_invoice`), `PUT /api/v1/plans/{code}`,
`PUT /api/v1/subscriptions/{external_id}/fixed_charges/{code}`, `PUT /api/v1/invoices/{id}` (payment status),
`PUT /api/v1/invoices/{id}/finalize`, `POST /api/v1/invoices/{id}/void`, `GET /api/v1/wallet_transactions/{id}/fundings`,
`POST /api/v1/subscriptions/{external_id}/alerts`, `POST /api/v1/customers/{external_id}/wallets/{code}/alerts`.
Clock jobs used: `billing`, `usage_update`, `lifetime_usage`, `wallet_refresh`, `terminate_ended`; tenant switches used:
`premium` (30 scenarios), `premium_integrations` `progressive_billing` and `lifetime_usage`, `store: ch` (3 scenarios).
Intermediate `snapshot` steps: 16 in 10 scenarios; `subscriptions` asserted (final or intermediate): 17 scenarios.

## 5. Steps

### 5.1 Clock

| Rule | Statement |
|---|---|
| ST-10 | Every step may carry `at` (an instant, whole seconds in every shipped scenario). The clock is set to `setup.at` before the setup and changes only when a step's `at` differs from the current clock; a step without `at` runs at the current clock. The clock may also move backwards (a few scenarios interleave steps on different dates exactly as their source did); objects keep the instant at which they were created. Some instants lie after the rest of the scenario, from 2026-09-15T10:00:00Z on, one second apart (their source ran those steps outside its own time travel, on the "present" clock; the kit records them on a fixed present instead of the machine's wall clock): they are ordinary scenario instants. |
| ST-11 | The clock is **frozen** during a step: every instant the system records while handling the step and its follow-up work ("now": creation instants, an event's default `timestamp`, issuing dates, …) is that instant. Time never advances by itself between steps. |
| ST-12 | All asynchronous follow-up work of a step (event post-processing, pay-in-advance fees, invoice finalization after creation, wallet top-up invoices, …) completes, at the step's clock, before the next step starts. A rebuild with queues must drain them in its test build. |

### 5.2 Step kinds

| `op` | Fields | Semantics |
|---|---|---|
| `api` | `method`, `path` (starts with `/api/v1/`), `query` (object, optional), `body` (object, optional), `expect`, `compare`, `capture`, `bind` | one REST v1 call with the tenant's API key; `expect` is a subset of `{"status": <int>, "body": <parsed JSON or null>}`; without `expect` the call must answer a status below 400 |
| `tick` | `jobs`: list of clock-job names (section 6) | run each named job at the current clock, in order, draining follow-up work after each |
| `snapshot` | `expect`, `compare`, `note` | intermediate check: the current snapshot (section 7) must contain `expect`; it names only the lists it asserts (for example only `subscriptions` right after a downgrade request, or only `invoices` after a threshold crossing), each compared in full like the final expectation |

### 5.3 Variables

| Rule | Statement |
|---|---|
| ST-20 | A string `"{{name}}"` anywhere in a setup body, a step `path`, a `query` value or a `body` is replaced by the variable's value; when the whole string is one placeholder the variable's JSON value is used as is, otherwise its text is spliced in. An unknown variable fails the scenario. |
| ST-21 | Variables come from setup auto-captures (section 4), from `capture` (`{"name": "<path in the response body>"}`, path syntax `a.b[0].c`) after a successful step, and from `bind`. |
| ST-22 | `bind` (`{"name": {"from": <list>, "where": <subset>, "index"?: n, "pick"?: "lago_id"}}`) resolves objects that only exist in the system's state (an invoice created by a tick, one of its fees): the runner takes a snapshot right before the step, selects the elements of `from` (`invoices`, `invoices[*].fees`, `credit_notes`, `credit_notes[*].items`, `wallets`, `wallet_transactions`, `subscriptions`, `fees`) that contain `where` (subset match, same comparison rules as expectations), and takes `pick` (default `lago_id`) of the only match, or of match number `index` (0-based, snapshot order). No match or several matches without `index` fail the scenario. |

## 6. Clock-job vocabulary (`tick`)

A tick runs a job "as if the hourly clock fired at the current instant"; local dates are those of each customer's
effective time zone at that instant (chapter 13 owns the production schedule; here only the effect matters; chapter
13 section 2.1 maps each tick to the clock jobs it stands for).

| Job | Effect |
|---|---|
| `billing` | Bill every subscription whose billing day (chapter 06) is today: create the periodic invoice of the period that just ended (subscription fee in arrears or for the next period in advance, usage charges, fixed charges, minimum-commitment true-up, progressive-billing credits; chapter 07), then bill subscriptions whose free trial ended today, then run `usage_update`. |
| `usage_update` | Refresh lifetime usage of subscriptions that received usage and create progressive-billing invoices for crossed thresholds (chapter 10), evaluate usage alerts (chapter 10). (The reference also computes daily usage analytics here, which is out of scope and invisible in the snapshot.) |
| `refresh_drafts` | Recompute every draft invoice flagged for refresh that still has an active subscription (new events after the draft was created, chapter 07). |
| `finalize_drafts` | Finalize every draft invoice whose grace period has ended (chapter 07). |
| `wallet_refresh` | Recompute the ongoing balance of every customer wallet flagged for refresh (chapter 09; premium). |
| `overdue` | Mark finalized, unpaid invoices whose payment due date has passed as payment-overdue. |
| `terminate_ended` | Terminate active subscriptions whose `ending_at` falls on today's local date (chapter 06). |
| `activate_subscriptions` | Activate pending subscriptions whose start instant has come (chapter 06). |
| `terminate_coupons`, `terminate_wallets` | Terminate coupons / wallets whose expiration has passed. |
| `interval_topups` | Create the interval top-ups of recurring wallet rules that are due (chapter 09). |
| `termination_alerts` | Emit the "subscription will terminate" notifications (chapter 12; no snapshot effect). |
| `lifetime_usage`, `subscription_activity` | The two halves of `usage_update`, separately. |

## 7. The snapshot

`system.snapshot` returns the tenant's state as API v1 representations (field catalogue: `billing-engine-spec`
chapter 11):

| Key | Content |
|---|---|
| `invoices` | every invoice, each with `customer`, `billing_periods`, `subscriptions`, `fees`, `credits`, `applied_taxes` embedded |
| `credit_notes` | every credit note with `items` and `applied_taxes` |
| `wallets`, `wallet_transactions` | every wallet and wallet transaction |
| `subscriptions` | every subscription (any status); expectations keep `external_id`, `external_customer_id`, `plan_code`, `status`, `billing_time`, `subscription_at`, `started_at`, `trial_ended_at`, `ending_at`, `terminated_at`, `canceled_at`, `previous_plan_code`, `next_plan_code`, `downgrade_plan_date` (a scenario that asserts no subscription omits the key) |
| `fees` | every fee that is not attached to an invoice (for example a pay-in-advance fee of a non-invoiceable charge), same representation as `GET /api/v1/fees` |

Lists are in creation order; where several objects are created at the same instant their order is undefined, and
scenarios compare such lists as sets (section 8). Expectations never contain volatile fields: internal ids
(`lago_*`), creation/update instants, URLs (documents are out of scope), counters, names and descriptions that do not
influence billing, and values derived from the wall clock of the machine that produces the snapshot. They do contain
`number` (the prefix is fixed by the setup), amounts, statuses, dates, units and fee item codes.

## 8. Comparison

`expect` (final and per step) is graded with the unit-vector comparison rules (`vector-format.md` section 4): an
object is a subset (extra keys allowed), integers compare exactly, decimal strings and JSON floats numerically (so
`"20.0"` = `20.0` = `"20"`), instants as instants, other strings as text, arrays in order and with the same length.
`compare` maps paths (relative to the snapshot for the final `expect`, relative to `{"status", "body"}` for a step)
to modes; scenarios use `set` for every list whose order the API does not define (invoices of one tick, fees of an
invoice, applied taxes, credit-note items, wallet transactions, the charges of a usage answer). Diff lines name the
place: `expect.invoices[0].total_amount_cents: expected 20900 (integer) got 20000`,
`steps[3].body.customer_usage.amount_cents: …`.

## 9. The `system.*` binding and the HTTP bridge

| Op | Input | Output |
|---|---|---|
| `system.reset` | `{organization, billing_entity?, premium, store}` | `{}` — empty tenant (section 3); erases every previous tenant of the adapter |
| `system.set_clock` | `{now}` | `{}` |
| `system.api` | `{method, path, query?, body?}` | `{status, body}` — after all follow-up work (ST-12) |
| `system.tick` | `{jobs}` | `{}` — after all follow-up work |
| `system.snapshot` | `{}` | `{invoices, credit_notes, wallets, wallet_transactions, subscriptions, fees}` (section 7) |

These ops are stateful (AP-6 does not apply); one adapter process replays the scenarios one after another. Instead
of an adapter, a test build of a service can expose the bridge endpoints and be driven with
`scenario-replay.py --http BASE_URL` (prefix `/__kit`, `--kit-prefix` to change):

| Bridge endpoint | Body | Answer |
|---|---|---|
| `POST /__kit/reset` | the `system.reset` input | `200 {"api_key": "<key>"}` (the runner then sends `Authorization: Bearer <key>` on REST calls) |
| `POST /__kit/clock` | `{"now": "<instant>"}` | any 2xx |
| `POST /__kit/tick` | `{"jobs": [...]}` | any 2xx after draining |
| `GET /__kit/snapshot` | — | `200` + the snapshot object |

The REST endpoints themselves must drain follow-up work before answering in the test build. These endpoints are a
kit convention; never expose them in production.

## 10. Running `scenario-replay.py`

```
python3 scripts/scenario-replay.py --impl-cmd "<adapter command>"        # or --http http://localhost:3000
        [--scenarios FILE ...] [--only REGEX] [--profile compat|corrected] [--report out.json] [--show-diff N]
        [--quiet] [--require-all] [--timeout S] [--include-holdout DIR] [--dump DIR]
```

`--dump DIR` writes one `<id>.replay.json` per scenario with every call (tagged with its step index and purpose:
setup, bind, step, final) and every answer, useful to debug a FAIL. `--mutate` and `--mutate-steps` are the
maintainers' self-checks of ST-31.

Output: `PASS|FAIL|ERROR|UNRULED <id> (<seconds>)` per scenario with diff lines under failures, an area row and
`SUMMARY scenario-replay: scenarios=N passed=N failed=N errors=N skipped=N unruled=N exit=N`. FAIL = a value or
status mismatch, a setup create that did not answer 200, or an unresolvable variable/bind; ERROR = protocol trouble
(adapter crash, timeout, `bad_input`/`internal`). Verdict: the `scn` threshold of `acceptance/thresholds.json`
(60 % shipped, a stretch goal) and 100 % of `core` scenarios; `--require-all` demands every scenario. Exit codes: 0
pass, 3 below threshold, 2 setup/protocol error, 4 invalid scenario files, 1 usage. Scenarios graded under
`--profile corrected` with `ruling: proposed` are UNRULED (never counted). `--report` writes JSON (not the kitrun
`report.schema.json` shape): `{runner, version, proto, started_at, finished_at, profile, impl, exit_code, areas: [{area,
set, total, pass, fail, error, skip, unruled, rate, core_rate, threshold, verdict}], scenarios: [{id, set, status, ms,
diffs, warnings, tags}]}`.

## 11. Building a system adapter for an implementation

- Map `reset` to "drop every tenant, create one tenant with these settings and one API key"; keep the key in the
  adapter and send it on every REST call.
- Make the clock injectable (a process-wide "now" provider) and set it on `set_clock`; nothing may read the host
  clock while replaying.
- Run asynchronous work synchronously in the test build, or wait until the queues are empty before answering
  (`api`, `tick`).
- Implement `snapshot` with the same serializers as the REST API (`GET /api/v1/invoices`, `/credit_notes`,
  `/wallets`, `/wallet_transactions`, `/subscriptions`, `/fees` with the embedded collections of section 7).
- Start with the `core` scenarios; `--show-diff 20` prints every mismatching path.

## 12. Determinism and known limits

| Rule | Statement |
|---|---|
| ST-30 | Scenarios avoid behaviour the reference leaves undefined: ties between objects created at the same instant (charge filters, coupons, wallets) and between events with equal timestamps are never needed to decide an expected value. A source example that depended on such an order was not shipped (RBD-30, KQ-13). |
| ST-31 | Every shipped scenario was replayed on the reference twice in fresh processes with identical results, and a copy with one expected integer changed by +1 failed (mutation check); a scenario with intermediate snapshot steps also failed when only those steps' expectations were changed. |
| ST-32 | Out of scope in this tier: payment providers and payments, PDFs/documents, e-invoicing, integrations, emails, webhooks (no endpoint is configured; chapter 12 and its unit vectors cover webhook payloads and signing), dunning, analytics and daily usage. |

## Provenance (maintainers)

- Scenario sources: 71 scenarios come from the reference's own end-to-end specs under `$API/spec/scenarios/` @591ae90
  (one source example per scenario, cited in each scenario's `evidence.ref`), recorded with
  `scripts/maintainer/scenario-recorder.rb` (loaded with `oracle.sh run -r`), converted with
  `scripts/maintainer/convert-scenarios.py` driven by `scripts/maintainer/scenario-manifest.tsv`; each expectation is
  the source example's own state (final, or at an intermediate snapshot step), so a PASS on the oracle also proves the
  kit form reproduces the source example (KQ-13). 5 scenarios are authored in kit form for rules that no source
  example isolates (manifest source `authored`): `scn.subscription.downgrade.002` (BE-SP-62, RBD-59),
  `scn.subscription.fee_selection.001`..`.004` (BE-SP-65, BE-SP-66). Their expectations were produced by replaying them
  on the oracle (`scenario-replay.py --dump`, then `convert-scenarios.py --fill`; `evidence.ref` = `derived`) and
  checked by hand against those rules (for example the upgraded plan's recurring charge is absent from the
  termination invoice and billed by the successor with the carried units; the starting invoice of an advance plan
  holds the in-advance fixed charge only). All 76 pass the same gate (`scripts/maintainer/replay-on-lago.sh`).
- Recorder v4 (2026-10-02 fix round): (1) a kit clock replaces the machine's wall clock: every example starts frozen at
  2026-09-15T10:00:00Z (one week after the pin's commit of 2026-09-08, after every date the in-scope source specs
  travel to) unless a spec's own around hook already travels, and every step the spec runs outside its own time
  travel moves to the next whole second after the latest instant seen. The 11 scenarios whose sources ran steps on
  the wall clock (`scn.alert.usage.001`, `scn.invoice.coupons.001`, `scn.invoice.one_off.001`/`.002`,
  `scn.invoice.prepaid.002`, `scn.invoice.void.001`, `scn.subscription.terminate.005`, `scn.wallet.alert.001`,
  `scn.wallet.balance.001`, `scn.wallet.traceability.001`/`.003`) were re-minted: they carried microsecond instants
  of the recording day before and now carry whole seconds that a re-mint reproduces. One recorded example fails on a
  frozen clock because it orders two credit notes created in one step by creation time
  (`$API/spec/scenarios/invoices/void_invoice_spec.rb:91`); it is not shipped. (2) The state at the start of every
  step is stored, so the converter can add intermediate snapshot steps where the source asserts mid-way (`snapshots`
  option; the step runs at the instant the state was serialised, because a pending downgrade's date depends on
  "now"). (3) Random hexadecimal transaction ids become `trx_<n>`; failures collected by `aggregate_failures` now
  also keep an example out of the recordings.
- The oracle side of the `system.*` ops is `scripts/maintainer/oracle-adapter/ops/system.rb`: full Rack stack per REST
  call, ActiveJob/Sidekiq drained after each call and tick (like `$API/spec/support/scenarios_helper.rb:4-26` and
  `$API/spec/support/queues_helper.rb:18-23`), frozen clock per call, PDF rendering stubbed like
  `$API/spec/support/pdf_helper.rb:5-11`, Kafka captured in memory, tenant created by
  `$API/app/services/organizations/create_service.rb:13`. Tick names map to `$API/clock.rb` jobs:
  `billing` = `Clock::SubscriptionsBillerJob` + `Clock::FreeTrialSubscriptionsBillerJob` then `usage_update`
  (`$API/spec/support/scenarios_helper.rb:413-439`); `usage_update` = `Clock::ComputeAllDailyUsagesJob`,
  `Clock::RefreshLifetimeUsagesJob`, `Clock::ProcessAllSubscriptionActivitiesJob`; the others one job each (table
  `KitSystem::JOBS` in `system.rb`).
- Snapshot serialisation mirrors the REST controllers' include lists (`$API/app/controllers/api/v1/invoices_controller.rb:399-406`,
  `$API/app/controllers/api/v1/credit_notes_controller.rb:159-161`). The authored scenarios rely on
  `$API/app/services/invoices/calculate_fees_service.rb:147` (charge selection), `:181` (fixed-charge selection) and
  `$API/app/services/plans/update_service.rb:332` (pending downgrades cancelled on an amount edit).
- Observed 2026-10-02, first minting (recorder v3): 64 source spec files, `{"example_count":577,"failure_count":0,…}`;
  70 scenarios accepted twice (independent re-check on a separate database: `accepted=70`, 22 source examples green,
  HTTP bridge 8/8 PASS and `--mutate` 3/3 FAIL).
- Observed 2026-10-02, fix round (pinned toolchain, own `ORACLE_DB`): `oracle.sh run -j 1 -r scenario-recorder.rb` on
  the 17 source spec files of the re-minted scenarios → `{"example_count":106,"failure_count":1,…}` (the frozen-clock
  example above) plus `{"example_count":2,"failure_count":0,…}`; `convert-scenarios.py` → 71 OK and 5 KEEP (authored),
  `--fill` → 5 FILLED; a second conversion of the same recordings is byte-identical; of the 48 scenarios still converted
  from v3 recordings, 43 are byte-identical to the first minting and 5 changed only where the manifest now keeps
  subscriptions (and random transaction ids); `validate-vectors.py` on the 76 files →
  `errors=0 warnings=0`; `replay-on-lago.sh` on all 76 → both replays `passed=76 failed=0` (about 3.5 min each), the
  mutated pass `failed=76`, the snapshot-step mutated pass `failed=10` (every scenario with an intermediate snapshot),
  `SUMMARY replay-on-lago: scenarios=76 accepted=76 rejected=0`; through the HTTP bridge (a test server wrapping the
  same oracle ops, `scenario-replay.py --http`) 5 scenarios with snapshot steps or authored setup 5/5 PASS and
  `--mutate-steps` 2/2 FAIL.
- Of 92 curated source candidates, 21 were not shipped: factory-only state with no REST equivalent (charge filters with
  empty values, factory subscriptions, wallets and events, direct model updates), order-dependent results (document
  numbers of drafts finalized in the same tick, two outbound wallet transactions created at the same instant),
  wall-clock drift inside one source step (recorder v3), and redundancy; `scenario-manifest.tsv` lists the reasons.
- Update triggers: a pin bump (re-record with recorder v4 and re-run `replay-on-lago.sh` on every scenario; a FAIL is a
  behaviour change or a kit defect, triaged like a unit vector; move the kit clock epoch past any new source date), a
  change of the `system.*` contract, a new tick job.
