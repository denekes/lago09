# Lago skill library (`.claude/skills/`)

Nineteen skills. Sixteen are for working in this umbrella repo: the Go `events-processor/`, the CI
and release workflows, docker compose dev and self-host, `deploy/`, and the docs. Three form the
re-implementation kit (`reimplementation-kit`, `events-processor-spec`, `billing-engine-spec`): a
behaviour specification plus conformance vectors for rebuilding or re-platforming the events-processor
and the in-scope lago-api billing engine without their source. A skill loads from the
`description` in its `SKILL.md` frontmatter. This README is not loaded automatically. It is the
index for people and agents.

- **If the Skill tool does not list a skill, read `.claude/skills/<name>/SKILL.md` directly.** The
  session listing is a snapshot with a size budget. Descriptions are kept to 600 characters or fewer
  so that all 19 fit.
- **HEAD convention.** Code facts are as of `5308258` (events-processor tree `83e012866f29`). The
  working branch may carry skills-only commits on top. `5308258` is the head of the fork. Upstream
  `getlago/lago` main is `a0de065` (2026-09-29), and its gitlinks are identical. Claims about lago-api
  say "at the pin `591ae90` (2026-09-08)".
- Run every command from the repo root: `cd "$(git rev-parse --show-toplevel)"`.
- **Owner decisions of 2026-10-02** (register: `change-control` §9). DECIDED: OD-1 production runs
  the memory cache (memory-cache findings are production-relevant; test cache mode too); OD-2
  delivery follows ADR-001 in `event-accounting-campaign` (delegated); OD-3 a ClickHouse schema
  change is acceptable; OD-4 a paired PR is needed only in repos that depend on the changed
  contract (`change-control` K1-K10 dependents); OD-5 the Docker-free `ep-test.sh` is an accepted
  pre-PR gate. OPEN and urgent: OD-1b, the production Debezium column list and CDC Kafka
  auth/brokers. DEFAULT APPLIED: OD-20, memory-cache hardening is campaign W6. DECIDED OD-24: the
  kit's clean-room test runs from a pack-only branch `kit-pack-v1` in fresh remote sessions. PROPOSED
  (open): OD-21 the rebuild-decision batch (`reimplementation-kit` RBD rows marked "proposed"), OD-22
  retry-topic naming, OD-23 legal review of the kit and the lago-expression licence.
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
| fixing lost, zeroed or mis-timed events | `event-accounting-campaign` | `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh` | `scoreboard: moved=0 unmeasured=0 targets_missed=13 (baseline 2026-10-01, cache_* 2026-10-02; ...)`, exit 0, ~20-25 s (needs Postgres) |
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
- A rebuild or re-platform: `reimplementation-kit` (method, vector format, `kitrun.py`, grading), then
  `events-processor-spec` and/or `billing-engine-spec` for the behaviour; `reimplementation-kit`
  `reference/rebuild-decisions.md` says where the kit expects as-is (compat) vs corrected behaviour.
- An owner decision: the register is `change-control` §9 (OD-1..OD-24 plus OD-1b: decision or
  default, who decides, record or closing evidence). Cite a decided one as "DECIDED OD-n (owner,
  <date>)" and an open one as "OPEN DECISION OD-n (owner)". Raise a new one as a GitHub issue titled
  "OD-n: <topic>".

## The 19 skills (one line each)

<!-- evidence-check: off index table; each skill carries its own evidence -->
| Skill | Owns | Not for |
|---|---|---|
| `architecture-contract` | as-is events-processor topology, startup, concurrency, commit and disposition, DB vs memory-cache mode, invariants, weak points | live triage, fixes |
| `build-and-env` | environment from zero, the Docker-free CGO recipe (an accepted pre-PR gate, DECIDED OD-5), the foundation scripts, version matrix, build traps | test policy, images |
| `change-control` | classes C0-C7, gates, non-negotiables N1-N13, cross-repo contracts K1-K10 with their external dependents, the owner-decision register, PR checklist | running tests, release steps |
| `config-and-flags` | every config plane, the env registry, boolean traps, add-a-variable checklist | bring-up, secrets policy |
| `debugging-playbook` | symptom -> cause -> confirm -> fix router, DLQ codes, costly traps; `explain-error.sh` | building probes, history |
| `diagnostics-and-tooling` | probe harnesses: kfake, binary smoke, `-overlay`, scratch Postgres, clickhouse local | conclusions, test policy |
| `docs-and-writing` | docs inventory, stale-claim register SC-01..SC-42, templates, style | the facts themselves |
| `domain-reference` | billing glossary with code locations, event lifecycle, misconceptions | Go/Rails contracts |
| `event-accounting-campaign` | the decision-gated plan W1-W6 that makes every raw record accountable (W6 memory-cache correctness, DEFAULT APPLIED OD-20); ADR-001, the delivery contract (DECIDED OD-2) | as-is behaviour, triage |
| `failure-archaeology` | chains A-N and X1-X13, do-not-re-fight rules, history scripts | current behaviour |
| `rails-go-parity` | Go vs Rails/ClickHouse contract rows, payload schemas, pinned-SHA drift, parity probes | glossary, fixes |
| `release-and-images` | release runbook, workflow inventory, artifact matrix, all-in-one image sync, actionlint | commit rules, local builds |
| `research-methodology` | hypothesis cards, evidence bar, history and pinned-checkout scripts, registry probing, owner-question wording | findings, harnesses |
| `run-and-operate` | variants, bring-up runbooks, output map, events-processor ops, partitioning, monitoring | variable meaning, images |
| `security-and-supply-chain` | insecure defaults, TLS, secrets in history (counts only), pinning, PII, C7 checklist | config meaning, release |
| `validation-and-qa` | evidence per class, baselines (235 PASS, 47.4% gated coverage, 21 lint issues), test conventions, harness defects | toolchain, probes |
| `reimplementation-kit` | kit method, vector format and adapter protocol, `kitrun.py` and `validate-vectors.py`, grading thresholds, rebuild decisions RBD-1..RBD-106, the KQ register; maintainer-only: the pinned lago-api oracle (`scripts/maintainer/oracle.sh`), holdout and pack tools | the behaviour itself (spec skills), working on this repo's code |
| `events-processor-spec` | neutral behaviour spec of the events-processor (EP-* rules: wire formats, processing, delivery and failures, memory-cache mode), the black-box conformance suite EPC-00..EPC-34 (`run-suite.sh --impl-cmd`), `ep.*` unit vectors | as-is code reading (`architecture-contract`), fixing this repo (`event-accounting-campaign`) |
| `billing-engine-spec` | neutral behaviour spec of the in-scope lago-api billing engine in 14 chapters (BE-* rules: domain, ingestion, expressions, aggregation, pricing, periods, invoices, credit notes, wallets, progressive billing and alerts, REST API, webhooks, clock), unit vectors and `scn.*` end-to-end scenarios | lago-api source questions (`domain-reference`), Go/Rails contracts (`rails-go-parity`) |
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
| `lago-api-run@591ae90/`, `k7-state/` (`redis/`, `ch/`, `runs/`, `ch.lock`, `bundle.lock`), `rubies/`, `micromamba-root/` | `reimplementation-kit` `scripts/maintainer/oracle.sh` | the maintainer oracle: a writable lago-api copy at the pin with its bundle, Ruby 4.0.6 from conda-forge, a private Redis on :6391 and ClickHouse on :8123, run logs. About 2.9 GB |
| `ep-reference/<tree>/`, `epconf-bin/<hash>/`, `epconf-runs/`, `epconf-regen/`, `epconf-selftest-venv/` | `events-processor-spec` `run-suite.sh` and its maintainer scripts | the Go reference build of the events-processor tree, the conformance runner binary, suite runs and golden regeneration scratch |
<!-- evidence-check: on -->

## ID registry (one owner per prefix)

Cite an ID from another skill as `<skill> <ID>`, for example `change-control N7` or
`architecture-contract I12`. The prefixes below are current as of 2026-10-02.

<!-- evidence-check: off registry table; ranges were read from the skill files with grep on 2026-10-02 -->
| Owner | Prefixes |
|---|---|
| `change-control` | C0-C7 change classes; N1-N13 non-negotiables; K1-K10 cross-repo contracts; OD-1..OD-24 and OD-1b owner decisions (§9; OD-10..OD-15 were release-and-images REL-1..REL-6); script rule ids G1-G5 (`precommit-guard.sh`), PS1-PS5 (`pin-sync-check.sh`), M1-M7 (`commit-msg-check.sh`) |
| `failure-archaeology` | A-N events-processor chains; X1-X13 infra chains |
| `architecture-contract` | I1-I15 invariants; L1-L9 loss modes; WP1-WP28 weak points; D1-D21 design decisions; startup-contract probe ids S0-S7 and SK1-SK9 |
| `rails-go-parity` | P1-P38 contract rows (each maps to a change-control K#); DR1-DR8 pinned-SHA drift items |
| `domain-reference` | LC1-LC17 lifecycle steps; MC1-MC28 misconceptions; E1-E7 worked-example events |
| `docs-and-writing` | SC-01..SC-42 stale claims; S1-S12 style rules; T1-T3 trust levels |
| `debugging-playbook` | T1-T16 traps; E1-E8 events-processor sections; BT1-BT14 build/test lookup rows; DEV1-DEV14 dev rows; CI1-CI5; RD1-RD6 release-day rows; SH1-SH4 self-host rows; `explain-error.sh` entry ids such as `start-brokers` |
| `build-and-env` | B1-B15 trap reproductions; trap-table rows 5.1-5.20 |
| `run-and-operate` | R1-R7 runbooks; DC1-DC10, DS1-DS11 defect rows; PD1-PD5 partitioning defects |
| `security-and-supply-chain` | SD1-SD13 self-host insecure defaults |
| `validation-and-qa` | HD1-HD7 harness defects |
| `diagnostics-and-tooling` | H1-H13 harness catalogue rows |
| `event-accounting-campaign` | W1-W6 workstreams; ADR-001 (delivery contract); ledger fault cases 1-16 (15-16 opt-in) |
| `research-methodology` | RM-<id> hypothesis cards; CC1-CC8, CD1-CD3, CM1-CM3, CV1-CV3 conflict cases |
| `config-and-flags` | GAP1-GAP6 `env-crossref.sh` gap codes |
| `release-and-images` | all-in-one "break 1..5" |
| `reimplementation-kit` | RBD-1..RBD-106 rebuild decisions (`reference/rebuild-decisions.md`); KQ-n kit questions; CRC-1..CRC-10 clean-room components; vector ids `<area>.<file>.<op>.NNN[x]` (an `x` suffix is a corrected twin) |
| `events-processor-spec` | EP-<letter><n> rules (e.g. EP-H8); EPC-00..EPC-34 conformance scenarios |
| `billing-engine-spec` | BE-DM, BE-EV, BE-EX, BE-AG, BE-PR, BE-SP, BE-IV, BE-CN, BE-WL, BE-PB, BE-AL, BE-API, BE-WH, BE-CK, BE-IF rules (one prefix per chapter); `scn.<topic>.<name>.NNN` scenarios |
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
- an owner decides an OD-n: `change-control` §9 first, then every skill that cites that OD; an OD-21
  ruling flips the named `reimplementation-kit` RBD rows and their corrected vectors from `proposed` to
  `decided`;
- the lago-api pin moves: re-run every billing vector and scenario against the new oracle
  (`reimplementation-kit` "update triggers"), triage each diff as a behaviour change or a kit defect, and
  re-mint; events-processor code changes: re-run the conformance suite against the new reference
  (`events-processor-spec`, goldens only through its reviewed regeneration);
- the HEAD convention moves to a new code commit: the as-of line of all 19 SKILL.md files.

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
# re-implementation kit: vector format, gates and its own runners
python3 .claude/skills/reimplementation-kit/scripts/validate-vectors.py --gate --rule-coverage
.claude/skills/reimplementation-kit/scripts/kit-selftest.sh
```

Expected: no Python error, no `SYNTAX` or `MISSING` lines, `explain-error` `self-test: OK`, `chain.sh`
exit 0, `doctor: 0 FAIL(s)`, `SUMMARY baseline: 0 FAIL`, `scoreboard: moved=0 unmeasured=0`,
`SUMMARY validate-vectors: ... errors=0`, `SUMMARY kit-selftest: steps=7 pass=7 fail=0 skip=0`.

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
