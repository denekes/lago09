# Docs of record: inventory

Read this when you need to know which doc to trust, who last touched it, or where a fact should be
written down. Facts as of 2026-10-01. Code facts as of `5308258` (events-processor tree
`83e012866f29`); the working branch may carry skills-only commits on top. History clone `$H` (776
commits as of 2026-10-01); lago-api at the pin `591ae90` (2026-09-08, `$API`).

## Trust levels (used below)

<!-- evidence-check: off (definitions) -->
| Level | Meaning | How to use the doc |
|---|---|---|
| T1 | Matches code today. Spot-checked, no open register entry. | Cite it with `path:line`. |
| T2 | Mostly right. The open entries are listed. | Use it, but check the listed SC entries first. |
| T3 | Several verified errors. | Treat every sentence as a hypothesis. Verify it against code before you repeat it. |
| MKT | Product or marketing copy. | Not a technical source. Never cite it as evidence (change-control N13). |
| EXT | Vendored or third-party. | Not ours. Do not edit it. Do not cite it for Lago behaviour. |
<!-- evidence-check: on -->

"Freshness" means the last commit that touched the file. It is not accuracy.
`events-processor/README.md` was edited on 2026-09-18 (`d9c32b6`) and still carries 9 stale
entries. "Main authors" is a routing hint (most commits, dependabot excluded). The repo has no
CODEOWNERS, so no doc has a stated owner.

## Umbrella repo: human docs

| Doc | Lines | Purpose | Audience | Main authors (commits) | Last touched | Trust | Open entries |
|---|---|---|---|---|---|---|---|
| `README.md` | 262 | product pitch, agent entry points (`:49-68`), agentic demo (`:70-109`), self-host quickstart (`:217-229`), SDK list | evaluators, self-hosters, coding agents | Raffi Sarkissian 9, Vincent Pochet 7 (49 total) | 2026-09-17 `eb58675` | MKT overall. The quickstart is T1: `.github/workflows/docker-ci.yml:16-32` runs that shape on every push to main | SC-34 (`:106` wording), SC-41 (`:190` metrics) |
| `CONTRIBUTING.md` | 213 | contribution process, commit style, labels | outside contributors | Vincent Pochet 4 (10 total) | 2025-09-16 `2002489` | T3 (process not practised) | SC-36 (OD-7), minor list |
| `PULL_REQUEST_TEMPLATE.md` | 28 | PR checklist | PR authors | 3 authors, 1 each | 2025-09-16 `9946c06` | T3 | SC-35, SC-36 |
| `CODE_OF_CONDUCT.md` | 128 | Contributor Covenant 2.0 (`:117-118`) | everyone | 1 commit | 2022-05-30 `f4b917a` | T1 (policy) | none |
| `.github/ISSUE_TEMPLATE/bug_report.md` | 32 | bug form | reporters | 1 commit | 2022-05-30 `716650b` | T3 (asks for browser/iOS, no Lago version) | minor list |
| `.github/ISSUE_TEMPLATE/config.yml` | 8 | blank issues off; features go to Canny | reporters | 3 commits | 2023-02-28 `5d33210` | T1 | none |
| `docs/architecture.md` | 548 | components, Sidekiq workers and queues, clock jobs, Redis, encryption, core flows, glossary | operators, engineers | Maxime Vidori 7, Vincent Pochet 3 (13 total) | 2026-09-01 `4230f1f` | T3 for semantics (retry, glossary, flows). T2 for the worker tables | SC-18 to SC-25 |
| `docs/arch_diagram.png` | n/a | component diagram (`docs/architecture.md:28`) | everyone | 1 commit | 2025-09-26 `870d141` | T2 | SC-26 |
| `docs/dev_environment.md` | 314 | contributor dev stack: clone, `lago` alias, TLS certs, hosts, env files, workers, tests, submodules, mail, webhooks | contributors | 4 authors, 1 each | 2026-09-03 `8f8334e` | T2 (the procedure works in principle) | SC-12 to SC-17, SC-39 |
| `docs/database_partitioning.md` | 251 | `enriched_events` pg_partman design, retroactive migration, maintenance | operators | Vincent Pochet 2 | 2026-02-12 `4cba248` | design T1. Retroactive steps T3 | SC-27, SC-28, SC-42 |
| `docs/monitoring.md` | 349 | Sidekiq metrics, alert rules, Grafana | operators | Maxime Vidori 1 | 2026-01-12 `206646b` | T3. Metric names UNVERIFIED (no running exporter here) | SC-29, SC-23 |
| `deploy/README.md` | 175 | self-host compose variants (local, light, production) and profiles | self-hosters | Jérémy Denquin 3, Maxime Vidori 2 | 2026-01-12 `206646b` | T3 (every start command fails as written) | SC-30. Its images are pinned at `v1.27.1`: see `release-and-images` |
| `docker/README.md` | 74 | all-in-one image (testing and staging only, `:5`) | evaluators | Jérémy Denquin 3 | 2025-05-22 `dc7b513` | T2 | SC-32 |
| `connectors/README.md` | 84 | Redpanda Connect ingest connectors (SQS, Kinesis, HTTP): event format, env tables | integrators | Jérémy Denquin 2 | 2026-04-27 `a12752f` | T3 (its event format loses data) | SC-33, SC-40 |
| `events-processor/README.md` | 68 | events-processor run, test and env tables | EP developers, operators | Vincent Pochet 3, Jérémy Denquin 3 (8 total, incl. the pre-rename path) | 2026-09-18 `d9c32b6` | T3 | SC-02 to SC-10 |
| `extra/kafka-connect/clickhouse-kafka-connect-v1.3.4/doc/README.md` | 42 | vendored connector docs | n/a | 1 commit | 2025-11-25 `d7355a6` | EXT | n/a |
| `docs/images/*.png` | n/a | README marketing images | evaluators | `530a0f3` (#775) | 2026-08-18 | MKT | n/a |

Not covered anywhere in prose: the Kafka topics, Debezium and the in-memory cache
(`grep -rliE 'debezium|events_enriched|events-raw' docs/ README.md` prints nothing), the release
train (see `release-and-images`) and events-processor operations (see `run-and-operate`). The skills
are the record for those topics until a human doc exists.

## Agent instruction files

| File | Scope | Content | Last touched | Trust | Notes |
|---|---|---|---|---|---|
| `events-processor/CLAUDE.md` | the only agent file in the umbrella repo. There is no root `CLAUDE.md` or `AGENTS.md` | 10 lines: test via `lago exec`, "direct go build/go test won't work" | 2026-03-05 `c340ddf`, added in passing by a logger PR (#711) and never revisited | T3 | SC-01. TARGET (not achieved as of 2026-10-01): it documents the Docker-free recipe |
| `.claude/skills/*/SKILL.md` + `reference/` | this skill library, 16 skills | runbooks, registers, scripts | per-skill "Facts verified" line | T1 when re-verified with each skill's Provenance commands | how to update one: `reference/templates.md` §6 |
| `$API/AGENTS.md` (lago-api, pinned) | Cursor-style front-matter `globs: app/**/*.rb`, `alwaysApply: true` (`:1-5`) | lago-api conventions: containers (`:7-9`), commits (`:30-68`), services, jobs, models, migrations, env vars (`:184-193`), tests (`:206-243`) | read at `591ae90` (v1.53.0); history not in the depth-1 checkout | T1 for lago-api code conventions | its `lago exec` lines need the alias (SC-17); its 50-char subject rule conflicts with `CONTRIBUTING.md:170` (SC-36, OD-7) |
| `$API/CLAUDE.md` | lago-api | one line: `@AGENTS.md` | same | T1 | imports AGENTS.md |

## Cross-repo convention sources (read-only, at the pin)

| File | Use it for |
|---|---|
| `$API/PULL_REQUEST_TEMPLATE.md` | lago-api PR shape: Roadmap Task / Context / Description (`:1-13`). The template in `reference/templates.md` follows its Context / Description. |
| `$API/CONTRIBUTING.md:175` | the same "<= 72 characters" rule as the umbrella `CONTRIBUTING.md:170` |
| `$API/docs/dropping_columns_and_tables.md` | the two-release column drop that Go readers depend on (see `change-control`, cross-repo protocol) |
| `$API/docs/profiling.md` | lago-api profiling. It uses the `lago` alias too. |

## Re-measure

```bash
cd "$(git rev-parse --show-toplevel)"
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)
for f in README.md CONTRIBUTING.md PULL_REQUEST_TEMPLATE.md docs/architecture.md docs/dev_environment.md \
         docs/database_partitioning.md docs/monitoring.md deploy/README.md docker/README.md \
         connectors/README.md events-processor/README.md events-processor/CLAUDE.md; do
  printf '%-34s %s  commits=%s\n' "$f" "$(git -C "$H" log -1 --format='%ad %h' --date=short -- "$f")" \
    "$(git -C "$H" log --oneline -- "$f" | wc -l)"
done
# expected (2026-10-01): README.md 2026-09-17 eb58675 commits=49 ... events-processor/CLAUDE.md 2026-03-05 c340ddf commits=1
git -C "$H" log --format=%an -- docs/architecture.md | grep -v dependabot | sort | uniq -c | sort -rn | head -3
```

The history clone holds `origin` only. For commits made in this working clone after it, run
`git log -1 --format='%ad %h' --date=short -- <file>` in the working repo, or
`history-setup.sh --refresh`.
