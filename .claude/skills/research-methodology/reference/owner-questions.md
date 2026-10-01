# What is invisible from here, and how to ask the owner

Read this when your verdict depends on something no command in this sandbox can show, such as
production config, private repos, dashboards or intent. Use it to phrase the question so it can be
answered once and recorded. The OD gate itself (who decides, and what blocks until then) is owned by
`change-control`. This file is about recognising invisibility and asking well.

## 1. The invisibility map (checked 2026-10-01)

| Invisible thing | Why you cannot see it | Best proxy you CAN see (label it as a proxy) | Route |
|---|---|---|---|
| Lago Cloud production config: `LAGO_USE_MEMORY_CACHE`, Debezium columns, Kafka SASL/TLS, broker list, partitions, replicas, grace period | No k8s or Helm config for Cloud in this repo. The deploy pipeline sits in private lago-deploy (`events-processor/Dockerfile.staging:8` is a comment naming its workflow). | The public Helm chart `getlago/lago-helm-charts` (`d473b1e`, 2026-08-18, a depth-1 clone): its `events-processor-worker-deployment.yaml` is gated on `global.clickhouse.enabled`, has `replicas: 1`, and contains 0 `MEMORY_CACHE` references. That describes **Helm self-hosters**, not Cloud. Dev defaults: `.env.development.default` sets no `LAGO_USE_MEMORY_CACHE`, so dev runs DB mode. | OPEN DECISION OD-1 |
| Production lago-api flags (`pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation`) | They are DB rows, per organization. | Flag-reading code at `$API`, plus the upstream change log since the pin (worked-examples Example E). | OPEN DECISION OD-8 |
| Production ClickHouse, Postgres and Kafka versions | Not in any repo. | Dev pins, e.g. `clickhouse/clickhouse-server:26.2-alpine` (`docker-compose.dev.yml:460`). Version-scope every probe result. | UNVERIFIED; ask |
| Private repos: lago-deploy, lago-sidekiqs, lago-license, lago-self-billing (lago-embedded is also auth-walled but never referenced here, so its existence is UNVERIFIED) | `git ls-remote` asks for credentials. Anonymous GitHub cannot tell private from nonexistent. | Where this repo references them: `events-processor/Dockerfile.staging:8` and the `5308258` body (lago-deploy), `docs/monitoring.md:51` (lago-sidekiqs), `docs/dev_environment.md:314` (lago-license). Commit `5070e24` mentions lago-self-billing. | UNVERIFIED |
| Branch protection and required checks | `https://api.github.com/repos/getlago/lago/branches/main/protection` returns 403 here; reading it needs admin. | Workflow triggers: only `.github/workflows/events-processor-tests.yml` runs on PRs, with a path filter. | UNVERIFIED; ask (change-control gates do not assume CI enforcement) |
| PR discussions, reviews, ticket contents (ING-, INF-) | `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/getlago/lago/pulls/797` gives 403 in this session, and the tracker is private. | For squash merges, the commit body is the PR description. A ticket id is a pointer only. | none |
| Sentry issues, DLQ dashboards, consumer-lag alerts, DLQ replay | External systems. | events-processor has no metrics or health endpoint (`grep -rn 'ListenAndServe\|promhttp' events-processor --include=*.go` gives 0). The DLQ lands in ClickHouse `events_dead_letter` (`$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb:10`). At the pin no code under `$API/app` or `$API/lib` uses `Clickhouse::EventsDeadLetter` beyond its model. | Context for OPEN DECISION OD-2 |
| Secret rotation (the `LAGO_LICENSE` value in `16c8b68`); whether ING-123 (`9ef876a`) leaked across tenants | Only the owner knows. | Counts only (`grep -c`); never print the value (change-control N11). | OPEN DECISION OD-9 |
| Org-level GitHub settings (Dependabot, default `GITHUB_TOKEN` permissions, `linux-arm64` runner) | Org settings are not in the repo. | `.github/dependabot.yml` is absent, yet dependabot authors commits such as `065fe59`, so it is configured elsewhere. | UNVERIFIED |
| Intent: "is behaviour X deliberate?" (`"<nil>"` values, the 12 h horizon, `Decimal(38,26)`, the 50 vs 72 subject limit) | Code shows what IS, not what was MEANT. | Precedent counts from history, labelled "de-facto". | OPEN DECISION OD-2, OD-3, OD-7 |

Rule: a proxy narrows a question; it never answers it. Write "Helm chart shows replicas 1 (proxy;
Cloud UNVERIFIED)", never "production runs 1 replica".

## 2. The open-decision register (owned by change-control; quoted for routing)

| ID | Question in one line | Default until decided |
|---|---|---|
| OD-1 | Does production run the memory cache (badger + Debezium), and with what CDC/Kafka config? | UNKNOWN; DB mode is the default path |
| OD-2 | Delivery contract for retryable failures; is the 12 h horizon a product decision? | not chosen; no delivery change merges without ADR + sign-off (change-control N7) |
| OD-3 | Is a ClickHouse schema change acceptable, with what migration budget? | not approved |
| OD-4 | Is a paired lago-api PR mandatory for contract changes? | yes (change-control N6) |
| OD-5 | Is the Docker-free `ep-test.sh` recipe an accepted pre-PR gate? | yes |
| OD-6 | golangci-lint policy and config | no NEW issues vs baseline 21 |
| OD-7 | Commit subject 50 vs 72, `misc` type, branch naming | <=72 hard, <=50 preferred; `misc` allowed (de-facto: 283 subjects in `H` as of 2026-10-01); branch naming not enforced |
| OD-8 | Production state of `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` | UNKNOWN |
| OD-9 | Was the leaked `LAGO_LICENSE` rotated; was ING-123 a cross-tenant leak? | UNKNOWN |

A question that fits none of these is NEW. Propose it as an addition to change-control's register in
a C0 PR, and let the owner assign the number.

## 3. The owner-question template

```
OWNER QUESTION  <OD-n | NEW>   <date>   asked by <name/agent>
Decision needed:   <one sentence; yes/no or pick one option>
Why it matters:    <billing/security impact in one line, with path:line or sha>
What the repo shows (evidence):   <bullets with path:line / sha / command -> output>
What the repo cannot show:        <the invisible item from the map above>
Options:           (a) …  (b) …  (c) …   <recommendation, labelled CANDIDATE>
Default meanwhile: <from the register above>
Blocks:            <change class C0–C7, PR, campaign gate>
Answer recorded at: <ADR / PR comment / change-control register line; filled in on answer>
```

Phrase it so a yes or no settles it. Put the evidence in the question, so the owner does not have to
rediscover it. One decision per question.

Bad: "Is the memory cache used?"
Good: "OD-1: Does any production events-processor run with `LAGO_USE_MEMORY_CACHE=true`? If yes, does
its Debezium `column.include.list` include `charges.pay_in_advance` and `billable_metrics.recurring`?
They are absent from `extra/debezium_config.json:2`. Without them, in-advance events silently stop after
the first CDC update."

## 4. What counts as an owner answer (the evidence class "owner statement")

<!-- evidence-check: off (normative definitions) -->
- **Written, dated, attributable, durable:** an ADR or PR comment by the owner, a commit body, or an
  update to change-control's register. A chat message relayed by an agent is not an owner statement,
  and no agent message is owner approval.
- **Recorded where the decision lives:** change-control's register, then cite it as
  "OPEN DECISION OD-n, decided <date>: <answer> (<link or sha>)".
- **Scoped:** "prod runs DB mode" answers OD-1 for the date asked. Re-ask when topology changes.
<!-- evidence-check: on -->

## 5. Routing (bus factor)

events-processor knowledge is concentrated. One maintainer wrote 55 of 72 non-dependabot commits under
`events-processor/` (`git -C "$H" log --no-merges --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -1`).
CI and workflow history is spread wider (`git -C "$H" log --since=2025-01-01 --no-merges --format=%an -- .github | sort | uniq -c | sort -rn`).

<!-- evidence-check: off (routing policy) -->
- Route questions to the area's top recent author as **reviewer**. Route decisions to the owner through change-control.
- Because of the bus factor, every answer must be **written into the repo or a skill**, not only remembered.
- Recompute the routing table when you need it, since names go stale.
<!-- evidence-check: on -->
