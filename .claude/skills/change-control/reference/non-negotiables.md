# Non-negotiables N1–N13: rule, why, incident, cost, check

Read this when a gate fails, when someone asks "why is this rule here", or before you propose
an exception. Code facts as of `5308258` (events-processor tree `83e012866f29`); the working
branch may carry skills-only commits on top. Every sha below was read in the full-history clone on 2026-10-01
(`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`; `git -C "$H" show <sha>`).
Dates are commit dates. "Body" means the commit message body. Where the message has no body,
the cause is marked INFERRED or UNVERIFIED. The full narratives live in `failure-archaeology`.
Other skills cite these rules as "change-control N#".

## N1. Never stage or commit an `api`/`front` gitlink move outside a release bump

- **Rule.** Only a release bump PR moves the `api` and `front` gitlinks (mode 160000 entries).
  Before every commit, run
  `git diff --cached --submodule=short --ignore-submodules=none -- api front`.
  Empty output is the pass condition.
- **Why.** `release-docker-image.yml:28-30` checks out with `submodules: true`. Whatever the
  gitlinks point at when a tag is cut is baked into `getlago/lago`. A feature PR that drags a
  pin therefore ships untagged api/front code in the next release.
- **Incidents.**
  - `12b8101` (#618, 2025-11-04 13:03): a Traefik label fix also moved api `2bd2d77 -> 225a41b`
    and front `812ea3c -> 8eb46bb`.
  - `647de3e` (#620, same day 16:18) reverted the pins. The body says the earlier commit
    "updated the `api` and `front` submodules by mistake".
  - `190aa81` (#596, 2025-09-18) moved front from `0a37bcf` (lago-front v1.33.4) back to
    `5a9f1a7` (v1.33.2). That is a downgrade, hidden in a connectors feature.
    Tags were mapped with `git ls-remote --tags https://github.com/getlago/lago-front`.
  - Older case: `0ca6cdf` (#424, 2024-11-04), titled "Fix dev events_raw topic" (it introduced
    a per-service topic mismatch, N12), also moved the api pin.
- **What it cost.**
  - The `12b8101` mistake took a second PR and a second review the same day.
  - The class keeps coming back. From 2025-01-01 to 2026-10-01, 77 commits moved a pin:
    - 60 were release bumps;
    - 2 were deliberate corrections (`f145388` "version should reflect tag", and `647de3e`);
    - **15 were non-release moves**: `4100da0 d1c1629 8a6ce39 7421650 6a1c26d cd9f0fa 3a94e3d 6ff3a2f ca4a4fb 190aa81 09a5cc7 12b8101 75b9cbc fff5858 7251947`.
  - Recount: `git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front`, then drop
    the release bumps.
- **Mechanism (verified in a scratch clone, git 2.43, 2026-10-01).**
  - A populated `api/` checked out at another commit shows as ` M api`.
  - `git add -A`, `git add -u` and `git commit -a` all stage it.
  - `diff.ignoreSubmodules=all` or `submodule.api.ignore=all` HIDE the ` M api` drift from
    `git status` and HIDE a staged move from `git diff --cached` (with or without
    `--submodule`/`--stat`). `git status` still lists a staged move as `M  api`.
    Neither setting stops `git add -A`/`git add -u` from staging the move. (`git commit -a`
    skipped it under `diff.ignoreSubmodules=all` but staged it under
    `submodule.api.ignore=all`.) This is why every check here passes `--ignore-submodules=none`.
- **Doc conflict.** `docs/dev_environment.md:266-278` ("Updating a reference") tells you to move
  the pointer and `git push origin main`. Do not follow it. It contradicts N1, and in practice
  every pointer update since 2025 went through a PR. `docs-and-writing` tracks the correction.
- **Check.** `scripts/precommit-guard.sh` (rule G1-gitlink). For a PR, run
  `scripts/precommit-guard.sh --range "$(git merge-base origin/main HEAD)..HEAD"`.

## N2. Never force-push a branch with an open PR, or `main`; never rewrite shared history

- **Rule.**
  - Fix forward with new commits; squash-merge collapses them anyway.
  - `git push --force-with-lease` is acceptable only on a branch that has no PR and no other
    user.
- **Incident.** `5308258` (2026-09-18) is the current project HEAD. Its body says PR #800's
  branch "was force-pushed onto main before being closed, so it holds no changes and GitHub
  will not reopen it", and "the original is unrecoverable".
- **What it cost.**
  - The PR, its history and its review were lost.
  - The work was rebuilt from a copy in the private `lago-deploy#3331`.
  - The same body contrasts it with `lago-front#4318`: "Unlike lago-front#4318 no review was
    pinned to the pre-push commit, so the original is unrecoverable". INFERRED: a review
    pinned to the pre-push commit is what kept the lago-front case recoverable.
- **Check.** No local tool can see GitHub PR state. Before any `--force*` push, run
  `git ls-remote origin "refs/heads/$(git branch --show-current)"`. Then confirm on GitHub that
  no PR is open from this branch. Branch protection on `main` is UNVERIFIED from here.

## N3. Toolchain and dependency pins move together; nothing floats

- **Rule.**
  - **lago-expression ref, 4 places:** `events-processor/Dockerfile:5`, `Dockerfile.dev:5`,
    `Dockerfile.staging:23` (`ARG LAGO_EXPRESSION_REF`) and
    `.github/workflows/events-processor-tests.yml:45`.
  - **Rust image, 2 places:** `events-processor/Dockerfile:1` and `Dockerfile.dev:1`. It must be
    new enough for that ref.
  - **Go major.minor, 5 places:** `go.mod:3`, `mise.toml:2`, `Dockerfile:7`, `Dockerfile.dev:7`
    and the CI file at `:61`.
  - **No floating tools:** no `@latest` in any Dockerfile, workflow or script. Base images move
    only at major.minor, together; patch drift is the accepted residual below.
  - **Do NOT "fix" `go.mod:10`** `expression-go v0.1.4`. No `expression-go/v0.2.0` tag exists
    (`git ls-remote --tags https://github.com/getlago/lago-expression`), and the wrapper is
    unchanged: between tags `expression-go/v0.1.4` and `v0.2.0` the only change under
    `expression-go/` is one line of `expression-go/Cargo.toml` (shallow fetch of both tags,
    `git diff --stat`, 2026-10-01). `build-and-env` documents this.
- **Residual (as of 2026-10-01).**
  - `docker/Dockerfile:12` still runs `corepack prepare pnpm@latest`. The v1.35.0 build failed
    in the `corepack prepare pnpm@latest` / `pnpm prune` step (`18b26d0`, #617); which pnpm ran
    is UNVERIFIED. lago-front pins `packageManager` to a pnpm version, which makes `pnpm@latest`
    inert today; it stays a conditional risk if lago-front drops `packageManager`.
  - Base images float at patch level: `golang:1.25` (the same digest as `golang:1.25.14` on
    Docker Hub, as of 2026-10-01), `rust:1.85`, `debian:13-slim`. The shipped binary is built
    with Go 1.25.14 while CI (`.github/workflows/events-processor-tests.yml:61`) and
    `GOTOOLCHAIN` test 1.25.0. The pin set (PS2/PS3) is checked at the spelled value only.
    Digest pins are a CANDIDATE (`security-and-supply-chain`, C5 + C7).
  - `events-processor/Dockerfile.staging:12-13` default to `:latest` base images
    (`precommit-guard.sh --commit 5308258` WARNs G3-latest-image on both).
  - `pin-sync-check.sh` PS5 covers only the events-processor Dockerfiles, and guard G3 flags
    only *added* lines, so neither reports these pre-existing cases.
- **Incidents and cost.**
  - `07d1d4d` (#487, 2025-03-14, no body):
    - lago-expression was cloned at HEAD in CI and both Dockerfiles. This commit pinned
      `v0.1.4` in all three.
    - It also moved `Dockerfile.dev` to `rust:1.85` but left `Dockerfile` on `rust:1.82`.
    - Replaying `pin-sync-check.sh --rev` shows that Rust mismatch latent from `07d1d4d` until
      `e8bbd60`, almost 10 months.
  - `5077151` (#666, 2026-01-02 15:02) bumped lago-expression to v0.2.0 in all 3 places that
    existed then (`Dockerfile.staging` only arrived in `5308258`), but left the prod
    `Dockerfile` on `rust:1.82`. `e8bbd60` (#667, "Fix prod release", 16:23) moved
    `Dockerfile` to `rust:1.85` 81 minutes later. The exact build error is UNVERIFIED (no
    body). `pin-sync-check.sh --rev 5077151` FAILs on PS2.
  - `d4e3665` (2026-01-08, no PR number, no body) added `git clone --tags`. INFERRED cause: a
    cached clone layer that predated the new tag.
  - `d589940` (#586, 2025-09-10): `air@latest` started requiring Go >= 1.25, and the dev
    container build failed. The error is quoted in the body. Fixed by pinning `dlv@v1.25` and
    `air@v1.62`.
  - `932c06c` (#724, dependabot, 2026-04-09 09:29) moved `go.mod` to `go 1.25.0` because of an
    otel bump. `50015b0` (#725, 10:19) realigned the two Dockerfiles and CI 50 minutes later.
    `pin-sync-check.sh --rev 50015b0^` FAILs on PS3.
- **Check.** `scripts/pin-sync-check.sh` checks the working tree. Use `--index` for staged
  changes and `--rev <sha>` for history. `precommit-guard.sh` runs it automatically whenever a
  pin file is touched.

## N4. events-processor SQL: explicit columns, `deleted_at IS NULL`, `organization_id`; pin the SQL in sqlmock

- **Rule.**
  - Every query against a Rails-owned table or view selects an explicit column list.
    `Select(schema.DBNames)` or `StreamQueryConfig.SelectFields` both work.
  - Every query filters `deleted_at IS NULL` on soft-deletable (Discard) tables.
  - Every query filters `organization_id`.
  - The sqlmock test pins the exact SQL text, anchored (`"^" + regexp.QuoteMeta(sql) + "$"`):
    the default matcher is an unanchored regexp, so a bare QuoteMeta pin is a "contains" pin.
- **Incidents.**
  - `bd92069` (#634, 2025-11-18) removed a customers join. GORM then emitted `SELECT *` for
    `FetchSubscription`.
  - `9acd83e` (#735, 2026-05-06, Refs ING-15). Body: "any DDL on the subscriptions table (the
    routine column-add migrations the API ships) invalidated every cached prepared plan with
    SQLSTATE 0A000". Exposure was about 5.5 months.
  - `3ac94a2` (#741, ING-143, 2026-05-21) applied the same fix to the `flat_filters` view.
  - `fff5858` (#639, 2026-04-27) swapped `gorm.DeletedAt` for `utils.NullTime`. That silently
    dropped GORM's soft-delete scope, so deleted billable metrics matched.
  - `8ceca4b` (#740, 2026-05-15) added explicit `deleted_at IS NULL` and restored the 101-line
    test file `fff5858` had deleted (it still pins `SELECT * FROM "billable_metrics"`). The bug
    sat on main for 18 days.
  - `9ef876a` (#738, ING-123, 2026-05-18, no body) added the missing `organization_id` to
    `FetchFlatFilters`. Whether that was a tenant leak or a performance issue is
    UNVERIFIED: OPEN DECISION OD-9 (owner).
- **Residual (as of 2026-10-01).**
  - `FetchBillableMetric` still uses gorm `First` with an implicit `SELECT *`
    (`events-processor/models/billable_metrics.go:59-66`).
  - Its tests pin that form: `models/billable_metrics_test.go:15` and
    `processors/events_processor/processor_test.go:91`.
  - `HasPayInAdvanceCharge` (`events-processor/models/charges.go:47-66`) has no exact sqlmock pin,
    only the wildcard `".* FROM \"charges\".*"` (`processors/events_processor/processor_test.go:108`).
    A PR touching it adds an anchored QuoteMeta pin.
- **Cross-repo corollary.** Explicit column lists mean a Rails column **drop** breaks Go. Follow
  the two-release drop rule in `$API/docs/dropping_columns_and_tables.md`: remove the column
  from the Go struct or select list in release N, before Rails drops it in N+1. See
  `reference/cross-repo-protocol.md`.
- **Check.** `grep -nE '\b(First|Find|Take|Last)\(' events-processor/models/*.go | grep -v _test`
  prints `billable_metrics.go:61` (no `Select`, the residual), plus `charges.go:60` and
  `subscriptions.go:42`. The last two are preceded by `Select(...)` at `:52` and `:37`.
  `architecture-contract` ships a fuller invariants grep.

## N5. Per-record side effects never use the process (signal-cancelled) context

- **Rule.** Per-record side effects (Redis, produce) use the batch context that
  `processRecordsAndCommit` creates (`context.Background()`,
  `events-processor/config/kafka/consumer.go:83`) and passes to every record, never the
  process/signal context that SIGTERM cancels. There is no per-record derived context. The
  process context is only for startup and connection setup.
- **Incident.**
  - `b6d3616` (#608, 2025-11-25) introduced a cancelable process context for graceful
    shutdown. The stores captured it at construction.
  - `02a4bc8` (#785, 2026-08-27). Body: "every Redis write still in flight during a rolling
    restart failed with `context canceled`".
- **What it cost.** About 9 months of failed refresh flags on every rolling restart. The record
  then fails as `flag_subscription_refresh` (`processor.go:128-131`), so it is retried or
  sent to the DLQ.
- **Check.** `grep -rnE '^\s+[A-Za-z_]+\s+context\.Context\s*$' events-processor --include=*.go`
  finds struct fields that hold a context.
  - Today it prints 6 lines: 4 in `config/tracing` (span contexts) and 2 in `cache/cache.go`
    (the cache lifecycle).
  - Any new hit in a type that does per-record I/O is a review blocker.
  - Before `02a4bc8` the same grep hit `models/stores.go` twice.

## N6. Cross-repo contracts change only together with their external dependents, versioned, with a deploy order

- **Rule.**
  - These contracts (K1-K10, `cross-repo-protocol.md` §1) change only together with every
    external dependent they have:
    - Redis ZSET `subscription_refreshed_v2` (name, member `<org>:<sub>|<bucket>`, 10 s bucket);
    - Kafka topic names and consumer-group naming;
    - the raw, enriched, in-advance and DLQ payload schemas;
    - the `value` string format;
    - the `api_post_processed` split;
    - the Debezium column list.
  - Any format change uses a **new versioned name**.
  - Paired PRs are dependency-driven (DECIDED OD-4 (owner, 2026-10-02)): one in every other repo
    whose listed dependent reads or writes the changed part (lago-api, lago-front,
    lago-helm-charts or a deploy repo). If none does, no paired PR; the PR says so and cites the
    K row. Most rows have lago-api dependents, so most format changes still need one.
  - Whenever a dependent exists, the PR states the deploy order and the rollback (DECIDED OD-4).
- **Incident chain.**
  - `7421650` (#500, 2025-04-07): a Redis SET `subscription_refreshed` (SADD).
  - `42615c9` (#720, 2026-03-27): changed to a ZSET with time buckets **and** renamed it
    `subscription_refreshed_v2`. This is the versioned-key pattern: a reader of the old name
    never meets the new type.
  - `fb6401d` (#729, 2026-04-20): bucket 15 s -> 10 s. Rails must hold the same constant:
    `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14`.
  - `b4ad153` (#768, 2026-07-27, no body): for recurring billable metrics, when no
    subscription is active at the event timestamp, fall back to the currently active one, so
    past recurring events still flag a refresh. That it was done for Rails parity is INFERRED.
- **What it cost.**
  - Four protocol changes in 15 months on a contract that is enforced only by convention.
  - The two sides already disagree in prose. The Rails comment (`:11`) says the score is "the
    event timestamp", while Go writes wall-clock time (`events-processor/models/stores.go:55-61`).
  - Whether each change had a paired lago-api PR is UNVERIFIED: the pinned lago-api checkout
    is depth 1.
- **Check.** `reference/cross-repo-protocol.md` has the contract inventory with both-side
  anchors. `rails-go-parity` ships the parity constants check.

## N7. No change to Kafka commit or delivery semantics without test + ADR-001 conformance + owner sign-off

- **Rule.** A change to commit, retry, DLQ or skip behaviour needs all three of:
  - (a) a test that drives `processRecordsAndCommit` through an in-process Kafka (the kfake
    harness from `diagnostics-and-tooling`), plus one
    `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path` run.
    The in-repo test adds kfake to `events-processor/go.mod` (absent today), so the PR is also
    C5: run `pin-sync-check.sh`; the kfake version pin is in `diagnostics-and-tooling`;
  - (b) conformance to ADR-001, the accepted delivery contract (DECIDED OD-2 (owner,
    2026-10-02), delegated; `event-accounting-campaign` `reference/delivery-options.md`): the
    PR references ADR-001 and names the points it implements (template in `docs-and-writing`);
  - (c) owner sign-off, as for every C4. A deviation from ADR-001 needs an owner decision (an
    ADR-001 amendment) before merge (DECIDED OD-2).
- **Incident chain.** It took 13 months and ended in a production segfault.
  - `cec0eb2` (#502, 2025-03-31) added retry semantics and `findMaxCommitableRecord`, with a
    stray `return` in the consume loop. "Commit every record" was the `4100da0` origin design
    (every failure DLQ'd), which `cec0eb2` replaced on purpose; going back to it today turns
    REDELIVERED into LOST (accounting-probe UNACCOUNTED 5 -> 7, `event-accounting-campaign`).
  - `656c829` (#511, 2025-04-10) counted unparseable records as processed: committed, Sentry
    only, no DLQ.
  - `600e195` (#628, 2025-11-07) extracted `processRecordsAndCommit`. The `return` now skipped
    the commit instead, and `poll()` looped forever after client close.
  - `b604769` (#629, 2025-11-10) hotfixed that infinite poll loop 3 days later.
  - `b6d3616` (#608, 2025-11-25) removed the `return`. A nil record could now reach
    `CommitRecords`.
  - `9acd83e` (#735, 2026-05-06, Refs ING-15). Body: "segfaulting the pod inside franz-go".
- **Residual.**
  - A retryable failure is skipped for good when a later batch on the same partition commits.
    See `events-processor/config/kafka/consumer.go:89-104`; the comment there says "re-polled
    after the next rebalance".
  - No test calls `processRecordsAndCommit` or `ProcessEvents`.
    `grep -rn "processRecordsAndCommit\|ProcessEvents(" --include=*_test.go events-processor`
    prints nothing.
  - The fix campaign is `event-accounting-campaign`; its target contract is ADR-001 (commit
    offset N only when every record <= N has a durable disposition), DECIDED OD-2.
- **Check.** If the diff touches `config/kafka/consumer.go` or the disposition branches of
  `processors/events_processor/processor.go:50-88`, it is C4 (see `change-classes.md`), unless
  it is an observability-only edit under the precedence rule (`change-classes.md` §1 step 6:
  no control-flow change, scoreboard `moved=0`), which is C3.

## N8. Go never re-implements Rails business resolution per event

- **Rule.**
  - Go does no per-event charge or charge-filter resolution.
  - Go computes no Rails cache keys.
  - Bringing either back needs a written parity spec, a parity test, and owner sign-off.
- **Incidents.**
  - The `flat_filters` saga ran about 15 months. It started with `3a6ed00` (#542, 2025-06-09)
    and needed these fixes:
    - `36b1e23` (#574): nil panic;
    - `0c46c8a` (#575): shared map;
    - `45b216d` (#603): flaky order;
    - `2fec4db` (#710);
    - `9ef876a` (#738, ING-123);
    - `3ac94a2` (#741, ING-143);
    - `0b56915` (#774, ING-543): "Select the same charge filter as Rails".
  - `d9c32b6` (#797, 2026-09-18) removed it all, 2,610 deleted lines. Body: the per-event view
    query was "the main database load coming from the service".
  - The Go charge-cache expiry ran `3a6ed00 -> 8d61fa7 -> 4cd30f2 -> 42615c9 -> fb6401d -> 0b56915`
    and was removed in `2fd8e8b` (#766, 2026-09-14, no body).
- **Check.** The reviewer refuses new Go code that reads `charge_filters`, `charge_filter_values`
  or a filters view per event, or that builds `charge-usage/...` style keys. Parity questions go
  to `rails-go-parity`.

## N9. events-processor pre-PR gate: tests, -race, vet, gofmt, no new lint; paste the evidence

- **Rule.**
  - `ep-test.sh` full suite green; the PASS count does not drop below the baseline (235).
  - `ep-test.sh -race -count=1 ./...` ok. This is the unit suite, which never runs
    `processRecordsAndCommit`; real-pipeline race evidence for C4 is the kfake run (N7).
  - `go vet ./...` clean.
  - `gofmt -l` prints nothing on changed files.
  - golangci-lint shows no new issues against the base. The baseline is 21: errcheck 16,
    staticcheck 5, golangci-lint v2.5.0, no config file. Policy: OPEN DECISION OD-6 (owner).
  - Paste the output in the PR.
- **Why.** CI (`.github/workflows/events-processor-tests.yml:63-64`) runs only `go test -v ./...`.
  It has no vet, lint, `-race`, gofmt or coverage step. Local gates are the only gates.
- **Check.** The one canonical block (numbered commands, expected outputs, `BASE` and its
  shallow-clone fallback) is "Pre-PR gate for events-processor code" in SKILL.md §3.

## N10. Probes and experiments never write into the repo

- **Rule.** Use `go test -overlay`, scratch copies, throwaway databases, `$LAGO_SKILLS_CACHE` or
  `$TMPDIR`. Build outputs go to a temp dir.
- **Why.** The repo is the record. The README's `go build -o event_processors .`
  (`events-processor/README.md:13`) writes a 58 MB binary that `events-processor/.gitignore:24`
  does not ignore. That file only ignores the default name `events-processor`.
- **Check.** `git status --porcelain` must show only your intended paths.
  `precommit-guard.sh` G4 refuses ELF binaries, `event_processors`, `*.so` and `*.out`.

## N11. No real secrets in `*.default`, `*.example`, compose, docs or skills; never print a historical value

- **Rule.** Placeholders only: `${VAR}`, `changeme`, `***`. Never echo, grep-print or paste a
  value from history. Report counts and shas only.
- **Incident.**
  - `16c8b68` (2025-01-23, branch `feat/improv-dev-env`) added a non-empty `LAGO_LICENSE` value
    to `.env.development.example`.
  - `84b6eef` renamed that file to `.env.development.default` 32 minutes later.
  - Merge `0a67ac0` (#455, 2025-01-29) brought it to `main`; `6dd7e56` (#477, 2025-03-07)
    "remove unintended lago license key" blanked it: 37 days on `main` (up to 43 days if the
    branch was public from 2025-01-23: UNVERIFIED). It is still in history.
  - Whether it was rotated is UNVERIFIED: OPEN DECISION OD-9 (owner).
- **Check.**
  - `precommit-guard.sh` G2 prints file:line only.
  - History, counts only:
    `git -C "$H" log -G'^LAGO_LICENSE=.' --format='%h %ad %s' --date=short -- .env.development.default .env.development.example`
    prints 2 lines (`6dd7e56`, `16c8b68`).
  - Wider scans live in `security-and-supply-chain`.

## N12. One env source of truth for dev; idempotent topic creation; healthy infra edges

- **Rule.**
  - **One env file.** Dev env lives in `.env.development.default`. Local overrides go in the
    gitignored `.env.development` (`docs/dev_environment.md:152-156`). Never copy env per
    service.
  - **Idempotent topics.** Topic creation stays idempotent. New topics go in the
    `redpandacreatetopics` `command:` list (`docker-compose.dev.yml:398-405`), which
    `scripts/create-topics.sh` creates only if missing.
  - **Healthy infra edges.**
    - Every edge to an infrastructure service (db, redis, redis-replica, redpanda, clickhouse)
      uses `condition: service_healthy`.
    - Edges to one-shot jobs (`migrate`, `redpandacreatetopics`) use
      `service_completed_successfully`.
    - Edges to `api` use `service_started` (11 such edges today, one in short form). This is
      settled, not a residual.
    - Known exception: `redpanda-console -> redpanda`, short form (`docker-compose.dev.yml:426-427`).
- **Incidents.**
  - `0ca6cdf` (#424, 2024-11-04) INTRODUCED a raw-topic mismatch: only `api-worker` got
    `events_raw`, every other service kept `events-raw` (env duplicated per service).
  - `16c8b68` and `84b6eef` (2025-01-23) consolidated env into one file, which fixed it.
  - `3cd78f1` (#611, 2025-10-23). Body: the API used Redis DB 3 and the events-processor DB 0,
    so "the `charge-usage` cache [never expired] in development".
  - `c80a7b5` (#580, 2025-09-03). Body: random `lago up -d` failures. `migrate` could not reach
    Redis or ClickHouse, and topic creation was refused.
  - `5477e39` (#581, 2025-09-04): "`rpk create topics` ... is not idempotent".
- **Check.**
  - `precommit-guard.sh` G5 warns only on NEW violations: new infra edges without
    `service_healthy`, new duplicated env keys, `rpk topic create`, topic renames.
  - `docker compose -f docker-compose.dev.yml config --quiet` must exit 0. It works without a
    daemon.

## N13. Claims carry evidence; unverified is labelled; no oversell

- **Rule.**
  - Every claim in a doc, PR or skill carries `path:line`, a sha, or a command and its output.
  - Anything else is labelled UNVERIFIED.
  - Targets are never presented as current state.
- **Why.** The docs are stale in 20+ places. The register is in `docs-and-writing`; these two were re-checked here:
  - `events-processor/CLAUDE.md:10` says direct `go test` cannot work, but `ep-test.sh` runs
    the full suite without Docker.
  - `docs/dev_environment.md:266-278` contradicts N1.
- **Check.** The stale-claim register and doc-drift check are in `docs-and-writing`. The
  citation lint is in `research-methodology`.
