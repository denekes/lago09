---
name: change-control
description: "Change-control rules for the Lago umbrella repo: change classes C0-C7 and the gates and evidence each needs, non-negotiables N1-N13 with their incidents, commit/PR conventions, cross-repo contracts K1-K10, submodule and pin hygiene, and the owner decision register OD-1..OD-20 (decided, open, defaults). Use before a commit or PR, on \"Subproject commit\" or \"M api\" in a diff, a gitlink move, a pin bump, a topic, group or Redis-key rename, force-push, \"what gates does this need\", \"who decides\". Not for running tests (use validation-and-qa) or cutting a release (use release-and-images)."
---
# Change control: classes, gates, non-negotiables

This skill says what must be true before a commit, a PR or a merge lands, in this repo and
across repos. It covers the gates for each change class, the 13 non-negotiables, and the
incident behind each one. It also owns the owner-decision register OD-1..OD-20 (§9;
OD-1..OD-5 DECIDED 2026-10-02, OD-1b OPEN). Code facts as of `5308258` (events-processor tree
`83e012866f29`); the working branch may carry skills-only commits on top. Facts verified
2026-10-01 unless marked; decisions and contract dependents folded in 2026-10-02.

## When to use / when NOT to use

Use it:

- before every commit (run `scripts/precommit-guard.sh`), before opening a PR, and while
  reviewing one;
- to classify a diff, pick its gates and evidence, and decide who must sign off;
- whenever a change touches the `api`/`front` gitlinks, the toolchain pin set, Kafka
  commit/retry/DLQ code, a contract lago-api also reads or writes, a secret, or a CI workflow;
- when another skill says "change-control N#", "class C#" or "OPEN DECISION OD-#".

Do NOT use it for:

- how to run tests, the baselines, or how to write a test: see `validation-and-qa`;
- `cannot find -lexpression_go`, toolchain setup, the `lago` alias trap: see `build-and-env`;
- cutting a release, the artifact matrix, the all-in-one image: see `release-and-images`;
- the story of an incident, or fix-after-fix chains: see `failure-archaeology`;
- what the code does today: see `architecture-contract`;
- what Go must mirror from Rails or ClickHouse: see `rails-go-parity`;
- PR-body, commit-body and ADR templates, or stale docs: see `docs-and-writing`;
- secret scans, exposure, provenance audits: see `security-and-supply-chain`;
- the plan to fix silent event loss: see `event-accounting-campaign`;
- probe harnesses (kfake, overlay, scratch PG): see `diagnostics-and-tooling`.

If the Skill tool does not list a sibling named here, read `.claude/skills/<name>/SKILL.md`
directly (every EP PR needs `validation-and-qa` and `docs-and-writing`).

## Terms

| Term | Meaning here |
|---|---|
| gitlink | The `api` / `front` tree entries (mode 160000) that pin a submodule commit. |
| release bump | The PR that moves both gitlinks and the `docker-compose.yml:11,13` image tags to `vX.Y.Z` (example `ba292b6`). Syncing `docker/Dockerfile` Ruby/Node ARGs (`:1-2`) and `BUNDLER_VERSION` (`:18`) to the new pins may ride along (guard WARNs G1-release-shape: explain it in the PR); anything else goes in its own PR. |
| pin set | Values that must move together: the lago-expression ref (4 places), the Rust image (2), Go major.minor (5). |
| contract | Data or names another repo reads or writes: K1-K10 in `reference/cross-repo-protocol.md`. |
| external dependent | A file in another repo (lago-api, lago-front, lago-helm-charts, a deploy repo), or another deployable of this repo (`connectors/*.yml`), that reads or writes a contract K#. Listed per K row in `reference/cross-repo-protocol.md` §1. A paired PR is needed in each repo whose dependent the change touches (DECIDED OD-4). |
| versioned name | A new key, topic or field name used when a format changes (`subscription_refreshed` -> `subscription_refreshed_v2`, `42615c9`). |
| EP | `events-processor/`, the only first-party code in this repo. |
| `BASE` | `git merge-base origin/main HEAD`: the point the PR diff starts from. |
| gate / evidence block | A check that must pass, and its output pasted into the PR body. |
| ADR | A short design note in the PR (template in `docs-and-writing`). |
| ADR-001 | The accepted delivery contract for failures (DECIDED OD-2): classify SYSTEMIC / TRANSIENT / PERMANENT; pause and back off, retry topic, or DLQ with cause; commit only durable dispositions. Text: `event-accounting-campaign` `reference/delivery-options.md`. |
| owner | The repository's engineering owner/maintainers: they take OD decisions and sign off C4, C7 and doctrine edits. Identity UNVERIFIED from the repo (no CODEOWNERS); route by history (§8: events-processor is dominated by one maintainer). |
| OD-n | An owner decision (§9). While open, write "OPEN DECISION OD-n (owner)" wherever you rely on its default. Once decided, write "DECIDED OD-n (owner, <date>)". "DEFAULT APPLIED OD-n" marks a default the orchestrator applied to an unanswered question (the owner may reassign). Raise a new one as a GitHub issue titled "OD-n: <topic>" with the evidence block. |
| N#, C#, G#/PS#/M# | Non-negotiable (§4), change class (§2), and the rule ids printed by the three scripts (§Scripts). |
| `$API`, `$FRONT`, `$H` | Pinned lago-api and lago-front checkouts and the full-history clone, from the research-methodology scripts (see Provenance). |

## 1. The flow for every change

<!-- evidence-check: off normative procedure; its commands are in §3 and reference/change-classes.md -->
1. **Classify** the diff with §2. Several classes can match: apply the union of their gates.
2. **Before each commit**, run `.claude/skills/change-control/scripts/precommit-guard.sh` (expect `0 FAIL`).
3. **Run the class gates** (§3; for events-processor code, the pre-PR gate block in §3;
   the per-class commands are in `reference/change-classes.md`).
4. **Before opening the PR**, run
   `precommit-guard.sh --range "$BASE..HEAD"` and `commit-msg-check.sh --range "$BASE..HEAD"`.
   - Branch from `origin/main`. If your branch sits on skill-library commits that are not on
     `origin/main` (`git log --oneline origin/main..HEAD -- .claude/skills`), set
     `BASE=$(git log -1 --format=%H -- .claude/skills)` before your own commits. Otherwise the
     range includes the library and `commit-msg-check.sh` FAILs on its subjects (M1, M6).
   - Until the library is on `main`, a branch made from `origin/main` has no `.claude/skills/`;
     run the scripts from a checkout that has them, with `-C <your-worktree>`.
5. **Write the PR.** Paste the evidence block, explain every WARN, label every OPEN DECISION
   you depend on, cite every DECIDED one you apply (§9), and route review (§8).
   - `PULL_REQUEST_TEMPLATE.md:12,14` (one commit, amend, `pnpm test`) do not apply here: use
     these gates; the squash merge makes the single commit.
6. **Never force-push the PR branch** (N2). Fix forward; the squash merge collapses commits.
<!-- evidence-check: on -->

## 2. Classify: C0-C7

<!-- evidence-check: off normative classification rules; evidence in reference/change-classes.md §1 -->
| Class | Typical paths | Tell-tale |
|---|---|---|
| C0 docs/skills | `*.md`, `docs/*.png`, `.claude/skills/**/*.md` | nothing executable changes |
| C1 tests/tooling | `events-processor/**/*_test.go`, `events-processor/tests/**`, `.claude/skills/**/scripts/**` | no production `.go` file changes, no existing expectation changes |
| C2 EP refactor | `events-processor/**/*.go` | tests, SQL strings, payloads and contract files all unchanged |
| C3 EP behaviour | `enrichment_service.go`, `utils/time.go`, `models/*.go` queries, `cache/*.go` | an expected value, SQL string, timestamp or matching rule changes |
| C4 delivery/contract | `config/kafka/consumer.go`, `producer.go`, disposition in `processor.go:50-88`, `event_producer_service.go`, JSON tags in `models/event.go`, `models/stores.go`, topic/group names, `connectors/*.yml` mappings, `extra/debezium_config.json`, `docker-build-multi-arch.yaml` | commit, retry, DLQ or skip semantics change (incl. a new DLQ cause or `error_code`), or anything lago-api or lago-front reads or writes (K1-K10, incl. the `value` string) |
| C5 release/pins/CI | `api`, `front`, `.gitmodules`, `docker-compose.yml:11,13`, `.github/workflows/**`, `events-processor/Dockerfile*`, `docker/Dockerfile`, `events-processor/go.mod`, `go.sum`, `mise.toml` | a version, pin, image, workflow or dependency changes |
| C6 dev env/deploy | `docker-compose.dev.yml`, `docker-compose.yml` (non-image), `.env.development.default`, `deploy/**`, `docker/runner.sh`, `traefik/**`, `scripts/**`, `extra/**` | how a stack is configured or started changes |
| C7 security overlay | any path | secrets, TLS/auth, ports, docker.sock, `.gitignore`, new actions, images or binaries, workflow permissions, PII |

How to apply the table:

- Use the union of all matching rows. C7 adds to whatever else matches.
- **Path row vs behaviour test: the behaviour test wins.** An edit to a C4 path
  (`config/kafka/consumer.go`, `config/kafka/producer.go`, `processor.go:50-88`,
  `event_producer_service.go`) that only adds or changes log lines, span attributes or counters
  is C3 when (a) the diff changes no control flow, return value, `CommitRecords`/DLQ/produce
  call or payload field, and (b)
  `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh --check-baseline` prints
  `moved=0 unmeasured=0` (paste it; about 20 s here, needs Postgres). Anything that alters commit, retry, DLQ
  or skip behaviour, or a contract K1-K10, is C4. Say in the PR which rule applied
  (`reference/change-classes.md` §1 step 6).
- **`value` string formatting** (`enrichment_service.go:114`) is C3 + C4 (K4, N6): lago-api reads
  it (ClickHouse queue, `decimal_value` default), so a paired lago-api PR (DECIDED OD-4); a
  ClickHouse schema change is allowed and rides in it (DECIDED OD-3). A DIVERGE value row of
  `rails-go-parity` (P10-P13) runs §6. Time parsing (`utils/time.go`) is C3; C4 if the enriched
  `timestamp` payload format changes.
- **A new DLQ cause or `error_code`** (e.g. detect-and-DLQ overflow) is C4. It must fit ADR-001
  (PERMANENT: DLQ at once with a cause; DECIDED OD-2), else the owner decides. A new
  `error_code` value is additive for lago-api; a DLQ payload change is K6 (paired PR). No DLQ
  replay tool exists yet (ADR-001 specifies one: CANDIDATE). The N7 kfake test is needed only if
  commit logic changes; the campaign ledger and value corpus before/after always are.
- A path that matches nothing: take the strictest plausible class and say so in the PR.
<!-- evidence-check: on -->
- Classifier one-liners, behaviour tests and worked cases (optional env knob in
  `config/kafka/*.go`, a new `Select` list): `reference/change-classes.md` §1.

## 3. Gates per class (summary)

<!-- evidence-check: off normative gate table; commands and outputs in the block below and reference/change-classes.md -->
| Class | Local gates (beyond G0 = guard + msg check + `git diff --stat`) | Evidence in PR | Sign-off | Consult |
|---|---|---|---|---|
| C0 | Each claim has `path:line`, a sha, or a command and its output; each documented command was run | claims checked + commands | any maintainer; owner for doctrine edits | docs-and-writing, research-methodology |
| C1 | `ep-test.sh`; `ep-test.sh -race -count=1 ./...`; PASS count does not drop (235); a regression test fails on base | test summary lines | area maintainer | validation-and-qa, diagnostics-and-tooling |
| C2 | N9: the EP pre-PR gate below (tests, `-race`, vet, gofmt, no new lint) | the C2 evidence block | EP maintainer | validation-and-qa, build-and-env |
| C3 | C2 + a test pinning the new behaviour; N4 SQL rules with SQL pinned in sqlmock; both data modes (production runs memory-cache mode, DECIDED OD-1; dev runs DB mode); parity cites `$API` file:line; value/time before-and-after on the corpus | + test names, parity cites, before/after | EP maintainer; owner if N8; lago-api maintainers for a ClickHouse schema change (paired PR) | rails-go-parity, architecture-contract, event-accounting-campaign |
| C4 | C3 + **delivery part (N7)**: conform to ADR-001 (DECIDED OD-2): kfake ledger test driving `processRecordsAndCommit` (puts kfake in `events-processor/go.mod`: also C5), one `GOFLAGS=-race` kfake run, campaign ledger before/after, ADR-001 reference in the PR. **Contract part (N6)**: a paired PR in every repo whose external dependent the change touches (DECIDED OD-4; dependents per K row in `reference/cross-repo-protocol.md` §1), versioned name, deploy order, rollback. Write "N6 (or N7): not applicable because <reason>" for a part the diff does not touch | + ledger output, ADR-001 points implemented, paired PR links or "no external dependent (K#)", deploy order | owner + EP maintainer; each dependent repo's owner on its paired PR; a deviation from ADR-001 needs an owner decision first | cross-repo-protocol, event-accounting-campaign, diagnostics-and-tooling |
| C5 | `pin-sync-check.sh` 0 FAIL; the EP pre-PR gate for dependency or pin bumps; YAML parse; `--release` for bumps; images "not built locally" | + pin-sync output | CI/release owner | release-and-images, build-and-env |
| C6 | `docker compose -f <f> config --quiet` for every touched compose file; `bash -n` on scripts; N12 (guard G5) | + config output, service diff | dev-env/infra maintainers | run-and-operate, config-and-flags |
| C7 | guard G2 + `security-and-supply-chain` scans; rotate anything ever pushed; never print values | counts and file:line only | owner (security) | security-and-supply-chain |
<!-- evidence-check: on -->

**Pre-PR gate for events-processor code (N9).** The one canonical block; other skills point
here. From the repo root:

```bash
BASE=$(git merge-base origin/main HEAD)   # shallow clone: git fetch --deepen=100 origin main, retry
                                          # skill-library commits under your branch: §1 step 4
T=.claude/skills/build-and-env/scripts/ep-test.sh
$T                                        # 1. ok x6: cache, config/database, config/kafka, models,
                                          #    processors/events_processor, utils; no FAIL
$T -v -count=1 ./... 2>&1 | grep -c -- '--- PASS'   # 2. not below 235 (as of 2026-10-01)
$T -race -count=1 ./...                   # 3. ok x6 (unit suite only: it never runs processRecordsAndCommit)
( cd events-processor && go vet ./... )   # 4. no output, exit 0 (vet and lint need no ep-env.sh)
git diff --name-only --diff-filter=AM "$BASE" -- events-processor | grep '\.go$' | xargs -r gofmt -l   # 5. no output
( cd events-processor && GOLANGCI_LINT_CACHE="${TMPDIR:-/tmp}/golangci-cache" \
  golangci-lint run --allow-serial-runners --new-from-rev="$BASE" ./... )   # 6. "0 issues." (baseline 21, OD-6)
.claude/skills/change-control/scripts/precommit-guard.sh --range "$BASE..HEAD"    # 7. 0 FAIL
.claude/skills/change-control/scripts/commit-msg-check.sh --range "$BASE..HEAD"   # 8. 0 FAIL
```

Timings here (4 vCPU, 2026-10-01): cold suite 60-75 s typical (up to about 120 s loaded), warm
4-5 s, `-race` warm about 7-8 s. Evidence-block template: `reference/change-classes.md` §4.

CI is not a safety net here: the only PR workflow, `events-processor-tests.yml`, runs only
`go test -v ./...` (`.github/workflows/events-processor-tests.yml:63-64`) and only for
`events-processor/**` paths (`:7-13`). Docs, compose, workflow, deploy and `docker/Dockerfile`-only
PRs get **no** PR check at all.

## 4. Non-negotiables N1-N13

The full rule, why, incident, cost and check for each is in `reference/non-negotiables.md`.
Every sha below was read in the history clone.

| # | Rule (short) | Incident (sha, PR, cost) | Check |
|---|---|---|---|
| N1 | Never stage or commit an `api`/`front` gitlink move outside a release bump | `12b8101` (#618) moved both pins in a Traefik fix; reverted by `647de3e` (#620) the same day; 15 non-release moves since 2025-01-01 (one, `190aa81`, downgraded front v1.33.4 -> v1.33.2) | guard G1; §5 |
| N2 | Never force-push a branch with an open PR, or `main` | `5308258` body: PR #800 "was force-pushed onto main… the original is unrecoverable"; rebuilt from lago-deploy#3331 | confirm no open PR before any `--force*` push |
| N3 | Pin set moves together; no `@latest`; leave `go.mod:10` expression-go v0.1.4 | `5077151` (#666) bumped the ref in all 3 places of the time but left the prod Dockerfile on rust:1.82; `e8bbd60` (#667) "Fix prod release" 81 min later; `d589940` (#586) `air@latest` broke the dev build; `932c06c` -> `50015b0` Go realign. Residual: `docker/Dockerfile:12` `pnpm@latest` (conditional risk); base images float at patch level (`golang:1.25` = 1.25.14 on Docker Hub; CI tests 1.25.0) | `pin-sync-check.sh`; guard G3 |
| N4 | EP SQL: explicit columns, `deleted_at IS NULL`, `organization_id`, SQL pinned in sqlmock | `bd92069` -> `9acd83e` (#735, ING-15) SQLSTATE 0A000 for about 5.5 months; `fff5858` -> `8ceca4b` (#740) deleted BMs matched for 18 days; `9ef876a` (#738, ING-123); residual: `models/billable_metrics.go:59-66` (`SELECT *`), `models/charges.go:47-66` (no exact SQL pin) | grep in non-negotiables §N4 |
| N5 | Per-record side effects (Redis, produce) use the batch context that `processRecordsAndCommit` creates (`context.Background()`, `events-processor/config/kafka/consumer.go:83`), never the process/signal context that SIGTERM cancels | `b6d3616` -> `02a4bc8` (#785): `context canceled` on every rolling restart for about 9 months | context-field grep (6 known hits) |
| N6 | Cross-repo contracts change together with their external dependents: versioned name, ordered deploy, a paired PR in each dependent repo (DECIDED OD-4: dependency-driven) | `7421650` -> `42615c9` (SET -> ZSET + `_v2`) -> `fb6401d` (15 s -> 10 s) -> `b4ad153`: 4 protocol changes in 15 months | `reference/cross-repo-protocol.md` |
| N7 | No commit/delivery change without a kfake ledger test + conformance to ADR-001 named in the PR + owner sign-off; a deviation from ADR-001 needs an owner decision (DECIDED OD-2) | `cec0eb2` -> `656c829` -> `600e195` (infinite poll loop, hotfixed by `b604769` 3 days later) -> `b6d3616` -> `9acd83e` (ING-15): 13 months, ended "segfaulting the pod inside franz-go" | no test calls `processRecordsAndCommit` today |
| N8 | Go never re-implements Rails resolution per event | `flat_filters` saga, about 15 months and 7 fix commits, removed by `d9c32b6` (#797) as "the main database load"; Go cache expiry removed by `2fd8e8b` (#766) | review |
| N9 | EP pre-PR gate: tests, `-race`, vet, gofmt, no new lint; paste evidence | CI runs `go test -v` only; lint baseline 21 issues (OD-6) | the §3 EP gate block |
| N10 | Probes never write into the repo | the README's `go build -o event_processors .` leaves an un-ignored 58 MB binary | `git status --porcelain`; guard G4 |
| N11 | No real secrets in tracked files; never print historical values | `LAGO_LICENSE` value on `main` 37 days (merge `0a67ac0` 2025-01-29 -> `6dd7e56` #477 2025-03-07; up to 43 days if the branch was public from 2025-01-23: UNVERIFIED); rotation UNVERIFIED (OD-9) | guard G2 |
| N12 | One dev env file; idempotent topics; infra edges `service_healthy`, one-shot jobs `service_completed_successfully` | `0ca6cdf` (#424) introduced a per-service topic mismatch, `16c8b68` fixed it; `3cd78f1` (#611) env drift; `c80a7b5` (#580) startup races; `5477e39` (#581) topic creation | guard G5; `compose config --quiet` |
| N13 | Claims carry evidence; UNVERIFIED is labelled | docs stale in 20+ places (register in `docs-and-writing`); re-checked here: `events-processor/CLAUDE.md:10`, `docs/dev_environment.md:266-278` | docs-and-writing drift check |

## 5. Submodule and pin hygiene (N1, N3)

**Before every commit** (from the repo root):

```bash
git diff --cached --submodule=short --ignore-submodules=none -- api front   # expect: no output
git ls-files -s api front; git ls-tree HEAD api front                      # expect: identical shas
.claude/skills/change-control/scripts/precommit-guard.sh                   # expect: 0 FAIL
```

**If G1-gitlink fires.** All three fixes below were verified in a scratch clone; they work even
when `api/` is not checked out.

| Where the move is | Fix |
|---|---|
| staged only | `git restore --staged -- api front` |
| committed, not pushed | `git restore --source="$BASE" --staged -- api front && git commit --amend --no-edit` (if the commit holds only the gitlink: `git reset --soft HEAD~1 && git restore --staged -- api front`) |
| pushed / PR open | `git restore --source="$BASE" --staged -- api front && git commit -m "fix(submodule): restore api/front gitlinks"`. A new commit, as `647de3e` did. Never amend and force-push (N2). |

**Traps** (verified with git 2.43 in a scratch clone, 2026-10-01; details in
`reference/non-negotiables.md` N1):

- A populated `api/` checked out at another commit shows as ` M api`. Then `git add -A`,
  `git add -u` and `git commit -a` all stage the move. Add paths explicitly.
- `diff.ignoreSubmodules=all` and `submodule.api.ignore=all` **hide** that drift from
  `git status` and a **staged** move from `git diff --cached`, but do **not** stop
  `git add -A`/`-u` from staging it. Never rely on them. The guard always passes
  `--ignore-submodules=none`.
- After working inside `api/` (`docs/dev_environment.md:251-262`), reset the submodule
  checkouts to the recorded pins:
  `git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init -- api front`.
  The URLs in `.gitmodules:3,6` are SSH. Verified in a scratch clone for `front` (with
  `--depth 1`): it checked out the recorded pin `0c5e539`.
- `docs/dev_environment.md:266-278` ("Updating a reference … `git push origin main`")
  contradicts N1. Ignore it. `docs-and-writing` tracks the correction.

**Bumping the lago-expression ref** (C5):

1. Change the ref in all four places: `events-processor/Dockerfile:5`, `Dockerfile.dev:5`,
   `Dockerfile.staging:23` (`ARG LAGO_EXPRESSION_REF`), `.github/workflows/events-processor-tests.yml:45`.
2. If the new ref needs a newer Rust, move `FROM rust:` in both `Dockerfile:1` and
   `Dockerfile.dev:1`.
3. Run `.claude/skills/change-control/scripts/pin-sync-check.sh`. Expect `0 FAIL`.
4. `source .claude/skills/build-and-env/scripts/ep-env.sh`. It reads the ref from the
   Dockerfile and builds that `.so` into the cache. Then run the EP pre-PR gate (§3).
5. Do **not** touch `events-processor/go.mod:10` (`expression-go v0.1.4`). The guard fails on
   it (G3-expression-go).
6. Expect the PR CI to run, because the Dockerfiles live under `events-processor/**`
   (`.github/workflows/events-processor-tests.yml:12-13`).

**Bumping Go:** the same discipline over 5 places: `go.mod:3`, `mise.toml:2`, `Dockerfile:7`,
`Dockerfile.dev:7` (all under `events-processor/`), and
`.github/workflows/events-processor-tests.yml:61`. A dependabot bump can raise the `go`
directive on its own: `932c06c` (#724) moved it, and `50015b0` (#725) realigned the rest 50
minutes later. The base images float at patch level (`golang:1.25` is 1.25.14 on Docker Hub
as of 2026-10-01): that skew against CI's 1.25.0 is an accepted residual of N3.

## 6. Cross-repo contract changes (N6, DECIDED OD-4)

Contracts (`reference/cross-repo-protocol.md` §1: anchors on both sides plus an **external
dependents** column, repo: file, verified 2026-10-02): K1 Redis ZSET `subscription_refreshed_v2`;
K2 the raw payload; K3 the `api_post_processed` split; K4-K6 the enriched, in-advance and DLQ
topics and payloads; K7 consumer-group naming; K8 Rails columns that Go selects; K9 Debezium
columns; K10 the reusable workflow lago-front calls at `@main`. N6 applies only when one changes.

**DECIDED OD-4 (owner, 2026-10-02): paired PRs are dependency-driven, not a blanket rule.** A
contract change needs a paired PR in every OTHER repo that reads or writes the part that
changes. If none does, write "N6: no external dependent of <K#> is touched" and cite the §1
row. Most rows have lago-api dependents (K1 the clock job; K2, K4, K6 ClickHouse queue tables;
K5 Karafka; K2, K3 Rails writers; K8 the Rails schema), so many changes still need one. A new
topic or Kafka env var also touches deployment repos (`getlago/lago-helm-charts` topic and env
lists; production provisioning is owner/ops).

<!-- evidence-check: off normative protocol; steps and anchors in reference/cross-repo-protocol.md §2 -->
1. **Additive first.** A format change uses a **new versioned name**.
2. **ADR in the PR:** both mixed-version windows, deploy order, rollback, cleanup owner.
3. **Paired PRs per dependent** (the K row's dependents cell), linked both ways; each side pins
   the format in a test.
4. **Deploy order:** the tolerant reader first, the writer second, cleanup a release later. Go
   writes K1, K4-K6 (lago-api first); Rails writes K2, K3 (EP first); a K8 column drop: the EP
   stops selecting it in release N, Rails drops it in N+1 (`$API/docs/dropping_columns_and_tables.md`).
5. **Rollback:** the writer first. Irreversible steps (column drops, topic deletion, ClickHouse
   DDL) happen only in cleanup.
<!-- evidence-check: on -->

## 7. Commit and PR conventions (OPEN DECISION OD-7)

The sources disagree: <= 72 (`CONTRIBUTING.md:170`) vs <= 50 (`$API/AGENTS.md:52`); one
squashed commit and `fix/`/`feature/` branches (`PULL_REQUEST_TEMPLATE.md:8,12`). Practice
follows none of them. Of the 293 non-merge commits since 2025-01-01 (`commit-msg-check.sh
--report`), 29 subjects exceed 72 and 142 exceed 50; 88% are conventional; `misc` 69 (279
all-time with the strict regex `^misc(\([^)]*\))?: `; 283 with `^misc(\(|:|!)`), `release:` 8; 64% have no body; 0 of 48 merges come from `fix/` or `feature/`.
The stated-vs-practised table and its commands: `reference/commit-pr-conventions.md` §1-§2.

Defaults we operate under until the owner decides OD-7:

<!-- evidence-check: off OD-7 defaults (normative); measurements in reference/commit-pr-conventions.md §2 -->
- Conventional Commits; `misc` allowed.
- Subject <= 72 hard and <= 50 preferred, measured as it lands on main. Keep PR titles
  <= 64 characters to leave room for ` (#NNNN)`.
- A Context/Description body for C3, C4, pin-related C5, C7 and incident fixes.
- No WIP or fixup subjects on main.
- Type `release`: WARN (M4), not FAIL, until OD-7 decides; prefer `chore(release)`.
- Branch names not enforced.
- `scripts/commit-msg-check.sh` enforces the subject rules.
<!-- evidence-check: on -->

## 8. Review routing

- **No CODEOWNERS** here, in history or in lago-api at the pin: `find . -iname 'CODEOWNERS*' -not -path './.git/*'`
  and `git -C "$H" log --all --oneline -- CODEOWNERS .github/CODEOWNERS` print nothing.
- **Required checks unknown.** Branch protection is not visible from git: UNVERIFIED.
- **Route by history.** Unless the row says otherwise: non-merge commits since 2025-01-01,
  from `git -C "$H" log --no-merges --since=2025-01-01 --format=%an -- <path>` (as of
  2026-10-01):

  <!-- evidence-check: off counts come from the git log command in the bullet above; rules are normative -->
  | Area (pathspec) | Most history (commits) | Note |
  |---|---|---|
  | `events-processor` (all time, path as named since the 2025-03-21 rename; command in Provenance) | Vincent Pochet 55 of 72 non-dependabot (62 of 79 with `events_processor` added) | **bus factor 1**: also ask a second reviewer (Jérémy Denquin 5, Maxime Vidori 4, Thomas Battiston 3) |
  | `.github/workflows` | Maxime Vidori 12, Vincent Pochet 8, Jérémy Denquin 8, Kyriakos Oikonomakos 5 | reusable workflow and ECR/OIDC |
  | `docker-compose.dev.yml .env.development.default` | Vincent Pochet 13, Yohan R. 11, Romain Sempé 7, Jérémy Denquin 7 | |
  | release bumps (the 60 bump commits among the 77 `api`/`front` moves) | rotates over 15 authors: Vincent Pochet 12, Ancor Cruz 8, Toon Willems 6, Anna Velentsevich 5, … | `release-and-images` |
  | `docs` + root `*.md` (`docs CODE_OF_CONDUCT.md CONTRIBUTING.md PULL_REQUEST_TEMPLATE.md README.md`) | Maxime Vidori 10, Vincent Pochet 6 | |

- **Rules.**
  - C4 and C7 need the owner on top of the area reviewer.
  - Contract changes need the owner of each dependent repo's paired PR (DECIDED OD-4, §6); a
    delivery change that deviates from ADR-001 needs an owner decision first (DECIDED OD-2).
  - AI review comments, such as the Copilot comments addressed in `c340ddf`, never replace a
    human sign-off.
- **Bus-factor rule.** One maintainer holds most events-processor context. Every C3+ PR body
  must stand alone: Context, Description, evidence, decisions. Never "as discussed".
<!-- evidence-check: on -->

## 9. Owner decisions OD-1..OD-20 (owned here)

The single owner-decision namespace. Other skills cite a row as `DECIDED OD-n (owner, <date>)` or
`OPEN DECISION OD-n (owner)` and route here; never present an OPEN row as settled. OD-10..OD-15
were release-and-images REL-1..REL-6 (OD-(9+n)); OD-16..OD-19 come from
`security-and-supply-chain`. To raise a new one, see "owner" in Terms. **2026-10-02:** the owner
answered OD-1..OD-5 in writing (this register is the record); OD-2 was delegated ("reason with
industry best practices") and is ADR-001, ACCEPTED (delegated); the unanswered part of OD-1 is the
OPEN row OD-1b; OD-20 carries a DEFAULT APPLIED (the owner may reassign it).

| ID | Question | Status: decision, or default until decided | Who decides | Record, or evidence that closes it |
|---|---|---|---|---|
| OD-1 | Does production run `LAGO_USE_MEMORY_CACHE=true` (badger snapshot + Debezium CDC)? | **DECIDED OD-1 (owner, 2026-10-02): YES.** Dev runs DB mode (`.env.development.default` sets no `LAGO_USE_MEMORY_CACHE`); PRODUCTION runs memory-cache mode. Consequences: every memory-cache defect (`architecture-contract` WP6-WP10: Debezium column gaps, swallowed snapshot errors, CDC consumer auth and a new group per start, µs vs ms subscription bounds) is production-relevant; C3/C4 tests, probes and campaign gates cover cache mode, not only DB mode. The config details moved to OD-1b | owner | owner statement 2026-10-02 (this row) |
| OD-1b | Production CDC config for memory-cache mode: is the live Debezium `column.include.list` the one in `extra/debezium_config.json:2`? Which Kafka auth (SASL/TLS) and which bootstrap broker list do the CDC consumers use? | **OPEN DECISION OD-1b (owner), urgent: verify first.** The repo list omits `charges.pay_in_advance`, `charges.accepts_target_wallet` and `billable_metrics.recurring`, which Go reads (`events-processor/models/charges.go:29-30`, `events-processor/models/billable_metrics.go:93`). If production uses it, a CDC update zeroes them in the cache: in-advance charges and the recurring fallback stop for every edited charge or metric (code-level VERIFIED, `architecture-contract` WP6; production impact UNVERIFIED). The CDC consumers pass `LAGO_KAFKA_BOOTSTRAP_SERVERS` as one seed with no SASL/TLS (`events-processor/cache/consumer.go:27-35`), unlike the main clients (SCRAM, `events-processor/config/kafka/kafka.go:58-60`). Default meanwhile: treat WP6 and WP10 as live production risks | owner + the prod deploy owner (private lago-deploy) | the prod Debezium connector config and the CDC consumers' Kafka env, secrets masked |
| OD-2 | Delivery contract for retryable failures (block the partition, retry topic, or bounded skip-to-DLQ)? Is the 12 h horizon a product decision? | **DECIDED OD-2 (owner, 2026-10-02), delegated**: ADR-001 in `event-accounting-campaign` `reference/delivery-options.md` (ACCEPTED (delegated)). SYSTEMIC failure (a dependency is down): pause the partitions, back off, commit nothing past it. TRANSIENT (one record): small in-place retry, then a retry topic. PERMANENT: DLQ at once with a cause; unmarshal errors too, never a silent commit. Commit offset N only when every record <= N has a durable disposition (acks=all). 12 h stays the default retry max age. Downstream idempotency is required. Implementation stays C4: kfake ledger test + ADR-001 reference in the PR; a deviation from ADR-001 needs the owner | owner (delegated) | ADR-001; the owner may amend it |
| OD-3 | Is a ClickHouse schema change acceptable (e.g. `events_enriched.decimal_value Decimal(38,26)`)? | **DECIDED OD-3 (owner, 2026-10-02): YES.** The value-fidelity fix may change the schema. Direction (CANDIDATE until the value corpus and ch-local probes prove it): align with Postgres `numeric(40,15)` (`$API/db/structure.sql:3059`), NULL or DLQ instead of 0 for unparseable values, exact decimal strings from Go. The DDL lives in lago-api: self-host `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`; Cloud `$API/db/clickhouse_migrate/cloud/02_events_enriched.sql:12`, edited in place (`$API/AGENTS.md:176`). So it needs a paired lago-api PR and a deploy order (DECIDED OD-4) | owner + lago-api maintainers (paired PR) | owner statement 2026-10-02; the migration plan goes in the paired PR |
| OD-4 | Is a paired lago-api PR mandatory for cross-repo contract changes? | **DECIDED OD-4 (owner, 2026-10-02): NO, unless another repo depends on the changed contract.** A paired PR is needed in every repo that reads or writes the changed part (lago-api Rails, clock, ClickHouse migrations, MVs and queue tables; connectors; Helm or deploy repos). No dependent: no paired PR. Dependents per K row: `reference/cross-repo-protocol.md` §1. Deploy order and rollback rules still apply whenever a dependent exists (§6, N6) | owner | owner statement 2026-10-02 (this row) |
| OD-5 | Is `ep-test.sh` (Docker-free) an accepted pre-PR gate? | **DECIDED OD-5 (owner, 2026-10-02): YES.** `ep-test.sh` is an accepted pre-PR gate (the §3 block); `lago exec events-processor go test ./...` stays valid for dev-stack users. Same SHAPE as CI, not identical: CI uses a `postgres:14-alpine` service (`.github/workflows/events-processor-tests.yml:25`), builds the whole lago-expression workspace with the runner's unpinned Rust (`:49`) and runs `go test -v` (`:64`); `ep-env.sh` builds the expression-go crate with local cargo against local Postgres. Fixing `events-processor/CLAUDE.md:7-10` (`docs-and-writing` SC-01) is approved, not yet applied: that edit is outside `.claude/skills`, so the owner makes it | owner, with the EP maintainer | owner statement 2026-10-02; SC-01 applied by a C0 PR |
| OD-6 | golangci-lint policy and config (none committed, ever; 21 issues today) | "no NEW issues vs base" (`--new-from-rev`). No config file without approval | owner, with the EP maintainer | proposed `.golangci.yml` + full-run count + CI job PR |
| OD-7 | Subject limit 50 or 72; is `misc` sanctioned; branch-name policy | <= 72 hard, <= 50 preferred; `misc` allowed (279 uses, strict regex `^misc(\([^)]*\))?: `); branch names not enforced | owner | CONTRIBUTING.md / PULL_REQUEST_TEMPLATE.md rewritten (C0) |
| OD-8 | Prod state of lago-api flags `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` | UNKNOWN. Drift findings say "impact depends on OD-8" | owner / lago-api maintainers | per-org flag state from prod |
| OD-9 | Was the `LAGO_LICENSE` value (`16c8b68` -> `6dd7e56`) rotated? Was ING-123 (`9ef876a`) a cross-tenant leak? | UNKNOWN, labelled UNVERIFIED. Never print the value | owner (security) | rotation record (date only); ING-123 ticket text |
| OD-10 | Is the all-in-one `getlago/lago` image still supported? Backfill the tags never published (list: `release-and-images`)? Alert on a failed release build? (was REL-1) | status quo: keep publishing, no backfill, no alert | owner + release owner | support statement; backfill run or "no backfill" note; alert job PR |
| OD-11 | Delete the dead `release.yml` `repository_dispatch` (no receiver; still needs `GH_TOKEN`)? (was REL-2) | keep it; it is inert | owner + CI/release owner | deletion PR (C5) or "keep" note |
| OD-12 | Release-day fix policy: dispatch the build from `main` (image != tag) or always cut a patch release (image == tag)? May a published tag ever be moved or deleted (default: no)? (was REL-3) | none chosen; both are used: say which in the release notes | owner + release owner | written policy here |
| OD-13 | Maintenance releases on an older line and the `latest` tag (both Docker Hub workflows re-tag `latest`) (was REL-4) | do not re-tag `latest` by hand without the owner | owner + release owner | written policy; `latest` restore procedure |
| OD-14 | Pin lago-front's `@main` call of `docker-build-multi-arch.yaml` (K10) to a tag or SHA? (was REL-5) | unpinned: treat every edit of that workflow as C4 and tell the lago-front owners | owner + lago-front owner | lago-front PR pinning the ref |
| OD-15 | Were v1.52.1 (stale pins) and v1.41.x intended? Who owns the `deploy/*.yml` image tags (still `getlago/api:v1.27.1`)? (was REL-6) | untouched by bump PRs | owner + release owner | owner note; a deploy/ tag policy |
| OD-16 | Self-host default of `LAGO_SIDEKIQ_WEB` (`docker-compose.yml:28` `${LAGO_SIDEKIQ_WEB:-true}`: `/sidekiq` with no auth) | unchanged; operators set `false` (`security-and-supply-chain`) | owner (security) | default flipped (C6 + C7) or a written acceptance |
| OD-17 | Is the HTTP connector (`connectors/http.yml`) ever reachable from outside a private network; may it trust a client-sent `organization_id`? | assume private only; widen no exposure; pinning the org id is CANDIDATE (C4 + C7) | owner (security) | deployment topology; connector fix PR |
| OD-18 | May the AWS account id stay in public workflows (`5308258` body says it was meant to stay private)? | unchanged (already in history); add no new account ids or ECR URLs to public files | owner (security) | policy note, or a move to secrets/variables (C5 + C7) |
| OD-19 | Full event JSON in Sentry extras and a TTL-less DLQ table under SOC2 | add no new payload-carrying extras or log fields (`security-and-supply-chain`) | owner (security) + data-handling owner | written policy; scrubber or TTL PR |
| OD-20 | Who owns memory-cache (badger + Debezium CDC) hardening? The as-is defects are `architecture-contract` WP6-WP10 | **DEFAULT APPLIED OD-20** (orchestrator, 2026-10-02; the owner may reassign): `event-accounting-campaign` workstream W6 "memory-cache correctness" owns it. Production relevance: DECIDED OD-1; production CDC config: OPEN DECISION OD-1b | owner (sits next to OD-1) | the owner confirms or reassigns W6 |

**Closing an OD:**

<!-- evidence-check: off normative procedure -->
1. The owner states the decision in writing (an issue, a PR, or a dated written answer).
2. A C0 PR updates the row to `**DECIDED OD-n (owner, <date>)**` with the decision, its
   consequences and the record; an unanswered part becomes an OPEN sub-id (OD-1b). Owner signs.
3. The same PR updates the skills that carry the label:
   `grep -rn "OD-<n>" .claude/skills`.
4. If the decision changes a gate, update the scripts' defaults too. For OD-7, change
   `commit-msg-check.sh --max/--pref`.
<!-- evidence-check: on -->

## 10. Pre-PR checklist (copy into the PR body)

```markdown
- [ ] Class(es): C_ (+C7?)  - union of gates applied (change-control §2-3)
- [ ] precommit-guard: staged before each commit AND --range "$BASE..HEAD" -> 0 FAIL; WARNs explained below
- [ ] commit-msg-check --range "$BASE..HEAD" -> 0 FAIL; PR title conventional, <= 64 chars
- [ ] N1 no api/front gitlink move (or this IS the release bump, checked with --release)
- [ ] N3 pin-sync-check -> 0 FAIL if any Dockerfile / workflow / go.mod / mise.toml changed; go.mod expression-go untouched
- [ ] N9 EP code: the §3 EP gate (ep-test.sh ok x6, PASS not below baseline, -race ok, go vet clean, gofmt -l empty, golangci-lint --new-from-rev=$BASE 0 issues); outputs pasted
- [ ] C3-vs-C4 rule applied and named (behaviour test; scoreboard moved=0 pasted for an observability-only C4-path edit)
- [ ] N4 queries: explicit columns, deleted_at IS NULL, organization_id, exact anchored SQL pinned in sqlmock (incl. HasPayInAdvanceCharge if touched)
- [ ] N5 side effects use the batch ctx from processRecordsAndCommit, never the process/signal ctx
- [ ] N7 commit/retry/DLQ change: kfake ledger test + GOFLAGS=-race kfake run + ADR-001 points implemented (DECIDED OD-2; a deviation needs the owner first) + owner sign-off, or "N7: not applicable because ..."
- [ ] N6 contract change: K# named; a paired PR <link> in each repo whose external dependent is touched, or "no external dependent of K# is touched" (DECIDED OD-4); versioned name, deploy order, rollback; or "N6: not applicable because ..."
- [ ] N8 no per-event Rails resolution added
- [ ] N10 git status clean apart from intended files; no build outputs
- [ ] N11 no secrets added; nothing printed from history
- [ ] N12 dev env: one env file, idempotent topics, service_healthy infra edges; compose config --quiet OK
- [ ] N13 every claim has path:line / sha / command; UNVERIFIED, OPEN DECISION OD-n and DECIDED OD-n labelled
- [ ] N2 no force-push on this branch from now on
- [ ] Reviewers per change-control §8 (owner for C4/C7)
```

## Scripts

All are read-only and run from anywhere in the repo. `-C <dir>` points them at the bare
history clone. Exit codes: 0 = no FAIL, 1 = FAIL, 2 = usage error or unknown revision.
Each prints its usage with `-h`.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/precommit-guard.sh` | staged (default), `--range A..B` or `--commit sha` check: G1 gitlinks (N1), G2 secrets without printing values (N11), G3 pins and `@latest` (N3; G3-latest* skip `.claude/`), G4 stray files and binaries, G5 dev compose (N12). `--release`, `--allow RULE`, `-q` | `precommit-guard.sh --range "$BASE..HEAD"` | clean: `SUMMARY precommit-guard: 0 FAIL, 0 WARN`. Replays (`-C "$H" --commit <sha> -q`): `12b8101` 2 FAIL G1-gitlink; `16c8b68` 1 FAIL G2-lago-license; `5077151` 1 FAIL G3-pins; `ba292b6 --release` 0 FAIL; `01cfbc6 --release` 1 WARN (no gitlink moved); `c80a7b5` 1 WARN G5-env-dup; `5308258` 2 WARN G3-latest-image |
| `scripts/pin-sync-check.sh` | PS1 lago-expression ref x4, PS2 Rust x2, PS3 Go x5, PS4 expression-go v0.1.4, PS5 `go install @latest`. Working tree, `--index` or `--rev` | `pin-sync-check.sh` | `OK    PS1 lago-expression ref v0.2.0 in 4 places: …`, `OK    PS3 Go 1.25 everywhere (5 places): …`, `SUMMARY pin-sync-check: 0 FAIL, 0 WARN` (level column padded to 5). `--rev 5077151`: FAIL PS2 (rust:1.82 vs 1.85); `--rev 50015b0^`: FAIL PS3; `--rev 07d1d4d^`: 5 FAIL (unpinned clones, `@latest`) |
| `scripts/commit-msg-check.sh` | M1 > 72 FAIL, M2 > 50 WARN, M3 not conventional, M4 unknown type (WARN for `release` while OD-7 is open), M5 trailing `.`, M6 WIP/fixup, M7 line 2 not blank. File (commit-msg hook), `-m`, `--range`, `--since`; `--report`, `--exclude-bots` | `commit-msg-check.sh -C "$H" --since 2025-01-01 --report` | `293 subjects; >72: 29; >50: 142; non-conventional: 35; unknown type: 3; release type (WARN, OD-7): 8; WIP/fixup: 0; FAIL subjects: 65; WARN-only subjects: 116; bot-authored included: 17` |

Optional local hooks. These write only into your `.git/hooks`, which is not tracked. Run
from the repo root:

```bash
ln -sf "$PWD/.claude/skills/change-control/scripts/precommit-guard.sh"  "$(git rev-parse --git-path hooks)/pre-commit"
ln -sf "$PWD/.claude/skills/change-control/scripts/commit-msg-check.sh" "$(git rev-parse --git-path hooks)/commit-msg"
```

Verified in a scratch clone (2026-10-01): a 1-of-4 lago-expression bump was refused by the
pre-commit hook (`FAIL  PS1 lago-expression refs disagree`), a `WIP:` subject by the commit-msg
hook (M3, M6); the 4-of-4 bump committed; `Merge ...` subjects are skipped. Bypass
(`git commit --no-verify`) only deliberately, saying why in the PR; for a release bump only after
a clean `precommit-guard.sh --release` (0 FAIL) run.

## Provenance and maintenance

- **Sources.**
  - `CONTRIBUTING.md:166-173`, `PULL_REQUEST_TEMPLATE.md`, `.gitmodules`, `docs/dev_environment.md:248-286`,
    `.github/workflows/events-processor-tests.yml`, `.github/workflows/release-docker-image.yml:28-30`, the
    events-processor Dockerfiles, `go.mod`, `mise.toml`, `docker-compose.dev.yml`.
  - `$API/AGENTS.md:30-68,163-178`, `$API/docs/dropping_columns_and_tables.md`; the K dependents
    in `reference/cross-repo-protocol.md` §1 (`$API`, `$FRONT`, lago-helm-charts `d473b1e`, 2026-10-02).
  - All shas in `reference/non-negotiables.md`, read with `git -C "$H" show`.
- **Paths:** `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`;
  `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (`front` for `$FRONT`).
- **Volatile facts, one re-check each** (as of 2026-10-01):
  - Pins: `git ls-tree HEAD api front` -> `591ae90…` / `0c5e539…`.
  - Pin set: `.claude/skills/change-control/scripts/pin-sync-check.sh -q` -> `SUMMARY pin-sync-check: 0 FAIL, 0 WARN`.
  - PR CI scope: `sed -n 7,13p .github/workflows/events-processor-tests.yml` -> `pull_request` with `paths: "events-processor/**"`.
  - Lint baseline, in `events-processor/`: `golangci-lint run --allow-serial-runners ./... | tail -3` -> `21 issues:` (errcheck 16, staticcheck 5; v2.5.0, no ep-env.sh needed).
  - Patch float: `curl -fsS https://hub.docker.com/v2/repositories/library/golang/tags/1.25 | grep -o '"digest":"[^"]*'` -> same digest as tag `1.25.14` (needs network).
  - C3-vs-C4 baseline: `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh --check-baseline | tail -1` -> `scoreboard: moved=0 unmeasured=0 targets_missed=12 …`, exit 0 (a `--check-*` run with skipped rows exits 5, never 0).
  - Pass count: `.claude/skills/build-and-env/scripts/ep-test.sh -v -count=1 ./... 2>&1 | grep -c -- '--- PASS'` -> `235`.
  - N4 residual: `sed -n 59,66p events-processor/models/billable_metrics.go` -> still `.First(`.
  - N7 gap: `grep -rn "processRecordsAndCommit" --include=*_test.go events-processor` -> no output.
  - CODEOWNERS: `find . -iname 'CODEOWNERS*' -not -path './.git/*'` -> no output.
  - Bus factor: `git -C "$H" log --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -1` -> `55 Vincent Pochet` (of 72).
  - Pin moves: `git -C "$H" log --since=2025-01-01 --oneline -- api front | wc -l` -> `77` (60 release, 2 corrective, 15 non-release).
  - Contract dependents (2026-10-02): `grep -rn kafka_topic_list "$API/db/clickhouse_migrate"` -> 7 queue migrations, of which raw, enriched and dead-letter read K2/K4/K6 (the others: enriched_expanded, activity, api and security logs); `grep -rn docker-build-multi-arch "$API/.github"` -> no output (K10 has only the lago-front caller).
  - Floating versions: `git grep -n '@latest' -- ':!.claude'` -> only `docker/Dockerfile:12` (`pnpm@latest`).
  - No `expression-go/v0.2.0` tag: `git ls-remote --tags https://github.com/getlago/lago-expression | grep expression-go` -> tags `expression-go/v0.1.0` (plus its `^{}` line) and `expression-go/v0.1.4`; no `v0.2.0` (needs network).
  - Conventions: `.claude/skills/change-control/scripts/commit-msg-check.sh -C "$H" --since 2025-01-01 --report` -> `293 subjects; >72: 29; >50: 142; …; FAIL subjects: 65`.

**Update triggers.** Re-verify this skill on: a release bump (new pins); an edit to a pin file
or `events-processor-tests.yml`; a new PR workflow or required check; a CODEOWNERS file or a
golangci config; the owner answering or amending any OD (incl. OD-1b, an ADR-001 amendment); a
contract anchor or dependent moving (re-run the greps behind `reference/cross-repo-protocol.md`
§1); a new incident; a rewrite of CONTRIBUTING.md or the PR template.
