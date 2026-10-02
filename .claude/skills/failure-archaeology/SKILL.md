---
name: failure-archaeology
description: "Chronicle of every major dead end, rejected fix, revert and fix-after-fix chain in the Lago umbrella repo (chains A-N, X1-X13) from full git history: symptom, root cause, evidence, status, do-not-re-fight rule (chain.sh, hist.sh). Use before editing a file that has a past (\"check its chain\"), when a fix looks obvious, or for \"why is it like this\", \"was this tried before\", \"why was X removed\", a revert or hotfix, ING-15, flat_filters, \"segfault inside franz-go\". Not for current behaviour (use architecture-contract) or an error you see now (use debugging-playbook)."
---

# Failure archaeology

The record of why the code looks the way it does: every costly failure, revert, removal and
fix-after-fix chain, so nobody re-fights a settled battle. It covers the Go `events-processor/` and the
infra around it (single image, workflows, compose, deploy, dev env). It does not describe current
behaviour; it tells you what was already tried and what still bites.
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. `5308258` is the fork head; upstream getlago/lago `main` is `a0de065`
(2026-09-29, 2 commits ahead, gitlinks identical). History facts verified 2026-10-01 in the history
clone made from the fork remote (776 commits, no tags; an upstream clone has 778 commits and 195 tags,
see `research-methodology` §5), unless marked. The scripts always read the history clone.

## When to use / when NOT to use

Use it when:
- you are about to change a file and want its history first (run `scripts/chain.sh --for <path>`);
- a fix looks obvious (it was probably tried: chains A, B, D, F, N);
- someone asks "why", "was this tried", "why was X removed", or cites a sha, PR or ticket (ING-15, ING-123, ING-143, ING-543, INF-366, INF-395);
- you write a PR or ADR and must show prior history (change-control N13);
- you need a failure-specific history query (reverts, fix-after-fix, removals, a path's chains);
  the scripts wrap the full-history clone (the working clone is shallow).

Do NOT use it for:
- how the pipeline behaves today, topics, invariants → `architecture-contract`;
- a live symptom you must triage now → `debugging-playbook` (it cites the stories here);
- change classes, gates, the N1–N13 rules themselves → `change-control`;
- running releases, image matrix, post-release checks → `release-and-images`;
- Rails/ClickHouse parity facts → `rails-go-parity`; env-var meanings → `config-and-flags`;
- fixing the open delivery/value/time defects → `event-accounting-campaign`;
- how to set up the history clone or weigh evidence in general → `research-methodology`.

## Terms

| Term | Meaning here |
|---|---|
| Battle | A recurring failure class that cost real time (several commits or months). |
| Chain | The ordered commits that fought one battle. IDs `A`–`N` = events-processor, `X1`–`X13` = infra. Replay with `chain.sh --named <ID>`. |
| Step | One commit in a chain, with what it tried and why it failed or held. |
| settled | The final fix still holds at HEAD. |
| removed | Resolved by deleting the feature or file. |
| residual | The specific bug is fixed but the same class can recur; current code is cited. |
| open | The defect is live at HEAD. |
| REGRESSION | A commit that introduced a defect fixed later (ledger "kind"). |
| Do-not-re-fight rule | The one-line constraint a chain teaches; breaking it needs the change-control gate. |
| `H` | Path of the full-history bare clone: `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`. |
| Rename-aware pathspec | `-- events-processor events_processor`; the dir was renamed in `d5bce86` (2025-03-21). |
| Pickaxe | `git log -G<regex>` (diff lines matching) or `-S<string>` (count of the string changed). |
| ING-/INF- | Internal ticket ids that appear in commit messages (ingestion / infra). |
| OPEN DECISION OD-n (owner) | An owner call listed in `change-control` §9 (OD-1..OD-20). This skill never settles one; a change that depends on it goes through change-control's gate. Short form `OD-n` in tables. |
| CANDIDATE / UNVERIFIED / inferred | Proposed but unproven / not checked here / read from code shape or a subject line because the commit has no body. |

## Before you change X, check its chain

Run from the repo root (`cd "$(git rev-parse --show-toplevel)"`). `S=.claude/skills/failure-archaeology/scripts`.

1. Find the chains that touched the path (file or directory):
   ```bash
   $S/chain.sh --for events-processor/models/stores.go
   ```
   Expected (2026-10-01): `Primary chains for … (curated index; read these first): G F J`, then the
   chains whose steps touched the path, primary ones marked `*` (`D *F *G H *J M`, e.g.
   `* F … steps: 3a6ed00 4cd30f2 42615c9 fb6401d 02a4bc8`), then the last 10 commits on the path.
   Big commits touch many files, so an unmarked chain may share only one commit with the path.
2. Read the primary chains in `reference/chains.md` (same list as the index below). Replay one:
   `$S/chain.sh --named G`.
3. Compare your plan with the chain's do-not-re-fight rule (table "The battles" below).
   If your change re-introduces something a chain removed or loosens a rule, stop: it is a gated change
   (change-control N7/N8 and its classes C3 behaviour, C4 delivery or cross-repo contract, C5 pins/images, C6 compose/deploy).
4. No curated chain? Read the raw history: `$S/hist.sh --path <path> --reverse` and
   `$S/incidents.sh --followups` (fix-after-fix within 14 days, all files).
5. For a symbol, use the pickaxe and look at the actual lines:
   `$S/chain.sh events-processor/config/kafka/consumer.go 'findMaxCommitableRecord|^[[:space:]]+return$' --show`.
   For one Go function: `$S/chain.sh --func findMaxCommitableRecord events-processor/config/kafka/consumer.go`.
6. Put one line in the PR body: "History checked: chains <IDs> (`chain.sh --for <path>`); not
   re-fighting because …" (change-control N13).

## Path → chain index

Primary chains only; key commits may predate a file move (e.g. `processors/events.go` became
`processors/events_processor/processor.go` in `2408a73`). `chain.sh --for <path>` prints the same
primary list (its `primary()` table, one line per path; keep both in sync, `chain.sh --verify` checks
IDs and paths) and then the full, data-driven list.

| Path (repo-relative) | Primary chains | Key commits | Why it matters |
|---|---|---|---|
| `events-processor/config/kafka/consumer.go` | A, J | `cec0eb2` `600e195` `b6d3616` `9acd83e` | commit path, ING-15 segfault, skip-past residual |
| `events-processor/processors/events_processor/processor.go` | A, J, E | `656c829` `a15bd3b` `d9c32b6` | retry/12 h branch, unparseable commit, errgroup, pay-in-advance gate |
| `events-processor/processors/events_processor/enrichment_service.go` | N, D, E, G | `2fec4db` `b4ad153` `d9c32b6` | `%v` value, removed fan-out, recurring fallback |
| `events-processor/processors/events_processor/event_producer_service.go` | D | `3dae52f` `731e18f` | expanded topic removed; keys `org-transaction_id` |
| `events-processor/processors/main_processor.go` | F, G, H, M | `7421650` `a918f60` `2fd8e8b` | store/producer init, env names, legacy TLS, dead cache env |
| `events-processor/models/subscriptions.go` | B | `bd92069` `9acd83e` | explicit column list (ING-15) |
| `events-processor/models/billable_metrics.go` | B, C | `fff5858` `8ceca4b` | `SELECT *` residual; `deleted_at` |
| `events-processor/models/charges.go` | E, C | `d7ee4c2` `d9c32b6` | `HasPayInAdvanceCharge`, soft delete |
| `events-processor/models/stores.go` | G, F, J | `42615c9` `fb6401d` `02a4bc8` | ZSET contract, per-call ctx, dead `CacheStore` |
| `events-processor/models/event.go`, `utils/time.go` | I | `d7d76be` `76c1b3b` | timestamp formats, `ingested_at` |
| `events-processor/utils/env.go` | M | `27169be` | bool parsing |
| `events-processor/config/redis/redis.go` | H | `69ec50d` `3a6ed00` (env side: `a918f60`) | TLS, `InsecureSkipVerify` |
| `events-processor/config/tracing/` | K | `475761d` `1f2d36e` | provider selection, `TODO: fetch version` |
| `events-processor/cache/`, `extra/debezium_config.json` | C, D | `fff5858` `d9c32b6` | memory cache (stalled, OD-1), dead filter caches |
| `events-processor/{Dockerfile*,go.mod,mise.toml}`, `.github/workflows/events-processor-tests.yml` | L | `07d1d4d` `e8bbd60` `d4e3665` `50015b0` | pins move together (change-control N3) |
| `docker/Dockerfile`, `docker/runner.sh`, `.dockerignore`, `.github/workflows/release-docker-image.yml` | X1 | `18b26d0` `558814a` `f719ef1` | release-day breakages |
| `.github/workflows/docker-build-multi-arch.yaml`, `build-*.yaml`, `release-processors-image.yml` | X7, X8 | `b61044f` `fdfeb91` `5070e24` | rewrites, unused `push`/OIDC inputs |
| `connectors/Dockerfile` | X8 | `6a595fb` `986f29b` | 429s, unpinned base |
| `deploy/` | X3, X9 | `cd9f0fa` `2453945` (root-compose port fix `b1e40bd` not ported here) | installer bugs, `v1.27.1` pins, redis port |
| `docker-compose.yml` | X9, X13, X1 | `1a9bea1` `b1e40bd` `ba292b6` | env defaults, healthchecks, release tags |
| `docker-compose.dev.yml`, `scripts/` | X4, X5, X10, X12 | `c80a7b5` `5477e39` `e5392e9` `4230f1f` | startup order, init scripts, topics, churned services |
| `.env.development.default` | X5, F, M | `84b6eef` `6dd7e56` `3cd78f1` (created as `.env.development.example` in `16c8b68`) | single env source, licence leak (OD-9), cache DB |
| `api`, `front` (gitlinks) | X6 | `12b8101` `647de3e` `7251947` | non-release pointer moves (change-control N1) |
| deleted: `models/flat_filters.go`, `cache/flat_filters.go` | D | `d9c32b6` | removed |
| deleted: `models/charge_cache.go`, `processors/events_processor/cache_service.go` | F | `2fd8e8b` | removed |
| deleted: `.github/workflows/deploy-preview.yml`, `docker-compose.arm64.yml` | X2, X10 | `42d40cd` `81a0df4` | removed |

## The battles

Ordered by cost (see the next section for the numbers). Evidence = commits in the history clone
plus `path:line` at HEAD. Full narratives: `reference/chains.md`.

| # | Battle (chain) | Symptom | Root cause | Evidence | Status | Do-not-re-fight rule |
|---|---|---|---|---|---|---|
| 1 | Kafka commit path (A) | partition goroutine exit and consumer stall (inferred), then skipped commits, then pod segfault inside franz-go | stray `return` (`cec0eb2`); `CommitRecords([nil])` after `b6d3616` | `cec0eb2`→`656c829`→`600e195`→`b604769`→`b6d3616`→`9acd83e` (ING-15) | settled; residual: a later batch commits past a retryable failure, unparseable records get no DLQ (`consumer.go:89-104`, `processor.go:49-59`); fix is OPEN DECISION OD-2 (owner) | no delivery change without a `processRecordsAndCommit` test, design note, owner sign-off (change-control N7). "Commit every record" is the `4100da0` design (every failure DLQ'd) that `cec0eb2` replaced on purpose; today it turns REDELIVERED into LOST (accounting-probe UNACCOUNTED 5 -> 7, `event-accounting-campaign` "Wrong paths") |
| 2 | `flat_filters` per-event resolution (D) | nil panics, shared maps, flaky test, missing org scope, tie-break mismatch, DB load | non-materialized 5-join view queried once per event | 19 commits `3a6ed00`…`d9c32b6` (ING-123, ING-143, ING-543) | removed; dead filter caches still loaded (`cache/cache.go:94-119`) | no per-event charge/filter resolution in Go (change-control N8) |
| 3 | Go expiry of Rails cache keys (F) | stale usage, refill race, wrong key expired, dev cache never expired | Go computed Rails cache keys | `3a6ed00`→`8d61fa7`→`4cd30f2`→`3cd78f1`→`42615c9`→`fb6401d`→`0b56915`→`02a4bc8`→`2fd8e8b` | removed; dead code `models/stores.go:15,75-104` | Go never computes Rails cache keys (change-control N8) |
| 4 | All-in-one image breaks on release day (X1) | release build fails or ships late; tags with no image | image built only at release; Ruby/Node/Bundler drift; distro roll (`14fa1e0`); the `pnpm@latest` / `pnpm prune` step (which pnpm ran: UNVERIFIED) | `023bfe1`, `e07e182`…`92b1af2`, `14fa1e0`→`b6b98c8`, `18b26d0`, `c6abc1e`, `558814a`, `b267320`, `f719ef1`; no `getlago/lago:v1.33.0-v1.33.2` (between `14fa1e0` and `b6b98c8`) or `v1.48.0/v1.49.0/v1.50.0` | each settled; class residual (no PR build; `docker/Dockerfile:12` `pnpm@latest`, inert while lago-front pins `packageManager`) | bump Dockerfile ARGs with the api/front bump (allowed in the bump PR; the guard WARNs G1-release-shape, explain it); run `single-image-pins.sh` before tagging; a release-day failure follows `release-and-images` runbook step 9 (patch release or dispatch from `main`: OPEN DECISION OD-12 (owner)) |
| 5 | 2022 deploy-preview churn (X2) | 42 commits in 50 days, 19 "fix/typo" | workflows developed by pushing to `main` | `4aaa93b`…`42d40cd` | removed | prototype workflows on a branch with `workflow_dispatch` |
| 6 | `deploy.sh` installer (X3) | Light/Production: `check_domain_dns: command not found` | function called before definition (`cd9f0fa`) | fixed `2453945` (#762) after 471 days | settled; other bugs open (`deploy/deploy.sh:58,106,169-191,314-326`) | only an end-to-end run proves an installer; `bash -n` is not enough |
| 7 | `SELECT *` vs cached plans (B) | SQLSTATE 0A000 after every Rails column add | gorm `SELECT *` (`bd92069`) + pgx statement cache | `9acd83e`, `3ac94a2`; `8ceca4b` restored a test pinning `SELECT *` | residual: `models/billable_metrics.go:59-66` (`SELECT *` since `4100da0`) | explicit columns, pinned SQL in sqlmock (change-control N4) |
| 8 | Soft-delete scope lost (C) | deleted billable metrics matched | `gorm.DeletedAt` → `utils.NullTime` in `fff5858` | fixed `8ceca4b` after 18 days | settled; class residual | explicit `deleted_at IS NULL` (N4) |
| 9 | Redis ctx canceled on SIGTERM (J) | every in-flight ZADD failed during rolling restarts | stores kept the process ctx, made cancelable by `b6d3616` | fixed `02a4bc8` after 275 days | settled | side effects use the batch context that `processRecordsAndCommit` creates (`consumer.go:83`), never the process/signal context (change-control N5) |
| 10 | Refresh-flag protocol (G) | refresh before data landed; backdated recurring events not flagged | immediate SADD drain; no recurring fallback | `7421650`→`42615c9`→`fb6401d`→`b4ad153` | settled | ZSET name/bucket/member change only with lago-api, versioned (`_v3`) (change-control N6; paired PR per OPEN DECISION OD-4 (owner), default yes) |
| 11 | Toolchain and lago-expression pins (L) | tests broke, prod build failed, tag not fetched, dev image needed newer Go | floating refs and `@latest` | `07d1d4d`, `d589940`, `5077151`→`e8bbd60`, `d4e3665`, `932c06c`→`50015b0` | settled (review only) | change-control N3 |
| 12 | Submodule pins moved outside releases (X6) | Traefik PR moved api/front pins | `git commit -a` with drifted submodules (inferred) | `12b8101`→`647de3e`; 15 non-release moves since 2025 | instance settled; class residual | change-control N1 |
| 13 | Dev compose startup and init (X4) | random `lago up` failures; `lago_test` never created | missing health conditions; init-script path typo | `c80a7b5`, `5477e39`, `fc70e75`; `2747b04`→`e5392e9` (774 days) | settled (edges match N12: app→`api` edges `service_started`; known exception `redpanda-console → redpanda`) | change-control N12 |
| 14 | One env source of truth (X5) | raw topic name differed per service; licence value in a public file | env duplicated per service; personal env copied | `688e4e7`→`0ca6cdf`→`16c8b68`; `16c8b68`→`6dd7e56` | settled; rotation is OPEN DECISION OD-9 (owner) | one env file; never real secrets in `*.default` (change-control N11, N12) |
| 15 | `%v` value stringification (N) | `"1e+06"`, `"<nil>"` reach `events_enriched` | `fmt.Sprintf("%v", …)` since `4100da0`; `2fec4db` fixed nil for grouped_by only | `enrichment_service.go:114` | open (`event-accounting-campaign` W2; any ClickHouse schema change is OPEN DECISION OD-3 (owner)) | fix the class with a corpus test, not one call site; the value format is a cross-repo contract (C3 + C4, change-control N6; paired lago-api PR per OD-4) |

Also settled, smaller: infinite poll loop (`600e195`→`b604769`, 3 days); offsets before produce
(`a15bd3b`); timestamps (I); Redis TLS (H, residual `InsecureSkipVerify`); Traefik `ws` entrypoint
(`12b8101`); connectors 429s (X8); Redis port healthcheck (X9, deploy residual); PR #800 lost to a
force-push (`5308258`, change-control N2).

## Costliest failures (owner default ranking, verified 2026-10-01)

Ranked by duration and commit count from history. The owner answered "default" to the
costliest-failures question, so this history-derived ranking stands until the owner revises it.

| Rank | Failure | Duration | Commits | Cost signal |
|---|---|---|---|---|
| 1 | Chain A, Kafka commit | 401 days (`cec0eb2` 2025-03-31 → `9acd83e` 2026-05-06); nil-commit window 162 days | 6 on the commit path (incl. hotfix `b604769`) | production segfault (ING-15); frequency and data impact UNVERIFIED |
| 2 | Chain D, `flat_filters` | 466 days (2025-06-09 → 2026-09-18) | 19 touch `FlatFilter`/`flat_filters` lines (pickaxe command in `reference/chains.md` D); 7 saga fixes: `36b1e23 0c46c8a 45b216d 2fec4db 9ef876a 3ac94a2 0b56915` | "the main database load coming from the service"; 2,610 lines deleted |
| 3 | Chain F, Go charge-cache expiry | 462 days (`3a6ed00` 2025-06-09 → `2fd8e8b` 2026-09-14) | 9 steps | wrong key expired (ING-543); dev cache never expired for 136 days |
| 4 | X1, single-image release-day breaks | 2025-02-12 → 2026-09-08 | 10 incidents | v1.35.0, v1.37.0, v1.45.0, v1.53.0 fixed after the bump; `getlago/lago` v1.33.0–v1.33.2 (cause `14fa1e0` trixie base, fixed `b6b98c8`) and v1.48.0–v1.50.0 (cause UNVERIFIED) never published (as of 2026-10-01; list: `release-and-images`); v1.52.1 built from v1.52.0 pins |
| 5 | X2, 2022 deploy-preview churn | 50 days (`4aaa93b` → `42d40cd`) | 42 | abandoned; deploy moved to private lago-deploy |
| 6 | X3, `deploy.sh` broken | 471 days (`cd9f0fa` 2025-05-20 → `2453945` 2026-09-03) | 4 | Light/Production installer unusable; other bugs remain |

Long silent defects worth knowing: `lago_test` never created 774 days (X4, `2747b04`→`e5392e9`);
root-compose Redis healthcheck ignored `REDIS_PORT` 805 days and `deploy/*.yml` still do (X9,
`ed6f687`→`b1e40bd`); Redis ctx canceled on restarts 275 days (J, `b6d3616`→`02a4bc8`); `SELECT *`
on subscriptions 169 days (B, `bd92069`→`9acd83e`).

## Stalled and abandoned work

| Item | Started | State (2026-10-01) | What remains / who owns it |
|---|---|---|---|
| In-memory cache + Debezium CDC (`LAGO_USE_MEMORY_CACHE`) | `fff5858` 2026-04-27 | flag-gated; production use is OPEN DECISION OD-1 (owner) | Debezium column list lacks `charges.pay_in_advance`, `billable_metrics.recurring` (`extra/debezium_config.json`); CDC client ignores the broker list, SASL and TLS and uses a random group per boot (`events-processor/cache/consumer.go:27-34`). Owner: none; hardening is unowned, owner question OPEN DECISION OD-20 (next to OD-1); candidate future campaign (`event-accounting-campaign` excludes it); as-is defects `architecture-contract` WP6-WP10 |
| Pre-aggregation / `events_enriched_expanded` | `3dae52f`, `75b9cbc` | removed `d9c32b6` | lago-api at the pin `591ae90` (2026-09-08) still ships the flag and CH migrations (impact depends on OD-8) |
| `target_wallet_code`, `reprocess` pipeline | `2cf3864`, `6048999` | removed `d9c32b6` | Rails at the pin still sends `reprocess`; Rails TODO for targeted wallets (see `rails-go-parity`) |
| Go charge-cache expiry | `3a6ed00` | removed `2fd8e8b` | dead code `models/stores.go:15,75-104`, `tests/mocked_cache_store.go`, `main_processor.go:40-43` |
| Meilisearch dev stack | `0e5937e` 2026-07-10 | removed `4230f1f` after 53 days | nothing |
| `docker-compose.arm64.yml` | `22a1685` 2022-09-13 | removed `81a0df4` after 219 days, 38 commits | nothing |
| Preview-deploy workflows | `4aaa93b` 2022-03-21 | removed `42d40cd` | private repo |
| `connectors-push-main.yml` | `76159bd` | replaced by `2146a18`, authored 13 min later; both landed on main together (committer 2026-08-25 10:59), so it never ran alone | nothing |
| Duplicate `release-processor-image.yaml` | `6ff3a2f` | removed 3 min later (`ca4a4fb`) | nothing |
| Reusable workflow `push` input | `b61044f` | removed `fdfeb91`, re-added `5070e24` | no in-repo caller uses `push: false` |
| OIDC `role-to-assume` | `5ee8e98` | unused | callers still pass long-lived keys (see `security-and-supply-chain`) |
| `docker/redis.conf` | `52ab3b3` | unused since `9eb8c3b` | `docker/runner.sh:40` still edits the stock config |
| `deploy/*.yml` image pins | `cd9f0fa` 2025-05-20 | stuck at `getlago/api:v1.27.1` | releases never bump `deploy/` (see `release-and-images`) |
| `LAGO_LICENSE_URL` | `16eb537` | removed `a41c6dc` after 16 days | nothing |
| GraphQL codegen split | `15961be` | reverted `84013d6` next day | nothing |
| `TODO: Improve this by using channels…` | `4100da0` | 569 days old, obsolete: `processEvent` waits for its producers (`defer errgroup.Wait()`, `processor.go:100-101`, since `a15bd3b`), so the 50 ms sleeps it guards are unneeded (inferred) | `processor_test.go:415,469` |
| `TODO: fetch version` | `475761d` | 308 days old | `config/tracing/tracer.go:115` |
| `# TODO: Use only LAGO_DOMAIN` | `8a6ce39` | 558 days old | `deploy/docker-compose.light.yml:21` |

TODO ages come from `$S/incidents.sh --todos` (relative to the day you run it).

## How to mine history (this skill's gotchas only)

Setup and the generic recipes (shallow-clone trap, `history-setup.sh`, rename-aware pathspec, pickaxe
`-S`/`-G`, `--follow`, `-L`, tags via `tag-map.sh`, upstream vs fork clone) live in
`research-methodology` §5. This skill's scripts wrap them: `$S/hist.sh` (rename-aware log with
scopes), `$S/chain.sh` (curated chains, path lookup, pickaxe), `$S/incidents.sh` (failure sweeps).

Gotchas specific to failure archaeology:
- For `git show <sha>:<path>` or `ls-tree` on commits before `d5bce86` (2025-03-21) spell the old
  directory: `git -C "$H" show 4100da0:events_processor/config/kafka/consumer.go` works, the
  `events-processor/` spelling fails with `fatal: path … does not exist in '4100da0'`. Chain A and B
  step 1 can only be checked this way.
- Subjects lie: `9e8edc0` says v1.41.3 but sets api v1.41.2; `449bf5b` "Bump version to 7" is Redis;
  `0ca6cdf` "Fix dev events_raw topic" introduced the mismatch. Read the diff and the body
  (`git -C "$H" show -s --format=%B <sha>`; the best bodies are `9acd83e`, `02a4bc8`, `d9c32b6`).
- No `git revert` exists under events-processor; removals were forward commits (`d9c32b6`, `2fd8e8b`).
  Search removals with `incidents.sh --removed`, not with `--grep=revert`.
- Release bumps and dependabot dominate raw counts: use `hist.sh --humans --no-bumps`
  (`$S/hist.sh --humans --no-bumps --count` → 448 of 776). `--no-bumps` drops release-version bumps
  only; toolchain bumps (Ruby, Node, Go, lago-expression, ClickHouse) stay visible.
- "N minutes later" claims use committer dates (`%cd`): `76159bd` and `2146a18` were authored 13 min
  apart but landed together.
- The scripts pass `-c gc.auto=0 -c maintenance.auto=false`, so lazy blob fetches never repack the
  clone in the background; `chain.sh --follow` reverses in awk because `git log --follow --reverse`
  prints one commit.

Compose dependency audit (X4; no Docker daemon needed). Expected state per change-control N12: infra
edges `service_healthy`, one-shot jobs `service_completed_successfully`, app→`api` edges
`service_started` (explicit, or the bare `front → api` list), known exception `redpanda-console →
redpanda`:
```bash
python3 -c "import yaml,collections;d=yaml.safe_load(open('docker-compose.dev.yml'));print(collections.Counter(v.get('condition') for s in d['services'].values() if isinstance(s.get('depends_on'),dict) for v in s['depends_on'].values()), [(n,s['depends_on']) for n,s in d['services'].items() if isinstance(s.get('depends_on'),list)])"
```
→ `Counter({'service_healthy': 20, 'service_started': 10, 'service_completed_successfully': 2}) [('front', ['api']), ('redpanda-console', ['redpanda'])]`
(as of 2026-10-01; the 10 `service_started` edges all point at `api`). A new bare list or a new
`service_started` edge on an infra dependency is a regression of X4.

## Scripts

All read-only; they resolve `H` through `history-setup.sh` (or `$LAGO_HISTORY`). Exit codes: 0 ok,
1 (`chain.sh --verify`/`--named`) missing step or unknown ID, 2 usage (unknown option or missing
value), 3 history clone unavailable. In the table, `\|` is a markdown escape: type a plain `|`.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/hist.sh` | rename-aware `git log` with scopes and filters | `$S/hist.sh --ep --humans --count` | `79` (`--ep --count` → `96`; `--infra --count` → `599`) |
| | | `$S/hist.sh --path events-processor/config/kafka/consumer.go --reverse` | 11 lines, `4100da0 … feat(events): Add events post-processor (#474)` first, `9acd83e` last |
| | | `$S/hist.sh --infra --humans --no-bumps --count` | `386` (infra commits without dependabot and release bumps) |
| `scripts/incidents.sh` | failure sweeps: `--list`, `--reverts`, `--tickets`, `--followups [N]`, `--removed`, `--todos` | `$S/incidents.sh --reverts` | 4 lines: `b604769` HOTFIX, `647de3e` REVERT, `84013d6` REVERT, `1a9bea1` HOTFIX |
| | | `$S/incidents.sh --infra --list` | 119 lines (the candidate list behind `reference/infra-ledger.md`) |
| | | `$S/incidents.sh --ep --followups` | 14 pairs (28 lines), e.g. `b604769 … <- 600e195 … (2.7 d …)`, `3ac94a2 … <- 9ef876a` |
| | | `$S/incidents.sh --tickets` | 10 lines: INF-366 ×4, INF-395 ×2, ING-123, ING-143, ING-15, ING-543 |
| `scripts/chain.sh` | replay curated chains, path lookup, pickaxe | `$S/chain.sh --named A` | 7 steps `4100da0 cec0eb2 656c829 600e195 b604769 b6d3616 9acd83e`, each with its role |
| | | `$S/chain.sh events-processor/config/kafka/consumer.go 'findMaxCommitableRecord\|commitableRecords\|CommitRecords\|^[[:space:]]+return$'` | `4100da0 cec0eb2 600e195 b604769 b6d3616 9acd83e` (chain A rebuilt from diffs alone) |
| | | `$S/chain.sh --verify` | `OK` for 27 chains, `OK   primary index (44 paths)`, `verified 161 steps`, exit 0 |
| | | `$S/chain.sh --for docker/Dockerfile` | `Primary chains for docker/Dockerfile (curated index; read these first): X1`, then `* X1 … steps: 52ab3b3 e07e182 d0099a9 9eb8c3b 14fa1e0 b6b98c8 18b26d0 57508c2 558814a b267320 f719ef1` |
| `scripts/_lib.sh` | shared helpers (sourced, not run) | – | executing it prints a hint and exits 2 |

Add a step or a chain by editing the `chains()` heredoc in `chain.sh` (`#ID|title|status` opens a chain,
`ID|sha|role` adds a step); a new primary path goes in its `primary()` heredoc (`path|IDs`) and in the
"Path → chain index" above. Then run `chain.sh --verify` and update `reference/chains.md`.

## Reference files

- `reference/chains.md`: read when a chain is relevant; every step narrated (tried / failed / held / residual / rule).
- `reference/events-processor-ledger.md`: read when you need the row for one events-processor commit; all 79 non-dependabot commits.
- `reference/infra-ledger.md`: read for release, CI, deploy, dev-env or hygiene incidents; every fix/revert/removal outside events-processor.

## Provenance and maintenance

Sources: the full history clone (`history-setup.sh`), commit bodies of `9acd83e`, `02a4bc8`, `d9c32b6`,
`5308258`, `18b26d0`, `e5392e9`, `c80a7b5`, `986f29b`, `2146a18`, `4955f79`, `5070e24`; code at HEAD
(`events-processor/…`, `docker/…`, `deploy/…`, compose files); pinned lago-api via
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`; Docker Hub tag API.

Volatile facts, one re-verification command each (as of 2026-10-01):
- Total history 776 commits (clone from the fork remote, HEAD `5308258`): `git -C "$H" rev-list --count HEAD` → `776`.
- EP human commits 79 of 96: `$S/hist.sh --ep --humans --count` → `79`.
- Curated chains and primary index resolve: `$S/chain.sh --verify` → `OK   primary index (44 paths)`, `verified 161 steps`, exit 0.
- Chain A rebuilt from diffs: see the `chain.sh <path> '<regex>'` row above → 6 shas ending `9acd83e`. `656c829` (processor.go, unparseable records) also belongs to chain A (`chain.sh --named A` lists it) but the consumer.go regex does not pick it up.
- `SELECT *` residual: `grep -n 'Connection.First' events-processor/models/billable_metrics.go` → line 61.
- `%v` residual: `grep -n 'Sprintf("%v"' events-processor/processors/events_processor/enrichment_service.go` → line 114.
- Skip-commit branch: `grep -n 'record, ok := findMaxCommitableRecord' events-processor/config/kafka/consumer.go` → line 94.
- Dead cache code: `grep -n 'func (store \*CacheStore) ExpireKey' events-processor/models/stores.go` → line 96.
- `pnpm@latest`: `grep -n 'pnpm@latest' docker/Dockerfile` → line 12.
- deploy pins: `grep -c 'getlago/api:v1.27.1' deploy/docker-compose.*.yml` → 1 per file.
- Missing images: `curl -s https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.33.0 | grep -o 'httperror 404'` → `httperror 404` (same for `v1.33.1`, `v1.33.2`, `v1.48.0`, `v1.49.0`, `v1.50.0`; `v1.33.3` and `v1.48.1` return a `last_updated`). Full artifact matrix: `release-and-images`.
- Non-release pin moves: `git -C "$H" log --since=2025-01-01 --no-merges --format='%h %s' -- api front | grep -viE 'bump|release|version|v1\.[0-9]' | wc -l` → `15` (one of them, `b6bb37d`, is a release; add `7251947`, which the `version` filter hides; the corrective `f145388` and `647de3e` are not counted).
- Bump filter: `$S/hist.sh --humans --no-bumps --count` → `448`; `$S/hist.sh --infra --humans --no-bumps --count` → `386`.

Update triggers: any commit that fixes, reverts or removes something (add a ledger row and, if it
continues a chain, a `chain.sh` step); a new ING-/INF- ticket in a message (`incidents.sh --tickets`);
a release whose image build needed a follow-up commit; owner answers to OD-1, OD-2, OD-3, OD-8, OD-9,
OD-10, OD-20; `history-setup.sh --refresh` bringing new upstream commits (the clone then moves past
`5308258`; re-run the counts above).
