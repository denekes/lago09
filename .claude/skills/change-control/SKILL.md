---
name: change-control
description: Change-control rules for the Lago umbrella repo (getlago/lago with the Go events-processor). Covers how to classify a change (C0-C7), the gates and evidence each class needs before commit, PR and merge, the non-negotiables N1-N13 with the incident behind each, commit/PR conventions as practised, the cross-repo contract protocol with lago-api, submodule and pin hygiene, review routing, and the owner OPEN decisions OD-1..OD-9. Use when about to commit, open or review a PR, or on "Subproject commit" in a diff, "M api"/"M front" in git status, a gitlink move, "bump lago-expression"/rust/go version, "@latest", go.mod expression-go, subscription_refreshed_v2, a topic or consumer-group rename, a Kafka commit/retry/DLQ change, force-push, "subject too long", misc type, ING-/INF- tickets, "paired lago-api PR", "what gates does this need". Not for running tests (validation-and-qa), CGO build errors (build-and-env), cutting a release (release-and-images), or incident narratives (failure-archaeology).
---
# Change control: classes, gates, non-negotiables

This skill says what must be true before a commit, a PR or a merge lands, in this repo and
across repos. It covers the gates for each change class, the 13 non-negotiables, and the
incident behind each one. It also owns the owner's OPEN decisions.
Facts verified 2026-10-01 against HEAD 5308258 unless marked. The working branch may carry
skill-library commits on top; project facts are as of `5308258`.

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

## Terms

| Term | Meaning here |
|---|---|
| gitlink | The `api` / `front` tree entries (mode 160000) that pin a submodule commit. |
| release bump | The PR that moves both gitlinks and the `docker-compose.yml:11,13` image tags to `vX.Y.Z` (example `ba292b6`). |
| pin set | Values that must move together: the lago-expression ref (4 places), the Rust image (2), Go major.minor (5). |
| contract | Data or names another repo reads or writes: K1-K10 in `reference/cross-repo-protocol.md`. |
| versioned name | A new key, topic or field name used when a format changes (`subscription_refreshed` -> `subscription_refreshed_v2`, `42615c9`). |
| EP | `events-processor/`, the only first-party code in this repo. |
| `BASE` | `git merge-base origin/main HEAD`: the point the PR diff starts from. |
| gate / evidence block | A check that must pass, and its output pasted into the PR body. |
| ADR | A short design note in the PR (template in `docs-and-writing`). |
| OD-n | An OPEN DECISION that only the owner can take (§9). Label it "OPEN DECISION OD-n (owner)" wherever you rely on its default. |
| N#, C#, G#/P#/M# | Non-negotiable (§4), change class (§2), and the rule ids printed by the three scripts (§Scripts). |
| `$API`, `$FRONT`, `$H` | Pinned lago-api and lago-front checkouts and the full-history clone, from the research-methodology scripts (see Provenance). |

## 1. The flow for every change

1. **Classify** the diff with §2. Several classes can match. Apply the union of their gates.
2. **Before each commit**, run `.claude/skills/change-control/scripts/precommit-guard.sh`.
   Expect `SUMMARY precommit-guard: 0 FAIL`.
3. **Run the class gates** (§3; the exact commands are in `reference/change-classes.md`).
4. **Before opening the PR**, run
   `precommit-guard.sh --range "$BASE..HEAD"` and `commit-msg-check.sh --range "$BASE..HEAD"`.
5. **Write the PR.**
   - Paste the evidence block.
   - Explain every WARN.
   - Label every OPEN DECISION you depend on.
   - Route review (§8).
6. **Never force-push the PR branch** (N2). Fix forward with new commits; the squash merge
   collapses them.

## 2. Classify: C0-C7

| Class | Typical paths | Tell-tale |
|---|---|---|
| C0 docs/skills | `*.md`, `docs/*.png`, `.claude/skills/**/*.md` | nothing executable changes |
| C1 tests/tooling | `events-processor/**/*_test.go`, `events-processor/tests/**`, `.claude/skills/**/scripts/**` | no production `.go` file changes, no existing expectation changes |
| C2 EP refactor | `events-processor/**/*.go` | tests, SQL strings, payloads and contract files all unchanged |
| C3 EP behaviour | `enrichment_service.go`, `utils/time.go`, `models/*.go` queries, `cache/*.go` | an expected value, SQL string, timestamp, DLQ code or matching rule changes |
| C4 delivery/contract | `config/kafka/consumer.go`, `producer.go`, disposition in `processor.go:50-88`, `event_producer_service.go`, JSON tags in `models/event.go`, `models/stores.go`, topic/group names, `connectors/*.yml` mappings, `extra/debezium_config.json`, `docker-build-multi-arch.yaml` | commit, retry, DLQ or skip semantics change, or anything lago-api or lago-front reads or writes |
| C5 release/pins/CI | `api`, `front`, `.gitmodules`, `docker-compose.yml:11,13`, `.github/workflows/**`, `events-processor/Dockerfile*`, `docker/Dockerfile`, `events-processor/go.mod`, `go.sum`, `mise.toml` | a version, pin, image, workflow or dependency changes |
| C6 dev env/deploy | `docker-compose.dev.yml`, `docker-compose.yml` (non-image), `.env.development.default`, `deploy/**`, `docker/runner.sh`, `traefik/**`, `scripts/**`, `extra/**` | how a stack is configured or started changes |
| C7 security overlay | any path | secrets, TLS/auth, ports, docker.sock, `.gitignore`, new actions, images or binaries, workflow permissions, PII |

How to apply the table:

- Use the union of all matching rows. C7 adds to whatever else matches.
- A path that matches nothing: take the strictest plausible class and say so in the PR.
- The three classifier one-liners and the full behaviour tests are in
  `reference/change-classes.md` §1.

## 3. Gates per class (summary)

| Class | Local gates (beyond G0 = guard + msg check + `git diff --stat`) | Evidence in PR | Sign-off | Consult |
|---|---|---|---|---|
| C0 | Each claim has `path:line`, a sha, or a command and its output; each documented command was run | claims checked + commands | any maintainer; owner for doctrine edits | docs-and-writing, research-methodology |
| C1 | `ep-test.sh`; `ep-test.sh -race -count=1 ./...`; PASS count does not drop (235); a regression test fails on base | test summary lines | area maintainer | validation-and-qa, diagnostics-and-tooling |
| C2 | N9: `ep-test.sh` ok x6, `go vet` clean, `gofmt -l` empty on changed files, `golangci-lint --new-from-rev=$BASE` 0 issues, `-race` ok | the C2 evidence block | EP maintainer | validation-and-qa, build-and-env |
| C3 | C2 + a test pinning the new behaviour; N4 SQL rules with SQL pinned in sqlmock; both data modes; parity cites `$API` file:line; value/time before-and-after on the corpus | + test names, parity cites, before/after | EP maintainer; owner if N8 or OD-3 | rails-go-parity, architecture-contract, event-accounting-campaign |
| C4 | C3 + kfake test driving `processRecordsAndCommit` (N7) + ADR + paired lago-api PR, versioned name, deploy order, rollback (N6) | + ledger output, ADR, lago-api PR link, deploy order | owner (OD-2, OD-4) + lago-api owner | cross-repo-protocol, event-accounting-campaign, diagnostics-and-tooling |
| C5 | `pin-sync-check.sh` 0 FAIL; full C2 gate for dependency or pin bumps; YAML parse; `--release` for bumps; images "not built locally" | + pin-sync output | CI/release owner | release-and-images, build-and-env |
| C6 | `docker compose -f <f> config --quiet` for every touched compose file; `bash -n` on scripts; N12 (guard G5) | + config output, service diff | dev-env/infra maintainers | run-and-operate, config-and-flags |
| C7 | guard G2 + `security-and-supply-chain` scans; rotate anything ever pushed; never print values | counts and file:line only | owner (security) | security-and-supply-chain |

CI is not a safety net here:

- The only PR workflow is `events-processor-tests.yml`. It is path-filtered to
  `events-processor/**` (`.github/workflows/events-processor-tests.yml:7-13`).
- It runs only `go test -v ./...` (`:63-64`).
- Docs, compose, workflow, deploy and Dockerfile-only PRs get **no** PR check at all.

## 4. Non-negotiables N1-N13

The full rule, why, incident, cost and check for each is in `reference/non-negotiables.md`.
Every sha below was read in the history clone.

| # | Rule (short) | Incident (sha, PR, cost) | Check |
|---|---|---|---|
| N1 | Never stage or commit an `api`/`front` gitlink move outside a release bump | `12b8101` (#618) moved both pins in a Traefik fix; reverted by `647de3e` (#620) the same day; 15 non-release moves since 2025-01-01 (one, `190aa81`, downgraded front v1.33.4 -> v1.33.2) | guard G1; §5 |
| N2 | Never force-push a branch with an open PR, or `main` | `5308258` body: PR #800 "was force-pushed onto main… the original is unrecoverable"; rebuilt from lago-deploy#3331 | confirm no open PR before any `--force*` push |
| N3 | Pin set moves together; nothing floats; leave `go.mod:10` expression-go v0.1.4 | `5077151` (#666) bumped the ref in all 3 places of the time but left the prod Dockerfile on rust:1.82; `e8bbd60` (#667) "Fix prod release" 81 min later; `d589940` (#586) `air@latest` broke the dev build; `932c06c` -> `50015b0` Go realign. Residual: `docker/Dockerfile:12` still runs `corepack prepare pnpm@latest` | `pin-sync-check.sh`; guard G3 |
| N4 | EP SQL: explicit columns, `deleted_at IS NULL`, `organization_id`, SQL pinned in sqlmock | `bd92069` -> `9acd83e` (#735, ING-15) SQLSTATE 0A000 for about 5.5 months; `fff5858` -> `8ceca4b` (#740) deleted BMs matched for 18 days; `9ef876a` (#738, ING-123); residual: `models/billable_metrics.go:59-66` | grep in non-negotiables §N4 |
| N5 | Per-record side effects use a per-record context | `b6d3616` -> `02a4bc8` (#785): `context canceled` on every rolling restart for about 9 months | context-field grep (6 known hits) |
| N6 | Cross-repo contracts change with lago-api: versioned, ordered deploy, paired PR (OD-4) | `7421650` -> `42615c9` (SET -> ZSET + `_v2`) -> `fb6401d` (15 s -> 10 s) -> `b4ad153`: 4 protocol changes in 15 months | `reference/cross-repo-protocol.md` |
| N7 | No commit/delivery change without a kfake test + ADR + owner sign-off (OD-2) | `cec0eb2` -> `600e195` -> `b6d3616` -> `9acd83e` (ING-15): 13 months, ended "segfaulting the pod inside franz-go" | no test calls `processRecordsAndCommit` today |
| N8 | Go never re-implements Rails resolution per event | `flat_filters` saga, about 15 months and 7 fix commits, removed by `d9c32b6` (#797) as "the main database load"; Go cache expiry removed by `2fd8e8b` (#766) | review |
| N9 | EP pre-PR gate: tests, vet, gofmt, no new lint; paste evidence | CI runs `go test -v` only; lint baseline 21 issues (OD-6) | C2 gate commands |
| N10 | Probes never write into the repo | the README's `go build -o event_processors .` leaves an un-ignored 58 MB binary | `git status --porcelain`; guard G4 |
| N11 | No real secrets in tracked files; never print historical values | `LAGO_LICENSE` value public 43 days (`16c8b68` -> `6dd7e56` #477); rotation UNVERIFIED (OD-9) | guard G2 |
| N12 | One dev env file; idempotent topics; infra edges `service_healthy` | `0ca6cdf` (#424), `3cd78f1` (#611) env drift; `c80a7b5` (#580) startup races; `5477e39` (#581) topic creation | guard G5; `compose config --quiet` |
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

**Traps** (verified with git 2.43 in a scratch clone, 2026-10-01):

- A populated `api/` checked out at another commit shows as ` M api`. Then `git add -A`,
  `git add -u` and `git commit -a` all stage the move. Add paths explicitly.
- `diff.ignoreSubmodules=all` and `submodule.api.ignore=all` **hide** that ` M api` drift
  from `git status`, and hide a **staged** move from `git diff --cached` (also with
  `--submodule` or `--stat`). `git status` does still list a staged move as `M  api`.
  They do **not** stop `git add -A` or `git add -u` from staging the move silently.
  (`git commit -a` skipped it under `diff.ignoreSubmodules=all` but staged it under
  `submodule.api.ignore=all`.) Never rely on them. The guard always passes
  `--ignore-submodules=none`.
- After working inside `api/` (`docs/dev_environment.md:251-262`), reset the submodule
  checkouts to the recorded pins:
  `git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init -- api front`.
  The URLs in `.gitmodules:3,6` are SSH. Verified in a scratch clone for `front` (with
  `--depth 1`): it checked out the recorded pin `0c5e539`.
- `docs/dev_environment.md:266-278` ("Updating a reference … `git push origin main`")
  contradicts N1. Ignore it. `docs-and-writing` tracks the correction.

**Bumping the lago-expression ref** (C5):

1. Change the ref in all four places:
   - `events-processor/Dockerfile:5`
   - `events-processor/Dockerfile.dev:5`
   - `events-processor/Dockerfile.staging:23` (`ARG LAGO_EXPRESSION_REF`)
   - `.github/workflows/events-processor-tests.yml:45`
2. If the new ref needs a newer Rust, move `FROM rust:` in both `Dockerfile:1` and
   `Dockerfile.dev:1`.
3. Run `.claude/skills/change-control/scripts/pin-sync-check.sh`. Expect `0 FAIL`.
4. `source .claude/skills/build-and-env/scripts/ep-env.sh`. It reads the ref from the
   Dockerfile and builds that `.so` into the cache. Then run the full C2 gate.
5. Do **not** touch `events-processor/go.mod:10` (`expression-go v0.1.4`). The guard fails on
   it (G3-expression-go).
6. Expect the PR CI to run, because the Dockerfiles live under `events-processor/**`.

**Bumping Go:** the same discipline over 5 places: `go.mod:3`, `mise.toml:2`, `Dockerfile:7`,
`Dockerfile.dev:7` (all under `events-processor/`), and
`.github/workflows/events-processor-tests.yml:61`. A dependabot bump can raise the `go`
directive on its own: `932c06c` (#724) moved it, and `50015b0` (#725) realigned the rest 50
minutes later.

## 6. Cross-repo contract changes (N6, OPEN DECISION OD-4)

Contracts are listed in `reference/cross-repo-protocol.md` §1 with anchors on both sides:

- K1 Redis ZSET `subscription_refreshed_v2`;
- K2 the raw payload;
- K3 the `api_post_processed` split;
- K4-K6 the enriched, in-advance and DLQ topics and payloads;
- K7 consumer-group naming;
- K8 Rails columns that Go selects;
- K9 Debezium columns;
- K10 the reusable workflow called by lago-front `@main`.

The protocol, in short:

1. **Additive first.** If a format changes, use a **new versioned name**.
2. **ADR in the PR.** It covers both mixed-version windows, the deploy order, the rollback and
   the cleanup owner.
3. **Paired lago-api PR.** Required by default (OD-4). Link both PRs both ways. Each side pins
   the format in a test.
4. **Deploy order.** The **tolerant reader ships first**, the writer switches second, and
   cleanup comes a release later.
   - Go writes K1, K4, K5 and K6, so lago-api ships first.
   - Rails writes K2 and K3, so the EP ships first.
   - Rails column drop (K8): the EP stops selecting the column in release N; Rails drops it in
     N+1 (`$API/docs/dropping_columns_and_tables.md`).
5. **Rollback.** Roll back the **writer first**. Irreversible steps (column drops, topic
   deletion, ClickHouse DDL) happen only in cleanup.

## 7. Commit and PR conventions (OPEN DECISION OD-7)

The details are in `reference/commit-pr-conventions.md`. Measured over the 293 non-merge
commits since 2025-01-01:

| Topic | Stated | Practised |
|---|---|---|
| Subject length | <= 72 (`CONTRIBUTING.md:170`); <= 50 (`$API/AGENTS.md:52`) | 29 over 72, 142 over 50 |
| Format | Conventional Commits | 88% conventional; 211 of 258 carry a scope; ticket as a `[ING-123] ` prefix or a `Refs:` trailer |
| Types | AGENTS list incl. `misc` (`$API/AGENTS.md:47`) | chore 74, misc 69 (279 all-time), fix 55, feat 43; `release:` 8 (not in the list) |
| Merging | one squashed commit (`PULL_REQUEST_TEMPLATE.md:12`) | 216 of 293 end in `(#NNN)`; 48 merge commits |
| Branches | `fix/` or `feature/` MUST (`PULL_REQUEST_TEMPLATE.md:8`) | 0 of either in 48 merge subjects |
| Body | `## Context` / `## Description` (`$API/AGENTS.md:37-43`) | 64% empty; 18 with `## Context` |
| Tests | `pnpm test` (`PULL_REQUEST_TEMPLATE.md:14`) | not applicable: no `package.json` |

Defaults we operate under until the owner decides OD-7:

- Conventional Commits; `misc` allowed.
- Subject <= 72 hard and <= 50 preferred, measured as it lands on main. Keep PR titles
  <= 64 characters to leave room for ` (#NNNN)`.
- A Context/Description body for C3, C4, pin-related C5, C7 and incident fixes.
- No WIP or fixup subjects on main.
- Branch names not enforced.
- `scripts/commit-msg-check.sh` enforces the subject rules.

## 8. Review routing

- **No CODEOWNERS.** None exists in this repo or its history, nor in lago-api at the pin.
  `find . -iname 'CODEOWNERS*' -not -path './.git/*'` prints nothing, and so does
  `git -C "$H" log --all --oneline -- CODEOWNERS .github/CODEOWNERS`.
- **Required checks unknown.** Branch protection and required status checks cannot be seen
  from git: UNVERIFIED.
- **Route by history.** Unless the row says otherwise: non-merge commits since 2025-01-01,
  from `git -C "$H" log --no-merges --since=2025-01-01 --format=%an -- <path>` (as of
  2026-10-01):

  | Area (pathspec) | Most history (commits) | Note |
  |---|---|---|
  | `events-processor` (all time, path as named since the 2025-03-21 rename; command in Provenance) | Vincent Pochet 55 of 72 non-dependabot (62 of 79 with `events_processor` added) | **bus factor 1**: also ask a second reviewer (Jérémy Denquin 5, Maxime Vidori 4, Thomas Battiston 3) |
  | `.github/workflows` | Maxime Vidori 12, Vincent Pochet 8, Jérémy Denquin 8, Kyriakos Oikonomakos 5 | reusable workflow and ECR/OIDC |
  | `docker-compose.dev.yml .env.development.default` | Vincent Pochet 13, Yohan R. 11, Romain Sempé 7, Jérémy Denquin 7 | |
  | release bumps (the 60 bump commits among the 77 `api`/`front` moves) | rotates over 15 authors: Vincent Pochet 12, Ancor Cruz 8, Toon Willems 6, Anna Velentsevich 5, … | `release-and-images` |
  | `docs` + root `*.md` (`docs CODE_OF_CONDUCT.md CONTRIBUTING.md PULL_REQUEST_TEMPLATE.md README.md`) | Maxime Vidori 10, Vincent Pochet 6 | |

- **Rules.**
  - C4 and C7 need the owner on top of the area reviewer.
  - Contract changes need the lago-api owner of the other side (OD-4).
  - AI review comments, such as the Copilot comments addressed in `c340ddf`, never replace a
    human sign-off.
- **Bus-factor rule.** One maintainer holds most events-processor context. Every C3+ PR body
  must stand alone: Context, Description, evidence, decisions. Never "as discussed".

## 9. OPEN decisions OD-1..OD-9 (owned here)

Other skills label these `OPEN DECISION OD-n (owner)` and route them here. Never present one as
settled.

| ID | Open decision | Default until decided | Who decides | Evidence that closes it |
|---|---|---|---|---|
| OD-1 | Does production run `LAGO_USE_MEMORY_CACHE=true` (badger + Debezium CDC)? With which column list, SASL/TLS and brokers? | UNKNOWN. DB mode is the default path. Memory-cache defects are real in code; their prod impact is UNVERIFIED | owner + the prod deploy owner (private lago-deploy) | prod EP env and the live Debezium `column.include.list`, secrets masked |
| OD-2 | Delivery contract for retryable failures: block the partition, retry topic, or bounded skip-to-DLQ? Is 12 h a product decision? | none chosen. `event-accounting-campaign` ranks options. No delivery change merges without ADR + owner sign-off (N7) | owner (product + engineering) | ADR with the fault-matrix ledger (target 0 LOST) and throughput per option |
| OD-3 | Is a ClickHouse schema change acceptable (e.g. `events_enriched.decimal_value Decimal(38,26)`), and with what migration budget? | not approved. Prefer fixes without a ClickHouse schema change (exact decimal strings, detect-and-DLQ overflow) | owner + lago-api maintainers (Cloud DDL edited in place, `$API/AGENTS.md:176`) | value-corpus magnitudes affected; self-host + Cloud migration plan |
| OD-4 | Is a paired lago-api PR mandatory for cross-repo contract changes? | YES (conservative), N6 | owner | written policy recorded here |
| OD-5 | Is `ep-test.sh` (Docker-free) an accepted pre-PR gate, or is `lago exec events-processor go test ./...` mandatory? | accepted: it mirrors CI's shape (host-built `libexpression_go.so`, `go test ./...` against Postgres, no Docker). `lago exec` stays valid | owner, with the EP maintainer | owner confirmation, then fix `events-processor/CLAUDE.md:10` (C0) |
| OD-6 | golangci-lint policy and config (none committed, ever; 21 issues today) | "no NEW issues vs base" (`--new-from-rev`). No config file without approval | owner, with the EP maintainer | proposed `.golangci.yml` + full-run count + CI job PR |
| OD-7 | Subject limit 50 or 72; is `misc` sanctioned; branch-name policy | <= 72 hard, <= 50 preferred; `misc` allowed (279 uses); branch names not enforced | owner | CONTRIBUTING.md / PULL_REQUEST_TEMPLATE.md rewritten (C0) |
| OD-8 | Prod state of lago-api flags `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` | UNKNOWN. Drift findings say "impact depends on OD-8" | owner / lago-api maintainers | per-org flag state from prod |
| OD-9 | Was the `LAGO_LICENSE` value (`16c8b68` -> `6dd7e56`) rotated? Was ING-123 (`9ef876a`) a cross-tenant leak? | UNKNOWN, labelled UNVERIFIED. Never print the value | owner (security) | rotation record (date only); ING-123 ticket text |

**Closing an OD:**

1. The owner states the decision in an issue or PR.
2. A C0 PR updates this row: decision, date and link. The owner signs it off.
3. The same PR updates the skills that carry the label:
   `grep -rn "OD-<n>" .claude/skills`.
4. If the decision changes a gate, update the scripts' defaults too. For OD-7, change
   `commit-msg-check.sh --max/--pref`.

## 10. Pre-PR checklist (copy into the PR body)

```markdown
- [ ] Class(es): C_ (+C7?)  - union of gates applied (change-control §2-3)
- [ ] precommit-guard: staged before each commit AND --range "$BASE..HEAD" -> 0 FAIL; WARNs explained below
- [ ] commit-msg-check --range "$BASE..HEAD" -> 0 FAIL; PR title conventional, <= 64 chars
- [ ] N1 no api/front gitlink move (or this IS the release bump, checked with --release)
- [ ] N3 pin-sync-check -> 0 FAIL if any Dockerfile / workflow / go.mod / mise.toml changed; go.mod expression-go untouched
- [ ] N9 EP code: ep-test.sh ok x6, -race ok, go vet clean, gofmt -l empty, golangci-lint --new-from-rev=$BASE 0 issues (outputs pasted)
- [ ] N4 queries: explicit columns, deleted_at IS NULL, organization_id, exact SQL pinned in sqlmock
- [ ] N5 side effects take the per-record ctx
- [ ] N7 commit/retry/DLQ change: kfake test + ADR + owner sign-off (OD-2)
- [ ] N6 contract change: paired lago-api PR <link>, versioned name, deploy order, rollback (OD-4)
- [ ] N8 no per-event Rails resolution added
- [ ] N10 git status clean apart from intended files; no build outputs
- [ ] N11 no secrets added; nothing printed from history
- [ ] N12 dev env: one env file, idempotent topics, service_healthy infra edges; compose config --quiet OK
- [ ] N13 every claim has path:line / sha / command; UNVERIFIED and OPEN DECISION OD-n labelled
- [ ] N2 no force-push on this branch from now on
- [ ] Reviewers per change-control §8 (owner for C4/C7)
```

## Scripts

All are read-only and run from anywhere in the repo. `-C <dir>` points them at the bare
history clone. Exit codes: 0 = no FAIL, 1 = FAIL, 2 = usage error or unknown revision.
Each prints its usage with `-h`.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/precommit-guard.sh` | staged (default), `--range A..B` or `--commit sha` check: G1 gitlinks (N1), G2 secrets without printing values (N11), G3 pins and `@latest` (N3), G4 stray files and binaries, G5 dev compose (N12). `--release`, `--allow RULE`, `-q` | `precommit-guard.sh --range "$BASE..HEAD"` | clean: `SUMMARY precommit-guard: 0 FAIL, 0 WARN`. Replays (`-C "$H" --commit <sha> -q`): `12b8101` 2 FAIL G1-gitlink; `16c8b68` 1 FAIL G2-lago-license; `5077151` 1 FAIL G3-pins; `ba292b6 --release` 0 FAIL; `01cfbc6 --release` 1 WARN (no gitlink moved); `c80a7b5` 1 WARN G5-env-dup; `5308258` 2 WARN G3-latest-image |
| `scripts/pin-sync-check.sh` | P1 lago-expression ref x4, P2 Rust x2, P3 Go x5, P4 expression-go v0.1.4, P5 `go install @latest`. Working tree, `--index` or `--rev` | `pin-sync-check.sh` | `OK    P1 lago-expression ref v0.2.0 in 4 places: …`, `OK    P3 Go 1.25 everywhere (5 places): …`, `SUMMARY pin-sync-check: 0 FAIL, 0 WARN` (level column padded to 5). `--rev 5077151`: FAIL P2 (rust:1.82 vs 1.85); `--rev 50015b0^`: FAIL P3; `--rev 07d1d4d^`: 5 FAIL (unpinned clones, `@latest`) |
| `scripts/commit-msg-check.sh` | M1 > 72 FAIL, M2 > 50 WARN, M3 not conventional, M4 unknown type, M5 trailing `.`, M6 WIP/fixup, M7 line 2 not blank. File (commit-msg hook), `-m`, `--range`, `--since`; `--report`, `--exclude-bots` | `commit-msg-check.sh -C "$H" --since 2025-01-01 --report` | `293 subjects; >72: 29; >50: 142; non-conventional: 35; unknown type: 11; WIP/fixup: 0; FAIL subjects: 73; WARN-only subjects: 108; bot-authored included: 17` |

Optional local hooks. These write only into your `.git/hooks`, which is not tracked. Run
from the repo root:

```bash
ln -sf "$PWD/.claude/skills/change-control/scripts/precommit-guard.sh"  "$(git rev-parse --git-path hooks)/pre-commit"
ln -sf "$PWD/.claude/skills/change-control/scripts/commit-msg-check.sh" "$(git rev-parse --git-path hooks)/commit-msg"
```

Verified in a scratch clone (2026-10-01): a 1-of-4 lago-expression bump was refused by the
pre-commit hook (`FAIL P1 lago-expression refs disagree`), a `WIP:` subject was refused by
the commit-msg hook (M3, M6), and the 4-of-4 bump with a conventional subject committed.
The commit-msg hook skips git-generated `Merge ...` subjects. Bypass only deliberately
(`git commit --no-verify`) and say why in the PR.

## Provenance and maintenance

- **Sources.**
  - `CONTRIBUTING.md:166-173`, `PULL_REQUEST_TEMPLATE.md`, `.gitmodules`.
  - `.github/workflows/events-processor-tests.yml`, `.github/workflows/release-docker-image.yml:28-30`.
  - The events-processor Dockerfiles, `go.mod`, `mise.toml`, `docker-compose.dev.yml`,
    `docs/dev_environment.md:248-286`.
  - `$API/AGENTS.md:30-68,163-178`, `$API/docs/dropping_columns_and_tables.md`.
  - All shas in `reference/non-negotiables.md`, read with `git -C "$H" show`.
- **Paths:**
  - `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`
  - `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`
  - `FRONT=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)`
- **Volatile facts, one re-check each** (as of 2026-10-01):
  - Pins: `git ls-tree HEAD api front` -> `591ae90…` / `0c5e539…`.
  - Pin set: `.claude/skills/change-control/scripts/pin-sync-check.sh -q` -> `SUMMARY pin-sync-check: 0 FAIL, 0 WARN`.
  - PR CI scope: `sed -n 7,13p .github/workflows/events-processor-tests.yml` -> `pull_request` with `paths: "events-processor/**"`.
  - Lint baseline: `( source .claude/skills/build-and-env/scripts/ep-env.sh && cd events-processor && golangci-lint run ./... | tail -3 )` -> `21 issues` (errcheck 16, staticcheck 5).
  - Pass count: `.claude/skills/build-and-env/scripts/ep-test.sh -v -count=1 ./... 2>&1 | grep -c -- '--- PASS'` -> `235`.
  - N4 residual: `sed -n 59,66p events-processor/models/billable_metrics.go` -> still `.First(`.
  - N7 gap: `grep -rn "processRecordsAndCommit" --include=*_test.go events-processor` -> no output.
  - CODEOWNERS: `find . -iname 'CODEOWNERS*' -not -path './.git/*'` -> no output.
  - Bus factor: `git -C "$H" log --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -1` -> `55 Vincent Pochet` (of 72).
  - Pin moves: `git -C "$H" log --since=2025-01-01 --oneline -- api front | wc -l` -> `77` (60 release, 2 corrective, 15 non-release).
  - Floating versions: `git grep -n '@latest' -- ':!.claude'` -> only `docker/Dockerfile:12` (`pnpm@latest`).
  - No `expression-go/v0.2.0` tag: `git ls-remote --tags https://github.com/getlago/lago-expression | grep expression-go` -> tags `expression-go/v0.1.0` (plus its `^{}` line) and `expression-go/v0.1.4`; no `v0.2.0` (needs network).
  - Conventions: `.claude/skills/change-control/scripts/commit-msg-check.sh -C "$H" --since 2025-01-01 --report` -> `293 subjects; >72: 29; >50: 142`.
- **Update triggers.** Re-verify this skill when any of these happens:
  - a release bump (new pins);
  - any edit to a pin file or to `events-processor-tests.yml`;
  - a new PR workflow or required check;
  - a CODEOWNERS file or a golangci config lands;
  - the owner answers any OD;
  - a contract anchor moves (re-run the `$API` greps in `reference/cross-repo-protocol.md`);
  - a new incident;
  - CONTRIBUTING.md or the PR template is rewritten.
