---
name: research-methodology
description: "Evidence discipline for the Lago umbrella repo: turn a hunch into an ACCEPTED, REFUTED or INCONCLUSIVE result (hypothesis predicting a number, cheapest discriminating probe, control), the evidence bar, conflicting sources, full history from the shallow clone (history-setup.sh), lago-api at the pin (pinned-checkout.sh), registry probing, owner questions. Use for \"is this true\", \"verify this\", \"which source is right\", \"when was X introduced\", \"git log shows only a few commits\", \"no tags\", evidence-check. Not for the OD register (use change-control) or harnesses (use diagnostics-and-tooling)."
---
# Research methodology: from hunch to accepted result

This is how claims about this repo family get established, checked and recorded. A result is only as
good as its evidence. Predict the number before you run anything. Every claim carries a `path:line`, a
sha, or a command with its output.

Facts verified 2026-10-01 unless marked; the owner decisions of 2026-10-02 (change-control §9) are
folded in, and so is the re-implementation kit's finding of 2026-10-02 that lago-api claims can be
EXECUTED here (probe rung 5b, section 6 step 8). Code facts as of `5308258` (events-processor tree
`83e012866f29`); the working branch may carry skills-only commits on top. `5308258` is the head of the
fork `denekes/lago09`; upstream `getlago/lago` main is `a0de065` (2026-09-29, same gitlinks).

## When to use / when NOT to use

Use when:
- You have a hunch ("I think retries get lost") and need to turn it into a verdict others will accept.
- Two sources disagree: a doc vs the code, a comment vs a run, two reports, a skill vs your run.
- You need history (who, when, why, how often) and the working clone is shallow.
- You must read lago-api or lago-front, whose submodules are empty here.
- You must say whether an image, tag or module version exists or was published.
- You are about to write "production does X", or "the owner wants Y".
- You review a PR, doc or skill for evidence quality (`.claude/skills/research-methodology/scripts/evidence-check.sh`).

Do NOT use for:
- The findings themselves. Use the owning skill: `architecture-contract` (as-is events-processor), `rails-go-parity` (Rails/ClickHouse contracts), `failure-archaeology` (incident narratives), `event-accounting-campaign` (fixes for loss, value and time).
- Building probe harnesses (kfake, miniredis, scratch PG, `-overlay`, clickhouse local). Use `diagnostics-and-tooling`.
- Test baselines and how to add tests. Use `validation-and-qa`.
- Change classes, OD gates and PR rules. Use `change-control`.
- Release audits and image matrices. Use `release-and-images`.
- Toolchain and CGO setup. Use `build-and-env`.
- Doc corrections. Use `docs-and-writing`.

## Terms

- **Hunch**: an unverified idea. Comments, docs, reports and memory are hunch *sources*, not evidence.
- **Hypothesis card**: the written record of one hypothesis, from prediction to verdict (template below).
- **Prediction**: the number or observable you expect if the hypothesis is true, written before the run.
- **Discriminating probe**: the cheapest action whose outcome differs depending on whether the hypothesis is true.
- **Control**: a run that must show the effect is visible at all. It proves the probe is not blind.
- **Verdict**: ACCEPTED, REFUTED or INCONCLUSIVE. A REFUTED card may end with a *refined claim*.
- **Labels**: VERIFIED (ran or read today, dated), UNVERIFIED, CANDIDATE (proposed, not proven), OPEN DECISION OD-n (owner's call, still open), DECIDED OD-n (owner, <date>) (recorded in change-control §9), DEFAULT APPLIED OD-n (a default applied to an unanswered question; the owner may reassign), TARGET (a goal, not a state).
- **`H`**: the bare, blob-less full-history clone from `.claude/skills/research-methodology/scripts/history-setup.sh`.
- **`$API` / `$FRONT`**: checkouts at the gitlink SHA, from `.claude/skills/research-methodology/scripts/pinned-checkout.sh`.
- **Pin**: the commit an `api` or `front` gitlink records (`git ls-tree HEAD api front`).
- **Upstream drift**: commits on `getlago/*` main that the fork or the pin does not have.

## 1. The method

Run these seven steps in order. Do not skip step 2.

<!-- evidence-check: off (procedure, not claims) -->
| # | Step | Output |
|---|---|---|
| 1 | **Hunch.** Write where it came from (comment, doc, report, symptom). | one line + source `path:line` or sha |
| 2 | **Hypothesis + prediction.** One falsifiable sentence, scoped (mode, version, pin). Predict a NUMBER or observable for both outcomes. | card fields H, Prediction |
| 3 | **Cheapest discriminating probe + control.** Climb the probe ladder below; stop at the first rung that can tell H from not-H. | command(s), expected cost |
| 4 | **Run.** Scratch only (change-control N10). Capture raw output, exit status, versions. Re-run timing-sensitive probes at least twice. | raw output |
| 5 | **Compare** the observation with the prediction AND check that the control behaved. | match / mismatch / control failed |
| 6 | **Verdict.** ACCEPTED, REFUTED (+ refined claim) or INCONCLUSIVE (+ what would decide it). Never edit the prediction afterwards; write a new card. | verdict + label |
| 7 | **Record** where the fact lives (owning skill, doc, test or script) and classify the change (section 9). | link, test, change class |

<!-- evidence-check: on -->

Probe ladder (cheapest first):

| Rung | Probe | Typical cost | Example here |
|---|---|---|---|
| 0 | Code read at a stated sha: `grep -n` at HEAD or `$API` | seconds | ZSET score is wall clock: `events-processor/models/stores.go:55,61` |
| 1 | An existing test: `.claude/skills/build-and-env/scripts/ep-test.sh -count=1 -run TestFindMaxCommitableRecord -v ./config/kafka/` | seconds | `--- PASS: TestFindMaxCommitableRecord` (`events-processor/config/kafka/consumer_test.go:18`) |
| 2 | A stdlib snippet in `$(mktemp -d)` | seconds | `%v` of `1000000` gives `1e+06` (worked-examples Example B) |
| 3 | A probe test added via `go test -overlay` (no repo writes) | about 1 min | see `diagnostics-and-tooling` |
| 4 | A scratch module with `replace` onto `events-processor` (real package APIs) | about 1 min | commit-skip probe driving `kafka.NewConsumerGroup` (`events-processor/config/kafka/consumer.go:227`), worked-examples Example A |
| 5 | A harness: kfake, miniredis, scratch PG, `clickhouse local` | minutes | see `diagnostics-and-tooling` |
| 5b | lago-api at the pin, RUN: its own rspec examples or a kit vector through the oracle (`diagnostics-and-tooling` H13) | about 10 s warm; 94 s setup from an empty cache | `oracle.sh run spec/services/events/kafka_producer_service_spec.rb` (in `.claude/skills/reimplementation-kit/scripts/maintainer/`) gives `"example_count":13,"failure_count":0` together with `apply_rounding_service_spec.rb` (2026-10-02) |
| 6 | The full dev stack (needs a Docker daemon) | not runnable in agent sandboxes | mark "not runnable here; verified by reading `<file:line>`" |

A probe is **not** discriminating if both outcomes fit H. Example: a unit test of
`findMaxCommitableRecord` passes whether or not a later poll skips the hole. Only driving the real
consumer across polls can tell (worked-examples Example A).

### Hypothesis card (copy, fill in, keep with the PR or skill change)

```
### RM-<id> <short title>                 <date> · HEAD <sha> · pins api <sha>/front <sha>
Hunch / source:        <where the idea came from (path:line, sha, report, symptom)>
Hypothesis (H):        <falsifiable statement; scope: DB|cache mode, versions, pin>
Prediction:            if H: <observable = NUMBER>;  if not H: <what you would see instead>
Discriminating probe:  <rung N> <command(s)>
Control:               <run that must show the effect is observable>
Cost / side effects:   <time, network; writes only to scratch (change-control N10)>
Observed:              <raw output, exit status, tool versions, runs repeated>
Verdict:               ACCEPTED | REFUTED | INCONCLUSIVE    Refined claim: <optional>
Label:                 VERIFIED <date> | UNVERIFIED | CANDIDATE | OPEN DECISION OD-n | DECIDED OD-n (owner, <date>)
Record:                <owning skill/doc + test/script carrying it; change class C0–C7>
Re-verify:             <one-line command> -> <expected output>
```

Verdict rules:
<!-- evidence-check: off (definitions) -->
- **ACCEPTED**: the observation matches the prediction, the control behaved, and timing-sensitive results reproduce.
- **REFUTED**: the observation contradicts the prediction and the control worked. A refined claim drawn from the same run is a new claim; say so.
- **INCONCLUSIVE**: the control failed, the probe did not discriminate, results are flaky, or the environment differs (a different ClickHouse version, no daemon). State what would decide it, and label the claim UNVERIFIED.
<!-- evidence-check: on -->

## 2. Two worked examples from this repo (full cards: `reference/worked-examples.md`)

The commands and raw outputs behind these summaries are in `reference/worked-examples.md`.
<!-- evidence-check: off (summaries; evidence in reference/worked-examples.md) -->

**A. "Retryable failures are redelivered."**
- Source: the comments `events-processor/processors/events_processor/processor.go:75-76` and `events-processor/config/kafka/consumer.go:97`.
- Prediction: after a restart, the failing record has 2 deliveries.
- Probe (rung 4): the real `kafka.NewConsumerGroup` against in-process kfake. The stub drops the record exactly as `processor.go:74-79` does. A later poll on the same partition commits.
- Control: the same run without the later poll.
- Observed (4/4 runs): treatment `retryable-fail:1`, i.e. **0 redeliveries**. Control `retryable-fail:2`.
- Verdict: **REFUTED**. Refined and ACCEPTED: a retryable failure is redelivered only if no later batch on that partition commits first; otherwise it is skipped forever, with no DLQ entry.
- Recorded: `architecture-contract` (as-is), `event-accounting-campaign` W1, change-control N7. The fix contract is ADR-001 in `event-accounting-campaign` (DECIDED OD-2 (owner, 2026-10-02), delegated): commit offset N only when every record <= N has a durable disposition.

**B. "ClickHouse cannot parse `1e+06`, so sums become 0."**
- Source: `value` is built with `fmt.Sprintf("%v")` (`events-processor/processors/events_processor/enrichment_service.go:114`), and `decimal_value` is `toDecimal128OrZero(value, 26)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`).
- Prediction: `'1e+06'` gives 0.
- Probe (rung 5): `clickhouse local` 25.8.2.29 over a corpus with boundary controls.
- Observed (identical on 25.8.2.29 and 26.2.9.9): `'1e+06'` gives 1000000. `'1e+12'`, `'1000000000000'` and `'<nil>'` give **0**.
- Verdict: **REFUTED**. New finding ACCEPTED (version-scoped): exponent strings parse; values >= 1e12 and `"<nil>"` silently become 0.
- Recorded: `rails-go-parity`, `event-accounting-campaign` W2. A ClickHouse schema change is allowed (DECIDED OD-3 (owner, 2026-10-02)). The production ClickHouse version is UNVERIFIED; dev runs 26.2 (`docker-compose.dev.yml:460`).

<!-- evidence-check: on -->
Both refutations came from the **control** and the **boundary cases**, not from the suspect input alone.

## 3. The evidence bar

| Claim type | Minimum evidence | NOT evidence (real examples here) |
|---|---|---|
| What code does (static) | Code read at a stated sha, cited `path:line` (repo) or `$API/path:line` + pin | Code comments, function names, docs. The Rails comment "event timestamp as score" (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11`) is wrong: Go uses `time.Now()` (`events-processor/models/stores.go:55`). |
| What code does at runtime (delivery, ordering, parsing, concurrency) | Probe or test output with exit status and a control; the command published | A code read alone ("should"). The comment "It will be consumed again" (`events-processor/processors/events_processor/processor.go:76`) is refuted by Example A. |
| A baseline number (PASS count, coverage, lint count) | Command + output + **exit status** + denominator | "47.4%" from `go test -coverprofile ./...`, which exits 1 (`reference/conflict-cases.md` CC6) |
| History (introduced, removed, reverted, by whom) | Sha(s) from `H`, with a rename-aware pathspec or `-S`/`-G` | The shallow clone: `git blame` there attributes all 308 lines of `consumer.go` to `^8ceca4b`. A subject line alone: `449bf5b` "Bump version to 7" is a Redis 6 to 7 change. |
| Counts over history | The command over `H` + an exact definition of what is counted | Subject-regex classification. Of the 77 pin moves since 2025 (`git -C "$H" log --since=2025-01-01 --format=%h -- api front`; count with (1) below), regexes call 18 or 20 "non-release"; by data it is 15 (worked-examples Example D). |
| A cross-repo contract (Go vs Rails vs ClickHouse) | `path:line` on BOTH sides at stated pins; a probe if semantics matter | One side only; a commit body in the other repo (lago-api `6341824` body about this repo was already stale) |
| What lago-api does at runtime (since 2026-10-02 this can be EXECUTED here) | A run at the pin: the rspec example(s) via the kit oracle (rung 5b: `oracle.sh run <spec>:<line>`, its JSON summary line and exit status), or a kit vector whose `evidence.kind` is EXECUTED (by `oracle-adapter` or `spec-green`) | A spec file that was never run; a kit vector labelled RECOMPUTED or EXTRACTED quoted as if executed. Example: the kit's draft text for `reimplementation-kit` RBD-37 said a division by zero kills the API process; the verifier's oracle run showed HTTP 500 with nothing stored and the server still serving |
| A version or pin | Every pin location `path:line`; the gitlink via `git ls-tree HEAD api front` | A comment that lists fewer locations (`events-processor/Dockerfile.staging:20-22` says two; there are four) |
| An artifact exists or was published | A registry API response (HTTP status, `last_updated`/digest), dated | A workflow file existing (`.github/workflows/release-docker-image.yml:11` builds `getlago/lago`); a release note. Yet `curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.48.0` gives 404. |
| External tool semantics (ClickHouse, franz-go, Go stdlib) | A run on a NAMED version, plus a version caveat (`clickhouse local` 25.8.2.29 in Example B) | Tool docs, or a run on another version presented without its version; dev runs 26.2 (`docker-compose.dev.yml:460`) |
| Production state (flags, mode, versions, topology) | An owner statement (written, dated) or telemetry the reader can open. Example: production runs the memory cache (DECIDED OD-1 (owner, 2026-10-02)) | Dev defaults (`grep -c LAGO_USE_MEMORY_CACHE .env.development.default` gives 0, which is dev, not prod), compose files, the public Helm chart (a proxy for self-hosters only) |
| Owner intent or policy | An owner statement recorded in change-control's register, an ADR or a PR | Precedent: `misc` is the subject type of 279 commits by the strict regex, 283 by a looser one (commands (2) below), which is de-facto, not policy (OPEN DECISION OD-7); an agent's relay of "approval" |
| "This doc is stale" | Doc `path:line` + contradicting evidence from a row above, e.g. `events-processor/CLAUDE.md:10` ("Direct `go test` won't work") vs a green `.claude/skills/build-and-env/scripts/ep-test.sh` run | Another doc |

Commands with a shell pipe stay out of table cells (a table needs `\|`, which the shell does not undo):

```bash
git -C "$H" log --since=2025-01-01 --format=%h -- api front | wc -l     # (1) 77 pin moves since 2025
git -C "$H" log --format=%s | grep -cE '^misc(\([^)]*\))?: '          # (2) 279, strict misc(scope): / misc:
git -C "$H" log --format=%s | grep -cE '^misc(\(|:|!)'                 # (2) 283, loose; quote a count with its regex
```

Never evidence, anywhere: earlier analyses and summaries; LLM output (this skill included, until its re-verify
line passes); a ticket id or PR number with no content; "everyone knows"; a number with no command.

Labelling: an unverified claim is fine if it is **labelled UNVERIFIED** (change-control N13). An
unlabelled, unverified claim is a defect.

## 4. Conflict resolution (full rule set and 17 verified cases: `reference/conflict-cases.md`)

| If you see | Do | Verified case |
|---|---|---|
| Two counts that differ | Pin the scope first (paths, dates, remote). Both may be right. | 88 vs 96 events-processor commits: `git -C "$H" log --format=%h -- events-processor` vs the same with `events_processor` added (counts below the table; CC4) |
| A doc vs a run or code read | The run or code read wins. Log the doc in `docs-and-writing`. | `docs/dev_environment.md:154` says `LAGO_CLICKHOUSE_ENABLED=false` disables ClickHouse; `.present?` at `$API/app/services/events/stores/store_factory.rb:10` keeps the store on (MIXED overall: see `config-and-flags`) (CD2) |
| A comment vs the code | The code wins | Example C in `reference/worked-examples.md` |
| A speculation vs a probe | The probe wins, with its version scope | `clickhouse local` 25.8.2.29 parses `'1e+06'` as 1000000 (Example B, CC2) |
| A classifier (subject regex) vs data | Data wins | 15 non-release pin moves by data; subject filters give 20, 18 or 16, and the one that drops `version` throws out the non-release `7251947` (CC5) |
| The same claim at different pins | Both true: "at `591ae90`" vs "upstream since `6341824`" | lago-api dropped `events_enriched_expanded` after the pin (Example E) |
| A number without exit status | Re-run and record the exit status | `go test -coverprofile=… ./...` prints 47.4% but exits 1 (`go: no such tool "covdata"`); the gated figure is the tested-packages form (`validation-and-qa`) (CC6) |
| Cited line numbers differ | `grep -n` at HEAD; cite anchor + line | `events-processor/go.mod:10` is expression-go; `:9` is badger (CC8) |
| Still unresolved | Label both UNVERIFIED, write the card for the deciding probe, or route to the owner (OPEN DECISION OD-n) | OPEN DECISION OD-1b, OD-8 |

```bash
git -C "$H" log --format=%h -- events-processor | wc -l                    # 88
git -C "$H" log --format=%h -- events-processor events_processor | wc -l   # 96 (CC4)
```

## 5. Mining history (recipes: `reference/history-mining.md`)

This section and `reference/history-mining.md` own the generic history recipes; `failure-archaeology`
keeps only its chain-specific gotchas.

1. Check for the shallow trap: `git rev-parse --is-shallow-repository` gives `true`; `git rev-list --count 5308258` gives 57 (count the code commit: HEAD's count grows with every skills-only commit on the working branch).
2. Get full history: `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`, then `git -C "$H" rev-list --count HEAD` gives 776 (2022-02-28 `5e9b9bb` to `5308258`).
3. Use the rename-aware pathspec: `git -C "$H" log -- events-processor events_processor`. `--follow` works for single files only, and not with `--reverse`. Before `d5bce86`, `git show <sha>:<path>` needs the old path `events_processor/`.
4. Use the pickaxe: `-S'<literal>'` when a literal's count changed (`git -C "$H" log -S'subscription_refreshed_v2' --format=%h` gives `42615c9`, #720). Use `-G'<regex>'` for any diff line (`-G'^LAGO_LICENSE=.'`; count, never print values: change-control N11).
5. Trace functions: `git -C "$H" log -L ':processRecordsAndCommit:events-processor/config/kafka/consumer.go' -s` gives `9acd83e`, `475761d`, `b6d3616`, `600e195`. Widen with `-G` for the chain's start (`cec0eb2`, `4100da0`).
6. Map tags: the default `H` has **0 tags** (it is cloned from the fork). Run `.claude/skills/research-methodology/scripts/tag-map.sh [--gitlinks]`.
7. Read PR numbers from `(#NNN)` subject suffixes: 216 of 293 non-merge commits since 2025 (`git -C "$H" log --since=2025-01-01 --no-merges --format=%s | grep -cE '\(#[0-9]+\)$'`). PR pages return 403 from this session (`curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/getlago/lago/pulls/797`). For squash merges, the commit body is the PR description (`git -C "$H" show -s d9c32b6`).
8. Check upstream drift: `git ls-remote https://github.com/getlago/lago refs/heads/main` gives `a0de065…`, 2 commits past the fork (`6dcdb62` #806, `a0de065` #810).

Traps in `H`:
- Blobs come lazily, so the first `git -C "$H" show <sha>` or `-G` search needs network.
- A **full** sha resolves even for upstream-only commits (fetched lazily): `git -C "$H" log -1 a0de065beab237f357f033c6aa92058ebd417d5c` works. The short `a0de065` fails ("unknown revision") until that first full-sha fetch.
- `--remote` on an existing cache is ignored with a warning. For an upstream clone (778 commits, 195 tags), use another cache: `LAGO_SKILLS_CACHE=<dir> .claude/skills/research-methodology/scripts/history-setup.sh --remote https://github.com/getlago/lago`.

## 6. Reading cross-repo code at the pinned SHA

1. Run `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (likewise `front`). This reads the gitlink, not the empty `api/` dir. Never populate the submodules in the working repo: a checked-out submodule at another commit is a gitlink change that `git commit -a` or `git add -A` stages. `12b8101` (a Traefik fix) moved both pins by mistake and `647de3e` (#620) reverted them (change-control N1); how they got staged is UNVERIFIED. Before a commit, run `.claude/skills/change-control/scripts/precommit-guard.sh` (expect `0 FAIL`).
2. **State the pin and its date** with every cross-repo claim: "`$API` = lago-api `591ae90` (2026-09-08, tag v1.53.0)" (`git -C "$API" log -1 --format='%h %cs'`).
3. Remember that **events-processor HEAD is newer than the pin.** The last events-processor commit is `5308258` (2026-09-18), 10 days after the pinned lago-api. Rails code at the pin may still expect Go behaviour that has since been removed, e.g. the expanded topic, removed in `d9c32b6`.
4. **Check upstream before you say "Rails still does X".** lago-api main is `b5500bc` (2026-10-01), 178 commits past the pin. A scratch `--shallow-since` clone shows what changed in a cited file. Example: `6341824` (#6475) dropped `events_enriched_expanded`, so a drift finding is "true at the pin, fixed upstream" (`reference/worked-examples.md` Example E).
5. For another tag, resolve the full sha first, then check it out:
   ```bash
   sha=$(.claude/skills/research-methodology/scripts/tag-map.sh --repo api --match '^v1\.27\.1$' | cut -f3)   # f40cb61…
   API127=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api "$sha")
   ls "$API127/scripts" | grep pdf          # start.pdfs.worker.sh only
   ```
   `deploy/docker-compose.production.yml:346` runs `start.pdf.worker.sh`, which does not exist at v1.27.1, the tag `deploy/` pins.
6. Cite `$API/<path>:<line>` and `$FRONT/<path>:<line>`. Re-grep line numbers at the pin you name.
7. For other public repos (`lago-cli`, `lago-helm-charts`), use a depth-1 clone in `$(mktemp -d)` and record HEAD sha + date (`reference/registry-probing.md`).
8. **Run the pinned lago-api when the claim is about behaviour** (2026-10-02: possible here without
   Docker). `pinned-checkout.sh api` stays the read-only source; the kit oracle
   (`.claude/skills/reimplementation-kit/scripts/maintainer/oracle.sh`, Ruby 4.0.6 from conda-forge,
   your own `ORACLE_DB`) runs its rspec examples or answers a kit op. Commands, cost and hygiene:
   `diagnostics-and-tooling` H13; the recipe itself lives only in `reimplementation-kit`
   `reference/maintainer-oracle.md` (do not copy it). Cite the result as "EXECUTED at `591ae90`:
   `oracle.sh run <spec>:<line>` -> `<summary line>`". Kit vectors carry their own evidence kind:
   EXECUTED (the reference ran) maps to VERIFIED, RECOMPUTED (an independent model) and EXTRACTED
   (read only) do not; a corrected-profile twin is RECOMPUTED by definition.

## 7. Probing registries and module proxies (commands and outputs: `reference/registry-probing.md`)

| Question | Command (as of 2026-10-01) | Result |
|---|---|---|
| Does an image tag exist? | `curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.48.0` | `404` (also v1.49.0, v1.50.0; `getlago/lago-events-processor` has all three; the full never-published list is in `release-and-images`) |
| When was it pushed, for which archs? | `curl -s https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.53.0` (fields `last_updated`, `images[].architecture`) | `2026-09-08T15:26:52Z`, amd64 + arm64 |
| GHCR tags | `curl -s "https://ghcr.io/token?scope=repository:getlago/api:pull"`, then `GET https://ghcr.io/v2/getlago/api/tags/list` with a Bearer token | 38 tags, `v1.44.0`…`v1.53.0`, `sha-591ae90` |
| Go module versions | `curl -s https://proxy.golang.org/github.com/getlago/lago-expression/expression-go/@v/list` | `v0.1.4`, `v0.1.0` (no v0.2.0; change-control N3) |
| Go toolchains | `curl -s https://proxy.golang.org/golang.org/toolchain/@v/list`, filtered (command below the table) | `go1.27.0`, `go1.27.1` |
| Does a repo exist or is it public? | `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/getlago/<repo> HEAD` | lago-deploy, lago-sidekiqs, lago-license: auth wall (private OR absent) |

```bash
curl -s https://proxy.golang.org/golang.org/toolchain/@v/list | grep -E 'go1\.27\.[0-9]+\.linux-amd64$'
```

Registries are mutable. Record the date, digest and `last_updated`, and re-probe before you cite.

## 8. What is invisible from here, and owner questions (`reference/owner-questions.md`)

| Invisible from this sandbox | How you can tell (2026-10-01) | Route |
|---|---|---|
| Lago Cloud production config: Debezium column list, CDC Kafka auth and brokers, partitions | No Cloud deploy config in this repo or the public Helm chart; the pipeline is in private lago-deploy (`events-processor/Dockerfile.staging:8`) | OPEN DECISION OD-1b (owner). The mode itself is settled: DECIDED OD-1 (owner, 2026-10-02), production runs the memory cache; hardening: DEFAULT APPLIED OD-20 (campaign W6) |
| Production lago-api flags | DB rows per organization; code only at `$API` | OPEN DECISION OD-8 |
| Production ClickHouse, Postgres, Kafka versions | Only dev pins exist, e.g. `docker-compose.dev.yml:460` | UNVERIFIED; ask |
| Private repos: lago-deploy, lago-sidekiqs, lago-license | `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/getlago/lago-deploy HEAD` asks for credentials | UNVERIFIED |
| Branch protection, PR threads | `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/getlago/lago/branches/main/protection` gives 403 | UNVERIFIED |
| Sentry, DLQ dashboards, lag alerts | No metrics endpoint: `grep -rn 'ListenAndServe' events-processor --include=*.go` gives nothing | UNVERIFIED; ADR-001 (DECIDED OD-2) specifies the counters and alerts to build |
| Secret rotation; ING-123 impact (`9ef876a`) | Only the owner knows | OPEN DECISION OD-9 |
| Intent behind as-is code (e.g. the 50 vs 72 subject limit) | Code shows what is, not what was meant | ask (OPEN DECISION OD-7 for the subject limit). Settled 2026-10-02: the 12 h horizon (`events-processor/processors/events_processor/processor.go:74`) stays as ADR-001's default retry max age (DECIDED OD-2); `Decimal(38,26)` may change (DECIDED OD-3) |

When you hit one:
1. Name the nearest **proxy** and label it as one. Example: the public Helm chart (`getlago/lago-helm-charts` at `d473b1e`) has `replicas: 1` and no memory cache, which describes Helm self-hosters, not Cloud.
2. Keep the claim UNVERIFIED or OPEN DECISION OD-n. Never resolve it by assumption.
3. Ask with the template in `reference/owner-questions.md`: one decision per question, the evidence inside the question, options with a CANDIDATE recommendation, the default meanwhile, and what it blocks.
4. Route the decision through change-control §9, the one register (OD-1..OD-24, plus sub-ids such as OD-1b; OD-21..OD-23 proposed on 2026-10-02 from the re-implementation kit); raise a new one as a GitHub issue titled "OD-n: <topic>" with the evidence block. Route review to the area's top recent author: events-processor has a bus factor of one, with 55 of 72 non-dependabot commits by one author (`git -C "$H" log --no-merges --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -1`). Record every answer in the repo; an answer that is only remembered is lost.

## 9. Acceptance: when a result is "accepted" here

A result is accepted only when ALL of these hold:

- [ ] The hypothesis card is complete, its verdict is ACCEPTED (or a REFUTED card is filed), and the raw output is quoted.
- [ ] It is reproducible. Someone else re-ran the published command, or it is a script with an expected output.
- [ ] It lands as **executable evidence**: a unit test for repo-code behaviour (table-driven, sqlmock pinning; see `validation-and-qa`), a probe or script in the owning skill for harness-level behaviour, or a re-verify line in a skill's Provenance for facts.
- [ ] The owning skill or doc is updated (table below), with labels and the as-of date.
- [ ] The change is classified C0–C7 and passes that class's gate (`change-control`). The PR body carries the evidence (change-control N13).
- [ ] If it touches an open decision, it stays CANDIDATE until the owner decides (OPEN DECISION OD-n).
- [ ] `.claude/skills/research-methodology/scripts/evidence-check.sh` on every changed SKILL.md adds no new flagged lines.

| The result is about… | Record it in | Change class |
|---|---|---|
| As-is events-processor behaviour or invariants | `architecture-contract` | C0 (skill) |
| Go vs Rails/ClickHouse divergence | `rails-go-parity` | C0; a fix is C3/C4 |
| Loss, value or time defects and their fixes | `event-accounting-campaign` | C1 test, then C3/C4 fix |
| A past incident or fix chain | `failure-archaeology` | C0 |
| Symptom to fix | `debugging-playbook` | C0 |
| A stale doc | `docs-and-writing` register + the doc | C0 |
| Env var meaning | `config-and-flags` | C0 / C6 |
| Release or image facts | `release-and-images` | C0 / C5 |
| Baseline numbers | `validation-and-qa` | C1 |
| Secrets, exposure, supply chain | `security-and-supply-chain` | C7 |
| A new rule or owner decision | `change-control` | C0 + owner |

## Scripts

All are read-only on the repo. They write only under `${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}` or `mktemp -d`.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/history-setup.sh` | Bare, blob-less, full-history clone; prints its path. `[--refresh] [--remote URL]`. Exit 2 on usage; git's code (e.g. 128) if the clone fails, leaving no directory. | `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)` | `$LAGO_SKILLS_CACHE/lago-history.git`; `git -C "$H" rev-list --count HEAD` gives 776 |
| `scripts/pinned-checkout.sh` | Depth-1 checkout at the gitlink (or a given **full** sha). Exit 1 on fetch failure, 2 on usage. | `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` | `…/lago-api@591ae9005110`; a short sha gives exit 2 with a hint |
| `scripts/tag-map.sh` | Tag to sha tables from `git ls-remote` for lago, lago-api, lago-front. `--repo`, `--match ERE` (on the tag), `--gitlinks`. | `.claude/skills/research-methodology/scripts/tag-map.sh --gitlinks --match '^v1\.5[23]\.'` | tab-separated: `v1.52.1 01cfbc6 2026-08-27 main api=731388f(v1.52.0) front=dbde527(v1.52.0)` |
| `scripts/evidence-check.sh` | Citation lint. Flags bullet and table claims with no `path:line`, sha, PR ref or backticked command. Exit = flagged count (max 255); 2 is also a usage error (stderr names it). `--explain`, `-q`, `--skip RE`, `--all-sections`. | `.claude/skills/research-methodology/scripts/evidence-check.sh .claude/skills/*/SKILL.md` | per file: `claims=N evidenced=E labeled=L flagged=F` |

Changes on 2026-10-01 (bug fixes; the interfaces are unchanged):
- `pinned-checkout.sh`: a failed fetch used to leave an empty cache dir that later calls returned with exit 0, and an empty sha argument silently fell back to the pin. Now it validates the cache, rejects short or empty shas, and moves into place atomically.
- `history-setup.sh`: it warns when `--remote` is ignored, and disables auto-maintenance in `H` (the "Auto packing…" noise on every lazy fetch).
- Both: they read the repo the script lives in, whatever the cwd (the cwd's checkout only when the script is not inside a git repo). Before, a call from outside a checkout made `pinned-checkout.sh` exit 128 and `history-setup.sh` clone upstream instead of the fork, and a call from another repository's checkout made `history-setup.sh` clone that repository into the cache. They set `GIT_TERMINAL_PROMPT=0` unless you set it, so a private or missing remote fails instead of hanging on a prompt.

## Provenance and maintenance

Sources:
- `events-processor/config/kafka/consumer.go`, `events-processor/processors/events_processor/{processor,enrichment_service}.go`, `events-processor/models/stores.go`
- `$API` files cited above at `591ae90`
- commits `9acd83e`, `d9c32b6`, `42615c9`, `6dcdb62`, `a0de065`, lago-api `6341824`, `908fb37`
- registry responses from the `curl` commands in section 7 (Docker Hub, GHCR, proxy.golang.org), run 2026-10-01

Volatile facts and one-line re-verification (from the repo root; `H`/`API` as above):
- `git rev-parse --is-shallow-repository` gives `true`, and `git rev-list --count 5308258` gives 57.
- `git -C "$H" rev-list --count HEAD; git -C "$H" tag | wc -l` gives `776` and `0` (fork remote; `--refresh` first if the fork moved).
- `git ls-tree HEAD api front` gives `591ae90…` and `0c5e539…`. `git -C "$API" log -1 --format='%h %cs'` gives `591ae90 2026-09-08`.
- `git ls-remote https://github.com/getlago/lago refs/heads/main` gives `a0de065…` (fork HEAD `5308258`).
- `git ls-remote https://github.com/getlago/lago-api refs/heads/main` gives `b5500bc…` (178 past the pin).
- `.claude/skills/research-methodology/scripts/tag-map.sh | cut -f1 | sort | uniq -c` gives 211 api, 195 front, 195 lago.
- `curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.48.0` gives `404`.
- `grep -n 'IsRetryable() && time.Since' events-processor/processors/events_processor/processor.go` gives `74`. `grep -n 're-polled' events-processor/config/kafka/consumer.go` gives `97`.
- `grep -n 'Score:' events-processor/models/stores.go` gives `61`. `grep -n 'event timestamp as score' "$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb"` gives `11`.
- Example A probe (`reference/worked-examples.md`): treatment `retryable-fail:1`, control `retryable-fail:2`.
- `.claude/skills/research-methodology/scripts/evidence-check.sh .claude/skills/research-methodology/SKILL.md` exits 0.
- Rung 5b works (2026-10-02): `ORACLE_DB=lago_api_test_<you> .claude/skills/reimplementation-kit/scripts/maintainer/oracle.sh run spec/services/events/kafka_producer_service_spec.rb` prints a JSON line with `"failure_count":0`.

Update triggers:
- a release bump moves `api`/`front` (re-pin; Example E may resolve);
- any change to `processRecordsAndCommit`, `findMaxCommitableRecord` or the retry branch (re-run Example A);
- a ClickHouse schema change or version bump (re-run Example B; schema changes are allowed by DECIDED OD-3);
- the fork syncs with upstream, or `H`'s remote changes;
- GitHub API access changes in agent sessions;
- an owner decision on any OD-n;
- a change of the kit oracle's toolchain or egress (conda-forge, rubygems, crates.io; `reimplementation-kit` KQ-12) that breaks rung 5b.
