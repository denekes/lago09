# Change classes C0–C7: how to classify, and the gates for each

Read this when you are about to open a PR. It covers the full per-class gate list, the exact
commands, the evidence to paste, the sign-off, the sibling skills and the cross-repo steps.
SKILL.md has the one-screen summary.

All commands run from the repo root. Set these first:

```bash
cd "$(git rev-parse --show-toplevel)"
BASE=$(git merge-base origin/main HEAD)   # if this fails in a shallow clone: git fetch --deepen=100 origin main
# Branch on top of skill-library commits that are not on origin/main? Use the last of them
# (BASE=$(git log -1 --format=%H -- .claude/skills), taken before your own commits): SKILL.md §1 step 4.
CC=.claude/skills/change-control/scripts
EPTEST=.claude/skills/build-and-env/scripts/ep-test.sh
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)       # pinned lago-api (network on first use)
FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)   # pinned lago-front
```

## 1. How to classify

1. List the paths: `git diff --name-only "$BASE"` (or `git diff --cached --name-only` before
   a commit).
2. Match every path against the class table below.
3. Then apply the behaviour test for each events-processor row. The path alone does not decide
   between C2, C3 and C4.
4. **Several rows can match. Apply the union of their gates.** C7 is an overlay: it adds to
   whatever else matches.
5. A path that matches no row: treat it as the strictest plausible class and say so in the PR.
6. **Precedence (path row vs behaviour test).** The behaviour test wins. An edit to a C4 path
   (`config/kafka/consumer.go`, `config/kafka/producer.go`, `processor.go:50-88`,
   `event_producer_service.go`) is **C3** when it only adds or changes log lines, span
   attributes or counters AND
   - (a) the diff changes no control flow, return value, `CommitRecords`/DLQ/produce call or
     payload field (commit path: `events-processor/config/kafka/consumer.go:82-109`), and
   - (b) `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh --check-baseline`
     prints `moved=0 unmeasured=0` (paste it; exit 0; about 20 s, needs Postgres; verified 2026-10-02:
     `scoreboard: moved=0 unmeasured=0 targets_missed=12`; skipped rows exit 5).

   Anything that alters commit, retry, DLQ or skip behaviour, or a contract K1-K10, is **C4**
   (N7, N6). Say in the PR which rule you applied.

| Class | Paths (any of) | Behaviour test: it is this class if… |
|---|---|---|
| **C0** docs/skills | `*.md` anywhere, `docs/*.png`, `.github/ISSUE_TEMPLATE/**`, `PULL_REQUEST_TEMPLATE.md`, `.claude/skills/**/*.md` | nothing executable changes |
| **C1** tests/tooling | `events-processor/**/*_test.go`, `events-processor/tests/**`, `**/testdata/**`, `.claude/skills/**/scripts/**` | no production `.go` file changes (check below prints nothing) and no existing expectation string (sqlmock SQL, expected values) changes |
| **C2** EP refactor | `events-processor/**/*.go` (non-test) | every C2 condition in §4 holds: no expectation changes, no SQL text change, no contract file touched |
| **C3** EP behaviour | same paths as C2, typically `processors/events_processor/enrichment_service.go`, `utils/time.go`, `models/*.go` queries, `cache/*.go` | an expected value, SQL string, timestamp or matching rule changes, or a new test pins new behaviour |
| **C4** delivery / contract | `config/kafka/consumer.go`, `config/kafka/producer.go`, the disposition branches in `processors/events_processor/processor.go:50-88`, `event_producer_service.go` (topics, keys), JSON tags in `models/event.go`, `models/stores.go` (ZSET), topic, group or flag-store names in `processors/main_processor.go`, `LAGO_KAFKA_*` in `.env.development.default`, the topic list in `docker-compose.dev.yml`, field mappings in `connectors/*.yml`, `extra/debezium_config.json`, `.github/workflows/docker-build-multi-arch.yaml` | commit, retry, DLQ or skip behaviour changes (incl. a new DLQ cause or `error_code`), or anything another repo reads or writes changes (see `cross-repo-protocol.md`); step 6 can make a C4-path edit C3 |
| **C5** release / pins / CI | `api`, `front` (gitlinks), `.gitmodules`, image tags in `docker-compose.yml:11,13`, `.github/workflows/**`, `events-processor/Dockerfile*`, `docker/Dockerfile`, `docker/Procfile`, `connectors/Dockerfile`, `events-processor/go.mod`, `go.sum`, `mise.toml` | a version, pin, image, workflow or dependency changes |
| **C6** dev env / compose / deploy | `docker-compose.dev.yml`, `docker-compose.yml` (non-image parts), `.env.development.default`, `deploy/**`, `docker/runner.sh`, `traefik/**`, `scripts/**`, `extra/**` (except the Debezium config), `examples/**`, `events-processor/.air.toml` | how a stack is configured or started changes |
| **C7** security overlay | any path, when the diff touches: a secret, key, licence or token; TLS or auth settings (`InsecureSkipVerify`, SASL, `LAGO_SIDEKIQ_WEB`); published ports; docker.sock mounts; `.gitignore` or `.dockerignore`; new third-party actions, images, `curl \| sh` or vendored binaries; workflow `permissions:`, `secrets.*` or OIDC; PII in logs, Sentry or DLQ payloads | exposure, trust or supply chain changes |

Quick checks that feed the behaviour test:

```bash
# Production Go files touched (empty => not C2/C3/C4 by path)
git diff --name-only "$BASE" -- events-processor | grep '\.go$' | grep -v '_test\.go$' | grep -v '^events-processor/tests/'
# Existing test expectations changed (any '-' line in a _test.go => at least C3, unless a pure rename)
git diff "$BASE" -- 'events-processor/*_test.go' | grep -E '^-[^-]' | head
# Contract files touched (non-empty => review for C4: C4 unless step 6 makes it C3;
# in main_processor.go only the topic, group and flag-store name lines count)
git diff --name-only "$BASE" -- events-processor/config/kafka events-processor/models/event.go events-processor/models/stores.go \
  events-processor/processors/events_processor/event_producer_service.go events-processor/processors/main_processor.go \
  connectors extra/debezium_config.json .github/workflows/docker-build-multi-arch.yaml
```

Worked cases (the precedence rule applied):

| Change | Class | Why |
|---|---|---|
| Log line, span attribute or counter in `consumer.go` / `processor.go:50-88` / `event_producer_service.go`, no control-flow change | C3 | step 6 (paste `moved=0`) |
| New optional env knob read in `processors/main_processor.go` or `config/kafka/*.go` whose default preserves behaviour | C3 + C6 | no commit/retry/DLQ/skip change and no topic, group, key, payload or Redis name change; write "C4 by path, C3 by behaviour" in the PR; add-a-variable checklist in `config-and-flags` |
| `value` string formatting (`processors/events_processor/enrichment_service.go:114`) | C3 + C4 | contract K4 (N6): paired lago-api PR (OD-4); a ClickHouse schema change only via OD-3; closing a DIVERGE value row of `rails-go-parity` (P10-P13) runs `cross-repo-protocol.md` |
| Time parsing (`utils/time.go`) | C3 | C4 if the enriched `timestamp` payload format changes (K4, `events-processor/models/event.go:45`) |
| New DLQ cause or `error_code` (e.g. detect-and-DLQ ClickHouse overflow) | C4 | changes disposition; ADR + owner acceptance under OD-3; DLQ'd rows are not replayable (no DLQ replay tool exists). The N7 kfake test is required only if `consumer.go` or commit logic changes; the campaign accounting-probe ledger and value corpus before/after are required either way |
| New `Select` list over columns Go already reads from that table (e.g. `FetchBillableMetric` using the columns of `GetAllBillableMetrics`, `models/billable_metrics.go:88-98`) | C3 + a K8 note in the PR | no new Go dependency on a Rails column |
| Selecting a column Go has never read before | C4 | K8 (Go anchor `models/subscriptions.go:37`): the two-release drop rule now binds that column |

## 2. Gate G0: every class, every PR

| Step | Command | Pass condition |
|---|---|---|
| Before each commit | `$CC/precommit-guard.sh` | `SUMMARY precommit-guard: 0 FAIL` |
| Before opening the PR | `$CC/precommit-guard.sh --range "$BASE..HEAD"` | 0 FAIL; every WARN explained in the PR |
| Commit subjects | `$CC/commit-msg-check.sh --range "$BASE..HEAD"` | 0 FAIL (see `commit-pr-conventions.md`) |
| Scope | `git diff --stat "$BASE"..HEAD` | only the paths you meant; paste it |
| Clean tree | `git status --porcelain` | nothing unintended (change-control N10) |

## 3. C0: docs and skills only

- **Local checks.**
  - G0.
  - Every new or changed claim carries `path:line`, a sha, or a command and its output (N13).
  - Every command you document was run. Otherwise mark it "not runnable in a daemon-less
    sandbox; verified by reading `<file:line>`".
  - Run the doc-drift check from `docs-and-writing` and the citation lint from
    `research-methodology`.
- **CI reality.**
  - No PR check runs on a docs-only PR. The only PR workflow is path-filtered to
    `events-processor/**` (`.github/workflows/events-processor-tests.yml:7-13`).
  - After merge, that workflow runs on the push to `main` regardless of paths (`:3-6`).
  - `[ci skip]` (`CONTRIBUTING.md:172`) is therefore pointless in PRs. It appears once in all
    history.
- **Evidence in the PR.** The claims you verified and the commands you used.
- **Sign-off.** Any maintainer. Changes to doctrine (N#, C#, OD-#) in this skill need the owner.
- **Siblings.** `docs-and-writing` (templates, stale-claim register), `research-methodology`
  (evidence bar).

## 4. C1 and C2: tests and tooling; events-processor refactor

C1 local checks:

```bash
$EPTEST                                   # expect: ok for cache, config/database, config/kafka, models,
                                          #         processors/events_processor, utils; no FAIL
$EPTEST -race -count=1 ./...              # expect: same 6 ok lines (about 7-8 s warm here, 2026-10-01)
$EPTEST -v -count=1 ./... 2>&1 | grep -c -- '--- PASS'   # 235 as of 2026-10-01; must not go DOWN
```

- A regression test must FAIL on the code before the fix. Paste that failing run too.
- Skill scripts: `bash -n <script>`, run on the real repo and on a scratch clone
  (`git clone -q . "$(mktemp -d)/c"`), and check `git status --porcelain` is unchanged.
- Adding a golangci-lint config: OPEN DECISION OD-6 (owner). Not C1-by-default.

C2 behaviour test. **All** of these must hold, otherwise the change is C3 or C4:

1. No existing test expectation changes (second quick check in §1 is empty, or only renames).
2. No SQL string in a sqlmock expectation changes.
3. No contract file is touched (third quick check in §1 is empty).
4. Observable outputs are unchanged: enriched, in-advance and DLQ payloads; DLQ `error_code`s;
   Redis members; commit behaviour.

C2 local checks (change-control N9): run the **"Pre-PR gate for events-processor code"** block
in SKILL.md §3. It is the one canonical copy (8 numbered commands with expected outputs: suite
ok x6 and PASS not below baseline, `-race`, `go vet`, `gofmt -l`, golangci-lint
`--allow-serial-runners --new-from-rev="$BASE"`, both guards). `go vet` and golangci-lint need
no `ep-env.sh`; only `go build`/`go test` of `processors/events_processor` do.

- Full-repo lint today: `golangci-lint run --allow-serial-runners ./...` prints "21 issues:
  errcheck 16, staticcheck 5" (v2.5.0, no config, as of 2026-10-01). The gate is "no NEW
  issues" (`--new-from-rev`), not zero. OPEN DECISION OD-6 (owner).
- `--new-from-rev` was verified in a scratch clone (2026-10-01): one added unchecked
  `os.Remove(...)` call in `utils/time.go` produced "1 issues: * errcheck: 1", exit 1; the
  21 baseline issues were not reported. On the unchanged tree it prints "0 issues.", exit 0.
- The Docker-free recipe is the accepted local gate: OPEN DECISION OD-5 (owner), default
  accepted. `lago exec events-processor go test ./...` is still valid for people running the
  dev stack.

Evidence block (paste into the PR body; template in `docs-and-writing`):

```
Class: C2   Base: <sha>
ep-test.sh: ok cache | config/database | config/kafka | models | processors/events_processor | utils
--- PASS count: <n> (baseline 235)
-race: ok x6 (unit suite)     go vet: clean     gofmt -l (changed files): empty
golangci-lint --new-from-rev=<base>: 0 issues (repo baseline 21)
precommit-guard --range: 0 FAIL, <n> WARN (explained below)
```

- **Sign-off.** The events-processor maintainer. See SKILL.md "Review routing".
- **Siblings.**
  - `validation-and-qa`: test conventions, baselines, sqlmock pinning.
  - `build-and-env`: when the recipe fails (`cannot find -lexpression_go`, loader errors).

## 5. C3: events-processor behaviour change

C2 gates, plus all of:

1. A table-driven test that pins the new behaviour and fails on `$BASE`.
2. **Queries (N4).** Explicit column list, `deleted_at IS NULL` on soft-deletable tables,
   `organization_id`, and the exact SQL pinned in the sqlmock test. sqlmock's default matcher
   is an unanchored regexp, so anchor new pins: `"^" + regexp.QuoteMeta(sql) + "$"`.
3. **Both data modes.**
   - If the logic exists in DB mode and memory-cache mode, test both: the dual-mode DataStore
     pattern in `validation-and-qa`.
   - Label any memory-cache production impact "depends on OPEN DECISION OD-1 (owner)".
4. **Parity.** If the behaviour mirrors Rails or ClickHouse:
   - cite both sides as `$API/<path>:line` at the pinned SHA
     (`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`);
   - run the matching probe from `rails-go-parity`;
   - state the pin lag: events-processor HEAD (2026-09-18) is newer than `api@591ae90`
     (2026-09-08).
5. **Value or time changes.** Paste a before/after table over the golden corpus
   (`event-accounting-campaign` W2/W3).
   - `value` string formatting (`enrichment_service.go:114`) is also C4 (contract K4; §1 worked cases).
   - A ClickHouse schema change is OPEN DECISION OD-3 (owner) and lago-api work.
6. **Per-event Rails resolution** (charge or filter matching, Rails cache keys) is forbidden
   (N8). Reintroducing it needs a parity spec, a parity test and owner sign-off.

- **Sign-off.** The events-processor maintainer. The owner too when N8 or OD-3 applies.
- **Cross-repo.** If Rails must change too, it is C4: follow `cross-repo-protocol.md`.

## 6. C4: delivery semantics or cross-repo contract

C4 has two parts. Apply the part(s) the diff touches, and for the other write
"N6 (or N7): not applicable because <reason>" in the PR. Example: a commit-path change in
`consumer.go` that changes no payload, topic, key or Redis name needs no paired lago-api PR.

C3 gates, plus:

1. **Delivery part (N7), for commit, retry, DLQ or skip changes:**
   - A test drives `processRecordsAndCommit` through in-process Kafka (the kfake harness from
     `diagnostics-and-tooling`).
   - That test puts `github.com/twmb/franz-go/pkg/kfake` into `events-processor/go.mod`
     (absent today: `grep -n kfake events-processor/go.mod` prints nothing), so the PR is also
     **C5**: run `$CC/pin-sync-check.sh`; the kfake version pin is in `diagnostics-and-tooling`.
   - Paste the per-offset outcome: enriched, DLQ, redelivered or LOST, and the campaign
     accounting-probe ledger before/after (`event-accounting-campaign`).
   - Race evidence: the unit-suite `-race` run never executes `processRecordsAndCommit`, so add
     one real-pipeline run:
     `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path`
     (exit 0; 66 = data race found).
   - No such test exists in the repo today:
     `grep -rn "processRecordsAndCommit\|ProcessEvents(" --include=*_test.go events-processor`
     prints nothing.
   - Owner sign-off: OPEN DECISION OD-2 (owner).
2. **Contract part (N6), for anything lago-api or ClickHouse reads or writes (K1-K10):**
   - Versioned key or topic for any format change.
   - Paired lago-api PR: OPEN DECISION OD-4 (owner), default YES. Both PRs link each other.
   - Deploy order and rollback written down.
   - Steps: `cross-repo-protocol.md`.
3. **Design note (both parts).** An ADR or design note in the PR body (template in
   `docs-and-writing`): options, chosen contract, failure matrix, throughput impact, rollback.
4. **Docs.** Update the contract table in `rails-go-parity` and the topology in
   `architecture-contract` in the same PR, or in a linked docs PR.

- **Campaign.** Delivery work for the hardest live problem runs through
  `event-accounting-campaign`. It has numbered phases and expected numbers at each gate.

## 7. C5: release, pins, images, CI workflows

| Change | Extra local checks | Notes |
|---|---|---|
| Release bump (gitlinks + compose tags) | `$CC/precommit-guard.sh --release` (0 FAIL; warns if files outside `api`, `front`, `docker-compose.yml` change, if tags differ, or if no gitlink moved), `$CC/pin-sync-check.sh`, `$CC/commit-msg-check.sh`. With the pre-commit hook installed, `git commit --no-verify` only after a clean `--release` run | Syncing `docker/Dockerfile` Ruby/Node ARGs (`:1-2`) and `BUNDLER_VERSION` (`:18`) may ride in the bump PR (G1-release-shape WARN: explain it); anything else goes in its own PR. Mechanics, ordering and artifact checks: `release-and-images`. `01cfbc6` (v1.52.1) changed compose only, so the gitlinks stayed at v1.52.0 |
| lago-expression / Rust / Go pin | `$CC/pin-sync-check.sh` -> `0 FAIL`; then the EP pre-PR gate (SKILL.md §3) | 4 + 2 + 5 locations (N3). Never edit `go.mod:10` expression-go |
| Dependency bump (`go.mod`, `go.sum`; dependabot) | the EP pre-PR gate (SKILL.md §3) + `$CC/pin-sync-check.sh` | a dependency can raise the `go` directive (`932c06c` -> `50015b0`) |
| Workflow YAML | `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*` (prints nothing); actionlint via `release-and-images` | see the CI-blind-spot bullets below |
| Dockerfiles / images | none possible without a daemon: say "not built locally; verified by reading `<file:line>`" | No PR-time image build exists (a target, not current state). The single image breaks at release time (`release-and-images`) |

CI blind spots for C5:

- A PR that changes only `.github/workflows/events-processor-tests.yml` is not exercised before
  merge, because the PR trigger is path-filtered to `events-processor/**` (`:12-13`). Watch
  the first push-to-main run.
- Release workflows run only on a release. Test them with `workflow_dispatch` first. The
  first single-image workflow needed two fixes within 20 minutes: `52ab3b3 -> 023bfe1 -> c91af2b`
  (2025-02-12).
- `.github/workflows/docker-build-multi-arch.yaml` is called by lago-front at `@main`
  (`$FRONT/.github/workflows/release.yml:13`). Any merge changes lago-front's release
  immediately. Treat it as C4 as well: tell the lago-front owners (OPEN DECISION OD-14).

- **Sign-off.** The CI/release owner for workflows and images. A release bump follows
  `release-and-images`.

## 8. C6: dev env, compose, deploy

```bash
for f in $(git diff --name-only "$BASE" -- 'docker-compose*.yml' 'deploy/*.yml' 'examples/*/compose.yml'); do
  docker compose -f "$f" config --quiet && echo "OK $f"; done          # no daemon needed; unset-var warnings are normal
docker compose -f docker-compose.dev.yml --profile '*' config --services | sort   # diff vs base: 30 services as of 2026-10-01
git diff --name-only "$BASE" | grep '\.sh$' | xargs -r -n1 bash -n                 # no output
```

- **Rules (N12).** One env source, idempotent topic creation, `service_healthy` on infra edges.
  `precommit-guard.sh` G5 warns on new violations.
- **Topic renames are C4.** ClickHouse queue tables bake topic names at migrate time
  (`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9`). The
  events-processor group id embeds the topic (`events-processor/config/kafka/consumer.go:237`).
  A new group starts at the earliest offset (franz-go default), so it replays the whole
  retained topic.
- **New variables.** Use the add-a-variable checklist in `config-and-flags`.
- **Bring-up.** `docker compose up` is not runnable in a daemon-less sandbox. Bring-up and
  runtime checks: `run-and-operate`.
- **Sign-off.** Dev-env and infra maintainers. Add the C7 overlay when ports, secrets or
  exposure change.

## 9. C7: security-sensitive overlay

- **Local checks.**
  - `$CC/precommit-guard.sh` (G2 rules print file:line only, never values).
  - The scans in `security-and-supply-chain` (counts only).
- **If a secret reached any pushed commit.**
  - Treat it as leaked. History is permanent; removal does not un-publish it (N11, `6dd7e56`).
  - Rotate it and tell the owner.
  - Never print the value, not even in a PR comment.
- **Workflows.**
  - Least-privilege `permissions:`.
  - No new long-lived cloud keys. OIDC `role-to-assume` exists in
    `.github/workflows/docker-build-multi-arch.yaml:90`, but no caller in this repo or in
    lago-front at its pin passes it (`grep -rn role-to-assume .github/workflows
    "$FRONT/.github/workflows"`). Callers in the private lago-deploy: UNVERIFIED.
  - Prefer pinned action versions.
- **Sign-off.** The owner (security). Record the decision in the PR.
