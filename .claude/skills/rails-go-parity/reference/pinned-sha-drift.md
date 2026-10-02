# Pinned-SHA drift: events-processor HEAD is newer than the pinned lago-api

Read this when you reason about how Go behaves "together with Rails", when you touch anything that
Rails reads (topics, payloads, Redis, cache keys), or when someone asks "is this combination safe to
deploy?". Facts verified 2026-10-01. Set up from the repo root:
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api); H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`.

## 1. The two dates

| Side | Commit | Date | Re-verify |
|---|---|---|---|
| events-processor (code facts as of) | `5308258` (last commit touching `events-processor/`; tree `83e012866f29`; the working branch may carry skills-only commits on top) | 2026-09-18 | `git log -1 --format='%h %cs' -- events-processor` |
| pinned lago-api (gitlink `api`) | `591ae90` (lago-api v1.53.0) | 2026-09-08 | `git ls-tree HEAD api` then `git -C "$API" log -1 --format='%h %cs'` |
| umbrella bump that set the pin | `ba292b6` "Bump version to v1.53.0 (#792)" | 2026-09-08 | `git -C "$H" log -1 --format='%h %cs %s' ba292b6` |

Events-processor commits after the bump (`git -C "$H" log --format='%h %cs %s' ba292b6..5308258 -- events-processor`):
`dee9bed` (deps), **`2fd8e8b`** (2026-09-14, #766), **`d9c32b6`** (2026-09-18, #797), `7d9a7cb`, `cffbca1`,
`065fe59` (deps), `5308258` (Dockerfile.staging). Only `2fd8e8b` and `d9c32b6` change behaviour Rails can see.

Where the combination actually runs: the dev stack builds events-processor from source
(`docker-compose.dev.yml:318-325`, `Dockerfile.dev`) and mounts the `api` submodule working tree
(`docker-compose.dev.yml:179`). The root `docker-compose.yml` and `deploy/*.yml` have no events-processor
service (`grep -c events-processor docker-compose.yml deploy/*.yml` → 0 each). Production pairing of
images is not visible from this repo (UNVERIFIED).

## 2. What changed in Go after the pin

| Commit | Go change | Rails-visible effect |
|---|---|---|
| `d9c32b6` | Deleted `flat_filters` (per-event charge + charge-filter resolution), the `events_enriched_expanded` producer and `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC`, the `reprocess` branch, `target_wallet_code` enrichment. Pay-in-advance now = "plan has a non-deleted `pay_in_advance` charge for the BM" (`events-processor/models/charges.go:47-66`). | Nothing is produced to `events_enriched_expanded` any more. `reprocess` events now produce a normal `events_enriched` row. Removed from `.env.development.default` and the dev topic list (`git -C "$H" show d9c32b6 -- .env.development.default docker-compose.dev.yml`). |
| `2fd8e8b` | Stopped expiring Rails `charge-usage/1/...` cache keys in Redis; removed `models/charge_cache.go`, `cache_service.go`. | For ClickHouse-store orgs nothing expires the current-usage cache unless the Rails flag `lazy_charge_usage_cache` is on. `LAGO_REDIS_CACHE_*` constants in `events-processor/processors/main_processor.go:40-43` are now dead. |

## 3. lago-api code at the pin that still references what Go removed

Each line below was read at `$API` = lago-api `591ae90` on 2026-10-01. Status is DIVERGE-CODE (read, not
exercised). Production impact depends on **OPEN DECISION OD-8 (owner)**: the production state of
`pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation`.

| # | `$API` location | What it still does | Consequence with Go >= `d9c32b6`/`2fd8e8b` |
|---|---|---|---|
| DR1 | `db/clickhouse_migrate/20250814124830_create_events_enriched_expanded_queue.rb:9` | Interpolates `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC` into the Kafka engine table | Dev env no longer defines it, so a fresh migration gets `kafka_topic_list = ''`. Effect on `rails db:migrate` UNVERIFIED (no ClickHouse server here). |
| DR2 | `app/services/events/stores/clickhouse_store.rb:133-140` (`distinct_charges_and_filters` → `ClickhouseEnrichedStore`), called from `app/services/events/billing_period_filters/charges_resolver.rb:14` when `organization.pre_filter_events?` | Reads `events_enriched_expanded` to find which charges/filters saw events | Orgs with `pre_filter_events = true` read a table nobody feeds: new usage would not be found (OD-8). |
| DR3 | `app/services/events/stores/store_factory.rb:41-43`, flag `app/config/feature_flags.yaml:5` | `enriched_events_aggregation` switches aggregation to `ClickhouseEnrichedStore` | Aggregates from the unfed table. `d9c32b6` says the flag "is off everywhere" (UNVERIFIED, OD-8). |
| DR4 | `app/services/events/stores/clickhouse/enriched_store_migration/comparison_service.rb:61` sets `pre_filter_events: true`; `.../wait_for_enrichment_service.rb:60-71` counts `EventsEnrichedExpanded` rows, `MAX_ATTEMPTS = 10` (`:18`) | The enriched-store migration waits for expanded rows | The migration can never see new expanded rows and fails after 10 attempts (`:40-47`). |
| DR5 | `app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:9,88-91`; `app/jobs/events/stores/clickhouse/pre_enrichment_check_job.rb:14` | Re-publishes `events_raw` rows with `source_metadata: {api_post_processed: true, reprocess: true}` | Go ignores `reprocess` (`events-processor/models/event.go:25-27`) and writes a normal enriched row; duplicates collapse only via ReplacingMergeTree merges, or `FINAL` at read time for orgs with `clickhouse_deduplication_enabled` (default false; `$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`). Properties come back as strings (Map(String,String)), so `value` changes form (see contract P10/P12). |
| DR6 | `app/services/events/post_process_service.rb:18` `# TODO: update also event-processor to process targeted wallets`; `check_targeted_wallets` `:114-127` | Only Rails PostProcessService (PG-store orgs) sends `target_wallet_code_not_found` webhooks | CH-store orgs get no such webhook; Go's `target_wallet_code` enrichment (`2cf3864`) is gone. |
| DR7 | `app/services/subscriptions/charge_cache_service.rb:5,9,57-68`; `post_process_service.rb:84-92`; flag `feature_flags.yaml:33` | Cache key `charge-usage/<1\|2>/<charge>/<sub>/<charge.updated_at>/<filter>/<filter.updated_at>[/full-usage]`; eager expiry only in PostProcessService (PG orgs, `create_service.rb:38`) and only without `lazy_charge_usage_cache` | After `2fd8e8b`, CH-store orgs without the lazy flag keep serving cached current usage (OD-8). |
| DR8 | `db/clickhouse_migrate/20260727090000_set_events_enriched_at_default_to_now64.rb:4`, `app/models/clickhouse/events_enriched_expanded.rb`, `app/services/events/stores/clickhouse/clean_duplicated_enriched_expanded_service.rb`, `app/services/events/delete_for_metric_service.rb` | Still touch `events_enriched_expanded` | Benign: maintenance on an unfed table. |

One-line re-check of all of the above: `.claude/skills/rails-go-parity/scripts/parity-constants.sh -q`
(rows `DRIFT`, `REPR`, `HIST` stay `KNOWN`/`OK` while this table is true; `CHANGED` means re-read it).
Full grep: `grep -rn "events_enriched_expanded\|ENRICHED_EVENTS_EXPANDED\|reprocess\|pre_filter_events\|lazy_charge_usage_cache" "$API/app" "$API/db/clickhouse_migrate" | grep -v _spec`.

## 4. Rules that follow

1. Before you rely on a Rails behaviour, read it at `$API` (the pin), not at lago-api `main`. If you need a
   newer lago-api to make a Go change safe, that is a cross-repo change: change-control N6, a paired lago-api
   PR because lago-api is the dependent (DECIDED OD-4 (owner, 2026-10-02): paired PRs follow dependencies),
   planned deploy order.
2. Do not "fix" the drift from this repo: no Go code may start producing `events_enriched_expanded` or computing
   Rails cache keys again (change-control N8). The decision belongs to the owner (OD-8) and to lago-api.
3. When the `api` gitlink moves (release bump), re-run `parity-constants.sh` and re-read section 3. Expect
   rows DR1-DR8 to shrink as lago-api deletes the dead paths.
4. To compare against a lago-api that is NOT the pin (e.g. the paired PR branch or lago-api `main`):
   `API2=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api <full 40-hex sha>)` then
   `.claude/skills/rails-go-parity/scripts/parity-constants.sh --api "$API2"` (short shas are refused; resolve
   with `git ls-remote https://github.com/getlago/lago-api <ref>`).
