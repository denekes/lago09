---
name: docs-and-writing
description: "Docs of record for the Lago umbrella repo and how to keep them true: inventory of docs and agent files with trust levels, a register of 42 verified doc-vs-code contradictions (SC-01..SC-42) with corrections checked by doc-drift-check.sh, a code-to-doc map, templates for commits, PR bodies, incident notes, ADRs and skill updates, style rules. Use when editing, quoting or trusting a doc, when a doc and the code disagree (\"the docs say\", \"stale doc\"), or when writing a commit message, PR body, ADR or incident write-up. Not for the facts themselves (owning skills) or gates (use change-control)."
---
# Docs and writing: docs of record, stale claims, templates, style

This skill keeps the repo's written record honest. It answers four questions: which doc to trust;
which claims are known wrong and what the corrected text is; how to write commits, PRs, ADRs and
incident notes that the next engineer can act on; and which docs to re-check when code changes.

Facts verified 2026-10-01 unless marked. Code facts as of `5308258` (events-processor tree
`83e012866f29`); the working branch may carry skills-only commits on top. lago-api at the pin
`591ae90` (v1.53.0, 2026-09-08); full-history clone `$H` (776 commits as of 2026-10-01).

## When to use / when NOT to use

Use it when:

- you are about to quote, follow or edit a doc. Check its trust level and open entries first
  (section 1);
- a doc and the code disagree, or someone says "the docs say X". Look up the register (section 2);
- you write a commit message, PR body, incident write-up, ADR or runbook section (section 3);
- you change code or config and must know which docs to re-check (section 5);
- you write or update a skill in `.claude/skills/` (`reference/templates.md` §6).

Do NOT use it for:

- the facts behind a doc. Config semantics are in `config-and-flags`; runtime topology in
  `architecture-contract`; Rails/Go contracts in `rails-go-parity`; the domain glossary in
  `domain-reference`; bring-up in `run-and-operate`; the toolchain and the `lago` alias trap in
  `build-and-env`.
- gates, change classes and commit/PR rules: `change-control`. This skill holds the templates that
  `change-control` points to.
- release notes and the release train: `release-and-images`.
- verifying a hunch or linting citations: `research-methodology` owns the evidence bar and its
  evidence-check script.
- incident history: `failure-archaeology`. Its ledger shape is reused by the incident template here.

## Terms

- **Doc of record**: a file people or agents follow as instructions or reference: the human docs
  plus the agent files `events-processor/CLAUDE.md`, `$API/AGENTS.md` and `$API/CLAUDE.md`.
- **Stale claim / register entry (SC-NN)**: a verified contradiction between a doc of record and
  the code, the config or another doc. Listed in `reference/stale-claims.md`.
- **Claim side / anchor side**: `doc-drift-check.sh` greps the doc for the wrong text (claim) and
  greps the code for the evidence that makes it wrong (anchor).
- **Check statuses**:
  - STALE: still wrong.
  - PASS: the claim is gone from the doc.
  - RECHECK: the claim is present but the anchor moved.
  - OPEN: an owner decision is pending.
  - KNOWN: an immutable record.
  - SKIP: a source is missing.
- **Trust level**: T1 authoritative, T2 mostly right, T3 verify first, MKT marketing, EXT vendored
  (`reference/inventory.md`).
- **Alias-free**: a command spelled with `docker compose -f <file>` instead of the `lago` shell
  alias. The alias is defined at `docs/dev_environment.md:53`, and non-interactive shells never load
  it.
- **`$API`**: lago-api at the pinned gitlink, from
  `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.
- **`$H`**: the full-history clone, from
  `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`.

## 1. Docs of record at a glance

Full table (purpose, audience, main authors, freshness, trust, entries): `reference/inventory.md`.
Read it before you cite a doc.

| Doc | Last touched | Trust | Open entries |
|---|---|---|---|
| `events-processor/CLAUDE.md` (the only agent file in the repo) | 2026-03-05 `c340ddf` | T3 | SC-01 |
| `events-processor/README.md` | 2026-09-18 `d9c32b6` | T3 | SC-02 to SC-10 |
| `docs/architecture.md` + `docs/arch_diagram.png` | 2026-09-01 `4230f1f` | T3 semantics, T2 tables | SC-18 to SC-26 |
| `docs/dev_environment.md` | 2026-09-03 `8f8334e` | T2 | SC-12 to SC-17, SC-39 |
| `docs/database_partitioning.md` | 2026-02-12 `4cba248` | design T1, retroactive steps T3 | SC-27, SC-28, SC-42 |
| `docs/monitoring.md` | 2026-01-12 `206646b` | T3 | SC-23, SC-29 |
| `deploy/README.md` | 2026-01-12 `206646b` | T3 | SC-30 (`deploy/deploy.sh`: SC-31) |
| `docker/README.md` | 2025-05-22 `dc7b513` | T2 | SC-32 |
| `connectors/README.md` | 2026-04-27 `a12752f` | T3 | SC-33, SC-40 |
| `README.md` | 2026-09-17 `eb58675` | MKT; quickstart T1 (run by `.github/workflows/docker-ci.yml:16-32`) | SC-34, SC-41 |
| `CONTRIBUTING.md`, `PULL_REQUEST_TEMPLATE.md` | 2025-09-16 | T3 | SC-35, SC-36 (OD-7) |
| `$API/AGENTS.md`, `$API/CLAUDE.md` (lago-api, read-only) | pinned v1.53.0 | T1 for lago-api conventions | SC-17, SC-36 |

Freshness is not accuracy. `d9c32b6` edited `events-processor/README.md` four days after `2fd8e8b`
had made its `LAGO_REDIS_CACHE_*` rows dead, and left those rows in (SC-05).

## 2. The stale-claim register

`reference/stale-claims.md` holds 42 entries (SC-01 to SC-42). Each has the claim, the truth with
evidence, corrected text ready to paste, and the owning change class. `scripts/doc-drift-check.sh`
re-asserts every entry. Today it prints `STALE=40 OPEN=1 KNOWN=1` (section "Scripts").

The ones that cost the most time if believed:

| ID | Doc says | Truth (evidence in the register) |
|---|---|---|
| SC-01 | `events-processor/CLAUDE.md:10`: direct `go test` "won't work locally"; always `lago exec` | It works with `CGO_LDFLAGS` + `LD_LIBRARY_PATH` (`ep-test.sh`: 6 packages ok). CI runs it on the host. Policy: OPEN DECISION OD-5 (owner) |
| SC-12 | `docs/dev_environment.md:154`: `LAGO_CLICKHOUSE_ENABLED=false` disables ClickHouse | MIXED (semantics: `config-and-flags`). The `.present?` sites (`$API/app/services/events/stores/store_factory.rb:10`) stay ON; org creation (`$API/app/services/organizations/create_service.rb:17`, boolean cast) turns OFF. Set it empty |
| SC-13 | `docs/dev_environment.md:158`: env files "are not interpolated" | They are: `docker compose -f docker-compose.dev.yml config api` renders `DATABASE_URL` from `${POSTGRES_USER}`… |
| SC-30 | `deploy/README.md:21` (14 commands): `docker compose up --profile all` | `unknown flag: --profile`. It is a global flag: `docker compose --profile all up` |
| SC-27 | `docs/database_partitioning.md:58-102`: 15-column DDL, then `INSERT … SELECT *` | The schema has 18 columns. Step 5 fails with "INSERT has more expressions than target columns" (reproduced) |
| SC-33 | `connectors/README.md:20`: numeric `precise_total_amount_cents` | A number passes through `connectors/http.yml:32-36`, and the events-processor (`string` field) drops the event without a DLQ |
| SC-16 | `docs/dev_environment.md:266-278`: commit the gitlink, `git push origin main` | Gitlinks move only in a release bump PR (change-control N1); changes land through a PR, never a direct push to main (change-control section 1) |
| SC-17 | `lago exec …` in 4 docs (alias at `docs/dev_environment.md:53`) | `lago` is also the getlago/lago-cli binary (no `exec`/`up`). Aliases are not expanded in agent shells (exit 127) |
| SC-39 | `docs/dev_environment.md:288-302`: Mailpit catches dev mail | lago-api sends to SMTP host `mailhog:1025` (`$API/config/environments/development.rb:70-73`); the service is `mailpit` with no alias, so sends fail even while it runs |

Rules for the register:

<!-- evidence-check: off (normative rules) -->
- **Never delete an entry.** Mark it `FIXED <date> <sha>`. The check keeps guarding against a
  regression.
- **Code-vs-code and config entries** (SC-31 `deploy/deploy.sh`, SC-34 `.env.development.default`)
  are registered so nobody re-documents them as working. Their fixes are C6, not C0.
- **Cross-repo entry** SC-37 lives in lago-api. Fix it there in a lago-api PR. SC-39's real fix is
  a compose alias (C6) or a lago-api PR; its doc note is a stopgap. **SC-38** is a commit message:
  immutable, never quote it.
- **OPEN entry** SC-36 waits on OPEN DECISION OD-7 (owner). Do not "fix" it by picking a side.
<!-- evidence-check: on -->

## 3. Templates

All templates are in `reference/templates.md`.

<!-- evidence-check: off (index of templates; sources cited in the templates file) -->
| You are writing | Template | Shape |
|---|---|---|
| a commit message | §1 | Conventional subject, optional `[ING-n] ` prefix (`0b56915`, `3ac94a2`, `9ef876a`); body A incident (`9acd83e`), B `## Context`/`## Description` (`02a4bc8`, `647de3e`), or C removal rationale (`d9c32b6`); `Refs:` trailer |
| a PR body | §2 | Context / Description / Change class / Evidence / Decisions / Cross-repo, then change-control's pre-PR checklist |
| an incident write-up | §3 | the `failure-archaeology` ledger row + symptom, root cause, evidence, fix, status, do-not-re-fight rule |
| an ADR / design note (C4, change-control N6, change-control N7) | §4 | options with measured drivers, contract before/after, mixed-version windows, failure matrix, deploy order, rollback, sign-off |
| a runbook section | §5 | When / Preconditions / numbered commands with "Expect:" / Verify / Undo / not-runnable labels |
| a skill update | §6 | frontmatter rules, skeleton order, provenance, re-verification, checks |
<!-- evidence-check: on -->

Subject rules are OPEN DECISION OD-7 (owner). Operate under the defaults: <= 72 characters hard,
<= 50 preferred, `misc` allowed, branch names not enforced, PR title <= 64 characters. The
measurements and the commit-msg check live in `change-control`.

## 4. Style rules for this repo's docs (and skills)

| # | Rule | Bad (seen here) | Good |
|---|---|---|---|
| S1 | **Every factual claim carries evidence**: `path:line`, a 7-char sha, `(#PR)`, or a command with its output (change-control N13) | "Direct `go test` won't work locally" (`events-processor/CLAUDE.md:10`, no evidence, wrong) | "`go test` needs `libexpression_go.so` on `CGO_LDFLAGS` (`events-processor/go.mod:10`); `ep-test.sh` -> ok x6 (2026-10-01)" |
| S2 | **Date-stamp volatile facts**: versions, counts, line numbers, image tags, "currently" | "Deploy images are up to date" | "`deploy/*.yml` pin `getlago/api:v1.27.1` (`deploy/docker-compose.local.yml:14`, as of 2026-10-01)" |
| S3 | **Label confidence**: VERIFIED (ran or read, with date), UNVERIFIED, CANDIDATE, OPEN DECISION OD-n (owner), TARGET. Never present a target or an open decision as the current state | "Production uses the memory cache" | "Whether production runs `LAGO_USE_MEMORY_CACHE=true` is OPEN DECISION OD-1 (owner)" |
| S4 | **No marketing in technical docs**: no unquantified superlatives ("high throughput", "robust", "simply", "seamless") in `docs/`, component READMEs, agent files or skills. Product copy stays in `README.md` | "High throughput events processor" (`events-processor/README.md:3`); "Simply go in the submodule directory" (`docs/dev_environment.md:253`) | "Consumes `LAGO_KAFKA_RAW_EVENTS_TOPIC` and produces to the enriched, in-advance and dead-letter topics (`processors/main_processor.go:118-128,171`)" |
| S5 | **Commands are copy-pasteable and alias-free.** State the cwd. Never write `lago exec` without the `docker compose -f` form beside it. No `$ ` prompts. Placeholders only as `<angle>`. Add `-T` to `exec` in non-TTY shells | `lago exec events-processor go test ./...` alone (`events-processor/CLAUDE.md:7`) | `docker compose -f "$LAGO_PATH/docker-compose.dev.yml" exec events-processor go test ./...` (alias form: `lago exec events-processor go test ./...`) |
| S6 | **Run what you document**, and paste the expected key output. If it cannot run here (no Docker daemon), say "not runnable in a daemon-less sandbox; verified by reading `<path:line>`" | `docker compose up --profile all` (never run: SC-30) | `docker compose -f deploy/docker-compose.local.yml --profile all config --services` -> 9 services |
| S7 | **No placeholders or promises.** Write what exists and link the owner of the rest | "A detailed architecture diagram will be added … in a future update" (`docs/architecture.md:532,540`) | a five-line verified flow (SC-25 corrected text) |
| S8 | **One fact, one home.** Link to the doc or skill that owns a table (env vars: `config-and-flags`) instead of copying it | the EP env table duplicated and drifting (SC-05, SC-10) | "Variables: see `config-and-flags`", plus the ones whose absence is fatal (`processors/main_processor.go:56-58,104-106`) |
| S9 | **Say which version a doc applies to** when it quotes lago-api or images | "lago-api mounts `/metrics`" | "lago-api v1.53.0 (`591ae90`) mounts Yabeda at `/metrics` (`$API/config/routes.rb:10`)" |
| S10 | **No secrets, ever.** Use `<redacted>` or placeholders. Never print a historical secret (change-control N11, OPEN DECISION OD-9) | a real licence value in `.env.development.example` (`16c8b68`, removed `6dd7e56`) | `LAGO_LICENSE=` (empty; get it from the owner) |
| S11 | **Cite line numbers with an anchor** (function or heading) and re-grep before you reuse them. Lines drift | "see main.go:56" | "`main.go:55` (`sentry.Init`, `Environment:`)" |
| S12 | **Agent files hold only commands that work in a non-interactive shell.** Test each with `bash -c '<cmd>'` | `lago exec …` (exit 127 in `bash -c`) | the `ep-env.sh`/`ep-test.sh` recipe (SC-01 corrected text) |

Run the `research-methodology` skill's evidence-check on any markdown you write (it flags claim lines
without evidence). Wrap templates and procedure blocks in
`<!-- evidence-check: off <reason> -->` … `<!-- evidence-check: on -->`, as `reference/templates.md`
does.

## 5. Doc maintenance: when code changes

Map and procedure: `reference/maintenance.md`. `scripts/docs-to-recheck.sh` applies the map to a
diff.

1. Run `.claude/skills/docs-and-writing/scripts/docs-to-recheck.sh --range origin/main..HEAD`
   (or `--staged`). Expect one `RECHECK <docs>` block per affected doc group, with the SC entries to
   look at.
2. Run `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh -q` and compare with the
   expected summary below. Any `RECHECK` line means your change moved an entry's anchor: open that
   entry.
3. Fix every sentence your change makes false in the same PR (C0 rides along), or register it
   (section 6).
4. Paste both outputs, and what you did with each line, under "Evidence" in the PR body.

Replay that shows why this exists. Run
`docs-to-recheck.sh -C "$H" --range 2fd8e8b^..2fd8e8b` (the commit that killed the Redis charge
cache). It prints a `RECHECK` block for `events-processor/README.md` (Configuration, `:32-68`) with
`SC-05` among the entries.
Nobody re-checked that README, and the dead `LAGO_REDIS_CACHE_*` rows are still there.

High-traffic mappings (all 18 rows are in the map):

| You changed | Re-check |
|---|---|
| EP env reads and Kafka client config (`main.go`, `processors/main_processor.go`, `config/tracing/*`, `config/kafka/{kafka,consumer,producer}.go`) | `events-processor/README.md` Configuration; `config-and-flags` |
| `events-processor/Dockerfile*`, `go.mod`, `events-processor-tests.yml` | `events-processor/CLAUDE.md`, README build section, the `Dockerfile.staging:20-22` comment |
| `docker-compose.dev.yml`, `traefik/*` | `docs/dev_environment.md` (hosts, volumes, services, profiles) |
| `.env.development.default` | `docs/dev_environment.md:150-158`, EP README topic examples |
| `deploy/*` / `docker/*` | `deploy/README.md` / `docker/README.md` |
| the `api` gitlink (release bump) | every SC entry anchored in `$API`: re-run `doc-drift-check.sh` |

## 6. Runbooks

### Fix a stale doc (C0)

1. Confirm the entry still holds:
   `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh --only SC-12`
   Expect: `STALE    SC-12  docs/dev_environment.md:154 … LAGO_CLICKHOUSE_ENABLED=false disables ClickHouse …`
2. Re-read the truth at its source, e.g.
   `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api); grep -n 'LAGO_CLICKHOUSE_ENABLED' "$API/app/services/events/stores/store_factory.rb" "$API/app/services/organizations/create_service.rb"`
   Expect: `…store_factory.rb:10:          ENV["LAGO_CLICKHOUSE_ENABLED"].present?` and
   `…create_service.rb:17:      if ActiveModel::Type::Boolean.new.cast(ENV["LAGO_CLICKHOUSE_ENABLED"]) …`.
3. Paste the entry's "Corrected text" into the doc. Keep the surrounding style.
4. Re-run step 1. Expect `PASS     SC-12 … -> claim gone: re-read the doc, then mark SC-12 FIXED`.
5. Check the diff: `git status --porcelain` lists only the doc, and
   `.claude/skills/change-control/scripts/precommit-guard.sh` prints `0 FAIL` (it runs
   `git diff --cached --submodule=short --ignore-submodules=none -- api front`, change-control N1).
6. Commit with `docs(<scope>): <summary>` and body shape B ("Fixes SC-12 of the docs-and-writing
   register"). Open the PR with the template in `reference/templates.md` §2.
7. After the merge, mark the entry `FIXED <date> <sha>` in `reference/stale-claims.md`, and update
   the expected summary in this file (STALE goes down by 1, PASS up by 1).

### Register a new contradiction

1. Prove it. Apply the evidence bar from `research-methodology`: a command and its output, or
   `path:line` on both sides.
2. Add `SC-<next>` to the summary table and the entries in `reference/stale-claims.md`: claim,
   truth, corrected text, class.
3. Add a check to `scripts/doc-drift-check.sh`. Copy an `E+=(scNN)` block: `claim()` greps the
   wrong text in the doc, and `truth()` greps the code anchor. Use `api_f` for `$API` files.
4. Run `doc-drift-check.sh --only SC-<next>`. Expect `STALE`. Then update the expected counts here
   and in Provenance.
5. If the doc is not in `reference/inventory.md` yet, add it. If its code path is not in
   `reference/maintenance.md`, add a row.

## Scripts

Both are read-only. Run them from anywhere inside the repo. `-h` prints usage.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/doc-drift-check.sh` | one status line per register entry (STALE/PASS/RECHECK/OPEN/KNOWN/SKIP), then a summary. Exit = STALE + RECHECK (cap 255); 2 = usage (stderr message, no SUMMARY line; a run with exactly 2 STALE+RECHECK also exits 2, so read the SUMMARY line, not only the exit code). Options `--only SC-a,SC-b`, `-q`, `--list`, `--offline`, `--no-docker` | `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh -q` | `SUMMARY doc-drift-check: entries=42 STALE=40 PASS=0 RECHECK=0 OPEN=1 KNOWN=1 SKIP=0 (pinned lago-api: yes; history clone: yes; docker CLI: yes)`, exit 40, in under 1 s with a warm cache |
| | without the pinned checkout or the history clone | `LAGO_SKILLS_CACHE=$(mktemp -d) .claude/skills/docs-and-writing/scripts/doc-drift-check.sh --offline -q` | `entries=42 STALE=39 PASS=0 RECHECK=0 OPEN=1 KNOWN=0 SKIP=2`. 13 STALE lines carry `[anchor not re-checked: no pinned lago-api]` (or `no history clone`) |
| | `--no-docker` | `… --no-docker --only SC-13,SC-30` | 2 STALE lines with `[anchor not re-checked: no docker compose CLI]`, exit 2 |
| `scripts/docs-to-recheck.sh` | applies `reference/maintenance.md` (the single source of the map) to a diff: `RECHECK <docs>` blocks with "look for" and SC entries, then the unmapped files. Modes: default (worktree + untracked vs HEAD), `--staged`, `--range A..B`, `-C <git dir>`, `-- <paths>`. Exit 0; 2 = usage or git error | `H=$(.claude/skills/research-methodology/scripts/history-setup.sh); .claude/skills/docs-and-writing/scripts/docs-to-recheck.sh -C "$H" --range 2fd8e8b^..2fd8e8b` | 2 RECHECK blocks (EP README Configuration with `SC-05`; connectors/architecture with `SC-20 SC-33`); `SUMMARY docs-to-recheck: changed=7 matched-rows=2 unmapped=2` |

The flip behaviour was tested in a scratch `git clone` of the repo (re-run 2026-10-01; never edit
the working repo for this, change-control N10):

- removing "won't work locally" from `events-processor/CLAUDE.md` turned SC-01 into `PASS`;
- adding a file that mentions `godotenv` under `events-processor/` turned SC-04 into `RECHECK`;
- `--only SC-01,SC-04` then printed `STALE=0 PASS=1 RECHECK=1` and exited 1;
- pasting the corrected texts of SC-12, SC-39, SC-40, SC-41 and SC-42 turned all five into `PASS`
  (exit 0); a `mailhog` network alias on the `mailpit` service turned SC-39 into `RECHECK`.

`docs-to-recheck.sh` runs git from the repo top level when `-C` is not given, so the default
mode gives the same result from any subdirectory. `-- <paths>` expects repo-relative paths.

## Provenance and maintenance

- **Sources:**
  - docs: `events-processor/{CLAUDE,README}.md`, `docs/*.md`, `deploy/README.md`,
    `docker/README.md`, `connectors/README.md`, `README.md`, `CONTRIBUTING.md`,
    `PULL_REQUEST_TEMPLATE.md`;
  - lago-api: `$API/AGENTS.md`, `$API/PULL_REQUEST_TEMPLATE.md`;
  - exemplar commits: `9acd83e` (#735), `02a4bc8` (#785), `d9c32b6` (#797), `647de3e` (#620),
    `0b56915` (#774), `2146a18`, `5070e24`;
  - doc histories in `$H`.
- **Volatile facts and their re-verification commands:**
  - Code anchor: `git rev-parse --short=12 5308258:events-processor` -> `83e012866f29`.
  - Register state:
    `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh -q`
    -> `entries=42 STALE=40 PASS=0 RECHECK=0 OPEN=1 KNOWN=1 SKIP=0` (as of 2026-10-01).
  - Doc freshness: the loop in `reference/inventory.md` "Re-measure"
    -> `events-processor/README.md 2026-09-18 d9c32b6 commits=7` (as of 2026-10-01).
  - Exemplar commits exist:
    `git -C "$H" show -s --format='%h %s' 9acd83e 02a4bc8 d9c32b6`
    -> 3 subjects ending `(#735)`, `(#785)`, `(#797)`.
  - Ticket-prefix style:
    `git -C "$H" log --format='%h %s' | grep -E '^[0-9a-f]+ \[(ING|INF)-'`
    -> `0b56915`, `3ac94a2`, `9ef876a` (as of 2026-10-01).
  - lago-cli has no `exec`/`up`:
    `d=$(mktemp -d); git clone -q --depth 1 https://github.com/getlago/lago-cli "$d" && grep -rhoE 'Use: +"(exec|up)[^"]*"' "$d" --include=*.go; rm -rf "$d"`
    -> only `Use:     "upgrade"` (lago-cli `49a7a03`, 2026-09-17).
  - Alias not expanded in agent shells:
    `bash -c 'alias lago="echo x"; lago hi'` -> `lago: command not found`, exit 127.
  - Commit and PR convention numbers: `change-control` (its commit-msg check `--report`).
- **Update triggers:**
  - a release bump that moves the `api` gitlink. Re-run `doc-drift-check.sh`: `$API` anchors may
    turn RECHECK.
  - any edit under `docs/` or to a README, `CONTRIBUTING.md`, `PULL_REQUEST_TEMPLATE.md` or
    `events-processor/CLAUDE.md`;
  - a decision on OD-5 (rewrite SC-01's policy line) or on OD-7 (SC-36, templates §1-2);
  - a fix of the dev mail host, in the compose file or in lago-api (SC-39 turns RECHECK);
  - a new doc file (add it to the inventory) or a new top-level code dir (add a map row);
  - a sibling script renamed: `grep -rn 'docs-and-writing' .claude/skills` for inbound references.
