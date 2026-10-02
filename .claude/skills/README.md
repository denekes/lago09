# Lago skill library (`.claude/skills/`)

Sixteen skills for working in this umbrella repo: the Go `events-processor/`, the CI and release
workflows, docker compose dev and self-host, `deploy/`, and the docs. A skill loads from the
`description` in its `SKILL.md` frontmatter. This README is not loaded automatically. It is the
index for people and agents.

- **If the Skill tool does not list a skill, read `.claude/skills/<name>/SKILL.md` directly.** The
  session listing is a snapshot with a size budget. Descriptions are kept to 600 characters or fewer
  so that all 16 fit.
- **HEAD convention.** Code facts are as of `5308258` (events-processor tree `83e012866f29`). The
  working branch may carry skills-only commits on top. `5308258` is the head of the fork. Upstream
  `getlago/lago` main is `a0de065` (2026-09-29), and its gitlinks are identical. Claims about lago-api
  say "at the pin `591ae90` (2026-09-08)".
- Run every command from the repo root: `cd "$(git rev-parse --show-toplevel)"`.
- **Postgres after a restart.** The sandbox Postgres 16 does not survive a container restart. Run
  `pg_isready -d postgres://lago:lago@localhost:5432/lago`. If it fails, run `pg_ctlcluster 16 main start`.
  Role and database `lago`/`lago` must exist (`build-and-env` "Postgres for tests"; the symptom when they
  are missing is `build-and-env` B6). Until Postgres is back,
  `config/database` tests panic in `TestNewConnection`, and `baseline.sh` and `scoreboard.sh` cannot
  run.

## Start here (pick your situation)

Every first command below was run on 2026-10-02 in this sandbox. The Expect column is the observed
output.

<!-- evidence-check: off routing table; every row was run on 2026-10-02 and its observed output is the Expect cell -->
| You are ... | Load | First command | Expect (observed 2026-10-02) |
|---|---|---|---|
| new, in a fresh session or sandbox ("where do I start") | `build-and-env` | `.claude/skills/build-and-env/scripts/doctor.sh`, then `.claude/skills/build-and-env/scripts/ep-test.sh` | `doctor: 0 FAIL(s)`, exit 0 (one WARN: shallow working clone); then 6 `ok` packages (cache, config/database, config/kafka, models, processors/events_processor, utils), ~5 s warm, 60-75 s cold |
| holding an error string, a log line or a wrong count | `debugging-playbook` | `.claude/skills/debugging-playbook/scripts/explain-error.sh 'panic: brokers not found'` (paste your first error line) | `[start-brokers] (startup) LAGO_KAFKA_BOOTSTRAP_SERVERS is empty or unset ...` then cause/confirm/fix lines, exit 0. An unknown string exits 1 |
| about to commit, open or review a PR | `change-control` | `.claude/skills/change-control/scripts/precommit-guard.sh` | `SUMMARY precommit-guard: 0 FAIL, 0 WARN (nothing to check)` with nothing staged, exit 0 |
| adding or reviewing a test, preparing PR evidence | `validation-and-qa` | `.claude/skills/validation-and-qa/scripts/baseline.sh` | `pass.total 235`, `cover.total 47.4`, `lint.total 21`, `SUMMARY baseline: 0 FAIL, 0 WARN (baseline as_of 2026-10-01 head 5308258; go test exit 0; ...)`, exit 0, ~11 s warm (needs Postgres) |
| reading or changing consumer/processor/cache/models code | `architecture-contract` (then `failure-archaeology`) | `.claude/skills/architecture-contract/scripts/topic-map.sh --no-api` | topic, group and key names per plane, last line `SUMMARY flags=0`, exit 0 |
| asking "why is it like this / was this tried before?" | `failure-archaeology` | `.claude/skills/failure-archaeology/scripts/chain.sh --for events-processor/config/kafka/consumer.go` | `Primary chains for ... consumer.go ...: A J`, then chain A steps `cec0eb2 656c829 600e195 b604769 b6d3616 9acd83e`, exit 0 |
| changing anything lago-api or ClickHouse also reads | `rails-go-parity` | `.claude/skills/rails-go-parity/scripts/parity-constants.sh -q` | `summary: OK=27 KNOWN=12 INFO=4 FAIL=0 CHANGED=0`, exit 0 |
| fixing lost, zeroed or mis-timed events | `event-accounting-campaign` | `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh` | `scoreboard: moved=0 unmeasured=0 targets_missed=12 (baseline 2026-10-01; ...)`, exit 0, ~15 s (needs Postgres) |
| asking what a billing term means or who does what | `domain-reference` | `.claude/skills/domain-reference/scripts/where-is.sh charge_filter` | `== events-processor @ 5308258` and `== lago-api @ 591ae90 ($API)` blocks with `path:line` hits, exit 0 |
| setting or adding an env var, or a flag "does nothing" | `config-and-flags` | `.claude/skills/config-and-flags/scripts/bool-semantics.sh LAGO_CLICKHOUSE_ENABLED` | per-site idiom table, `Verdict: MIXED ...`, `Safe to turn OFF everywhere: <unset> ""`, exit 1 (1 = MIXED) |
| bringing up a stack or operating the events-processor | `run-and-operate` | `.claude/skills/run-and-operate/scripts/compose-matrix.sh --brief` | `RESULT: all 6 compose file(s) valid`, exit 0 (no Docker daemon needed) |
| cutting a release, an image is missing, editing workflows | `release-and-images` | `.claude/skills/release-and-images/scripts/release-pin-audit.sh` | 52 tag rows, last line `# audited=52 ok=48 not-ok=4`, exit 1 (known: v1.41.1-v1.41.3, v1.52.1) |
| needing a runtime measurement (kfake, smoke, overlay, ClickHouse) | `diagnostics-and-tooling` | `.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh --check` | `franz-go: events-processor=v1.20.5 harness=v1.20.5`, `kfake-run: check OK`, exit 0 |
| verifying a claim, mining history, reading lago-api | `research-methodology` | `H=$(.claude/skills/research-methodology/scripts/history-setup.sh); git -C "$H" rev-list --count HEAD` | `776` |
| editing or trusting a doc; writing a commit, PR, ADR | `docs-and-writing` | `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh -q` | `SUMMARY doc-drift-check: entries=42 STALE=40 PASS=0 RECHECK=0 OPEN=1 KNOWN=1 SKIP=0 ...`, exit 40 (= STALE count; known) |
| hardening a self-host; secrets, pinning, PII | `security-and-supply-chain` | `.claude/skills/security-and-supply-chain/scripts/secret-defaults-scan.sh` | `SUMMARY secret-defaults-scan: placeholders=50 (selfhost=35) sensitive_ports=18 (selfhost=12) redis_noauth=4 history_literal=0`, exit 0 |
<!-- evidence-check: on -->

Typical chains:

- An error: `debugging-playbook`, then the owning skill it names, then the `change-control` gate for the fix.
- A code change: `architecture-contract` and `failure-archaeology`, then `validation-and-qa`, then
  `change-control` (its "Pre-PR gate for events-processor code").
- An owner decision: the register is `change-control` §9 (OD-1..OD-20: default, who decides, closing
  evidence). Raise one as a GitHub issue titled "OD-n: <topic>".

## The 16 skills (one line each)

<!-- evidence-check: off index table; each skill carries its own evidence -->
| Skill | Owns | Not for |
|---|---|---|
| `architecture-contract` | as-is events-processor topology, startup, concurrency, commit and disposition, DB vs memory-cache mode, invariants, weak points | live triage, fixes |
| `build-and-env` | environment from zero, the Docker-free CGO recipe, the foundation scripts, version matrix, build traps | test policy, images |
| `change-control` | classes C0-C7, gates, non-negotiables N1-N13, cross-repo contracts K1-K10, the OD register, PR checklist | running tests, release steps |
| `config-and-flags` | every config plane, the env registry, boolean traps, add-a-variable checklist | bring-up, secrets policy |
| `debugging-playbook` | symptom -> cause -> confirm -> fix router, DLQ codes, costly traps; `explain-error.sh` | building probes, history |
| `diagnostics-and-tooling` | probe harnesses: kfake, binary smoke, `-overlay`, scratch Postgres, clickhouse local | conclusions, test policy |
| `docs-and-writing` | docs inventory, stale-claim register SC-01..SC-42, templates, style | the facts themselves |
| `domain-reference` | billing glossary with code locations, event lifecycle, misconceptions | Go/Rails contracts |
| `event-accounting-campaign` | the decision-gated plan W1-W5 that makes every raw record accountable | as-is behaviour, triage |
| `failure-archaeology` | chains A-N and X1-X13, do-not-re-fight rules, history scripts | current behaviour |
| `rails-go-parity` | Go vs Rails/ClickHouse contract rows, payload schemas, pinned-SHA drift, parity probes | glossary, fixes |
| `release-and-images` | release runbook, workflow inventory, artifact matrix, all-in-one image sync, actionlint | commit rules, local builds |
| `research-methodology` | hypothesis cards, evidence bar, history and pinned-checkout scripts, registry probing, owner-question wording | findings, harnesses |
| `run-and-operate` | variants, bring-up runbooks, output map, events-processor ops, partitioning, monitoring | variable meaning, images |
| `security-and-supply-chain` | insecure defaults, TLS, secrets in history (counts only), pinning, PII, C7 checklist | config meaning, release |
| `validation-and-qa` | evidence per class, baselines (235 PASS, 47.4% gated coverage, 21 lint issues), test conventions, harness defects | toolchain, probes |
<!-- evidence-check: on -->

## Foundation scripts

Any skill may cite these five paths. Cite other scripts by skill name, or by a path verified to exist.

<!-- evidence-check: off index table; interfaces are documented in each script's header and in build-and-env / research-methodology -->
| Script | Use |
|---|---|
| `.claude/skills/build-and-env/scripts/ep-env.sh` | `source` it before `go build`/`go test` of events-processor (works from any cwd). Not needed for `go vet` or golangci-lint |
| `.claude/skills/build-and-env/scripts/ep-test.sh` | Docker-free `go test` (default `-count=1 ./...`; `--no-cgo` runs the 5 packages that do not link libexpression_go) |
| `.claude/skills/build-and-env/scripts/doctor.sh` | read-only readiness report (OK/WARN/FAIL/INFO); exit code = number of FAILs |
| `.claude/skills/research-methodology/scripts/history-setup.sh` | prints `$H`, a blob-less full-history bare clone (the working clone is shallow) |
| `.claude/skills/research-methodology/scripts/pinned-checkout.sh api\|front [full-sha]` | prints `$API`/`$FRONT`, lago-api/lago-front at the gitlink SHA (the submodules are empty here) |
<!-- evidence-check: on -->

`build-and-env` also ships `dc.sh`, an alias-free stand-in for the docs' `lago` alias
(`docker compose -f docker-compose.dev.yml`). `dc.sh config --services` works without a daemon.

## Cache directory

Everything heavy lives outside the repo in `${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}`.
Probes never write into the repo (change-control N10). Everything here can be deleted and is
rebuilt on demand. It was about 4 GB on 2026-10-02.

<!-- evidence-check: off inventory of the cache dir (ls of the cache on 2026-10-02) -->
| Path | Written by | What |
|---|---|---|
| `lago-expression-<ref>/` | `ep-env.sh` | lago-expression checkout at the Dockerfile ref (v0.2.0) and the built `target/release/libexpression_go.so` |
| `lago-history.git` | `history-setup.sh` | blob-less bare clone with full history (776 commits at `5308258`; fork remote, no tags) |
| `lago-api@<sha12>/`, `lago-front@<sha12>/` | `pinned-checkout.sh` | depth-1 checkouts at a gitlink SHA. Old SHAs pile up and can be deleted |
| `clickhouse/<ver>/clickhouse` | `diagnostics-and-tooling` `ch-local.sh` (`ch-local.sh --path` prints it) | shared ClickHouse binary. A legacy `clickhouse-<ver>/` is reused by `rails-go-parity` `ch-decimal-probe.sh` |
| `kfake-harness-bin/<GOFLAGS hash>/` | `kfake-run.sh` | built kfake harness binaries |
| `golangci-cache/` | `baseline.sh` | `GOLANGCI_LINT_CACHE` |
| `tools/actionlint-<v>/`, `tools/shellcheck-<v>/` | `release-and-images` `actionlint-local.sh` | pinned linters (actionlint 1.7.7, shellcheck 0.11.0) |
| `rails-go-parity/lago-expression.git` | `parity-constants.sh` | lago-expression history for the expression-version rows |
<!-- evidence-check: on -->

## ID registry (one owner per prefix)

Cite an ID from another skill as `<skill> <ID>`, for example `change-control N7` or
`architecture-contract I12`. The prefixes below are current as of 2026-10-02.

<!-- evidence-check: off registry table; ranges were read from the skill files with grep on 2026-10-02 -->
| Owner | Prefixes |
|---|---|
| `change-control` | C0-C7 change classes; N1-N13 non-negotiables; K1-K10 cross-repo contracts; OD-1..OD-20 owner decisions (§9; OD-10..OD-15 were release-and-images REL-1..REL-6); script rule ids G1-G5 (`precommit-guard.sh`), PS1-PS5 (`pin-sync-check.sh`), M1-M7 (`commit-msg-check.sh`) |
| `failure-archaeology` | A-N events-processor chains; X1-X13 infra chains |
| `architecture-contract` | I1-I15 invariants; L1-L7 loss modes; WP1-WP26 weak points; D1-D21 design decisions; startup-contract probe ids S0-S7 and SK1-SK9 |
| `rails-go-parity` | P1-P34 contract rows (each maps to a change-control K#); DR1-DR8 pinned-SHA drift items |
| `domain-reference` | LC1-LC17 lifecycle steps; MC1-MC17 misconceptions; E1-E7 worked-example events |
| `docs-and-writing` | SC-01..SC-42 stale claims; S1-S12 style rules; T1-T3 trust levels |
| `debugging-playbook` | T1-T16 traps; E1-E8 events-processor sections; BT1-BT14 build/test lookup rows; DEV1-DEV14 dev rows; CI1-CI5; RD1-RD6 release-day rows; SH1-SH4 self-host rows; `explain-error.sh` entry ids such as `start-brokers` |
| `build-and-env` | B1-B15 trap reproductions; trap-table rows 5.1-5.20 |
| `run-and-operate` | R1-R7 runbooks; DC1-DC10, DS1-DS11 defect rows; PD1-PD5 partitioning defects |
| `security-and-supply-chain` | SD1-SD13 self-host insecure defaults |
| `validation-and-qa` | HD1-HD7 harness defects |
| `diagnostics-and-tooling` | H1-H11 harness catalogue rows |
| `event-accounting-campaign` | W1-W5 workstreams |
| `research-methodology` | RM-<id> hypothesis cards; CC1-CC8, CD1-CD3, CM1-CM3, CV1-CV3 conflict cases |
| `config-and-flags` | GAP1-GAP6 `env-crossref.sh` gap codes |
| `release-and-images` | all-in-one "break 1..5" |
<!-- evidence-check: on -->

Letters overlap across skills (T# in docs-and-writing and debugging-playbook, E# in domain-reference
and debugging-playbook). The skill prefix in a citation tells them apart.

## Maintaining the library

Skill docs (`.claude/skills/**/*.md`) are change class C0; skill scripts (`.claude/skills/**/scripts/**`)
are C1 (`change-control` §2). The per-skill checklist is `docs-and-writing`
`reference/templates.md` §6.

Update triggers. Re-verify the owning skills when one of these happens:

- the `api`/`front` gitlinks move (a release bump): `rails-go-parity`, `domain-reference`,
  `config-and-flags`, `release-and-images`, and every "at the pin" claim;
- events-processor code changes: `architecture-contract`, `validation-and-qa` (re-baseline with
  `baseline.sh --write` only through a PR), `rails-go-parity`, `event-accounting-campaign`
  (`scoreboard.sh --check-baseline`), `debugging-playbook` patterns;
- a workflow, Dockerfile or compose file changes: `release-and-images`, `run-and-operate`,
  `security-and-supply-chain`, `build-and-env`;
- a doc changes: `docs-and-writing` (`doc-drift-check.sh`, `docs-to-recheck.sh`);
- an owner decides an OD-n: `change-control` §9 first, then every skill that cites that OD;
- the HEAD convention moves to a new code commit: the as-of line of all 16 SKILL.md files.

Re-verify the whole library (all commands are read-only):

```bash
cd "$(git rev-parse --show-toplevel)"
# frontmatter parses, name == dir, description <= 600 characters
python3 -c "import yaml,re,glob,os
for f in sorted(glob.glob('.claude/skills/*/SKILL.md')):
    d=yaml.safe_load(re.match(r'^---\n(.*?)\n---\n',open(f).read(),re.S).group(1))
    assert d['name']==os.path.basename(os.path.dirname(f)) and len(d['description'])<=600, f"
for f in .claude/skills/*/scripts/*.sh; do bash -n "$f" || echo "SYNTAX $f"; done
.claude/skills/research-methodology/scripts/evidence-check.sh -q .claude/skills/*/SKILL.md
# every cited skill script path exists
grep -rhoE '\.claude/skills/[a-z0-9-]+/scripts/[A-Za-z0-9_./-]*[A-Za-z0-9_]' .claude/skills | sort -u | while read -r p; do test -e "$p" || echo "MISSING $p"; done
# self-tests and baselines
.claude/skills/debugging-playbook/scripts/explain-error.sh --self-test
.claude/skills/failure-archaeology/scripts/chain.sh --verify
.claude/skills/domain-reference/scripts/lifecycle-check.sh
.claude/skills/build-and-env/scripts/doctor.sh && .claude/skills/build-and-env/scripts/ep-test.sh
.claude/skills/validation-and-qa/scripts/baseline.sh
.claude/skills/event-accounting-campaign/scripts/scoreboard.sh --check-baseline
```

Expected: no Python error, no `SYNTAX` or `MISSING` lines, `explain-error` `self-test: OK`, `chain.sh`
exit 0, `doctor: 0 FAIL(s)`, `SUMMARY baseline: 0 FAIL`, `scoreboard: moved=0 unmeasured=0`.

To add a skill:

<!-- evidence-check: off procedure, not claims -->
1. Create `.claude/skills/<name>/SKILL.md` with the skeleton in `docs-and-writing`
   `reference/templates.md` §6. Put long tables in `reference/` and scripts in `scripts/`. Scripts are
   read-only on the repo and write only to the cache directory or a temp dir.
2. Write a description of 600 characters or fewer: what the skill is, a trigger clause ("Use when ...",
   "Use for ...", "Use on ..." or "Use before ..."), then "Not for ... (use <sibling>)". An exact error
   string may appear in only ONE description (skill bodies may repeat it):
   `grep -H '^description:' .claude/skills/*/SKILL.md | grep -cF -- '<string>'` prints `1`.
3. Add the skill to this README: the start-here table (with an observed first command), the index,
   and the ID registry. Its ID prefixes must not reuse a prefix that another skill owns.
4. Run the re-verify block above, then `.claude/skills/change-control/scripts/precommit-guard.sh` and
   `.claude/skills/change-control/scripts/commit-msg-check.sh` before committing.
<!-- evidence-check: on -->
