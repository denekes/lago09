# What is invisible from here, and how to ask the owner

Read this when your verdict depends on something no command in this sandbox can show, such as
production config, private repos, dashboards or intent. Use it to phrase the question so it can be
answered once and recorded. The OD gate itself (who decides, and what blocks until then) is owned by
`change-control`. This file is about recognising invisibility and asking well.

## 1. The invisibility map (checked 2026-10-01; owner decisions of 2026-10-02 folded in)

| Invisible thing | Why you cannot see it | Best proxy you CAN see (label it as a proxy) | Route |
|---|---|---|---|
| Lago Cloud production config: Debezium columns, the CDC consumers' Kafka SASL/TLS and broker list, partitions, replicas, grace period (`LAGO_USE_MEMORY_CACHE` itself is answered: DECIDED OD-1) | No k8s or Helm config for Cloud in this repo. The deploy pipeline sits in private lago-deploy (`events-processor/Dockerfile.staging:8` is a comment naming its workflow). | The public Helm chart `getlago/lago-helm-charts` (`d473b1e`, 2026-08-18, a depth-1 clone): its `events-processor-worker-deployment.yaml` is gated on `global.clickhouse.enabled`, has `replicas: 1`, and contains 0 `MEMORY_CACHE` references. That describes **Helm self-hosters**, not Cloud. Dev defaults: `.env.development.default` sets no `LAGO_USE_MEMORY_CACHE`, so dev runs DB mode; production runs memory-cache mode by owner statement (DECIDED OD-1 (owner, 2026-10-02)). | OPEN DECISION OD-1b (owner) for the CDC config; hardening: DEFAULT APPLIED OD-20 (campaign W6) |
| Production lago-api flags (`pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation`) | They are DB rows, per organization. | Flag-reading code at `$API`, plus the upstream change log since the pin (worked-examples Example E). | OPEN DECISION OD-8 |
| Production ClickHouse, Postgres and Kafka versions | Not in any repo. | Dev pins, e.g. `clickhouse/clickhouse-server:26.2-alpine` (`docker-compose.dev.yml:460`). Version-scope every probe result. | UNVERIFIED; ask |
| Private repos: lago-deploy, lago-sidekiqs, lago-license, lago-self-billing (lago-embedded is also auth-walled but never referenced here, so its existence is UNVERIFIED) | `git ls-remote` asks for credentials. Anonymous GitHub cannot tell private from nonexistent. | Where this repo references them: `events-processor/Dockerfile.staging:8` and the `5308258` body (lago-deploy), `docs/monitoring.md:51` (lago-sidekiqs), `docs/dev_environment.md:314` (lago-license). Commit `5070e24` mentions lago-self-billing. | UNVERIFIED |
| Branch protection and required checks | `https://api.github.com/repos/getlago/lago/branches/main/protection` returns 403 here; reading it needs admin. | Workflow triggers: only `.github/workflows/events-processor-tests.yml` runs on PRs, with a path filter. | UNVERIFIED; ask (change-control gates do not assume CI enforcement) |
| PR discussions, reviews, ticket contents (ING-, INF-) | `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/getlago/lago/pulls/797` gives 403 in this session, and the tracker is private. | For squash merges, the commit body is the PR description. A ticket id is a pointer only. | none |
| Sentry issues, DLQ dashboards, consumer-lag alerts | External systems. | events-processor has no metrics or health endpoint (`grep -rn -e ListenAndServe -e promhttp events-processor --include=*.go` prints nothing). The DLQ lands in ClickHouse `events_dead_letter` (`$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb:10`). No DLQ replay tool exists: at the pin no code under `$API/app` or `$API/lib` uses `Clickhouse::EventsDeadLetter` beyond its model, and the `events:reprocess` rake task (`$API/lib/tasks/events.rake:90`) is re-enrichment, not DLQ replay. ADR-001 (DECIDED OD-2) specifies an operator-gated replay tool and the counters to build; until built, a manual re-feed is CANDIDATE. | UNVERIFIED; build per ADR-001 (`event-accounting-campaign`) |
| Secret rotation (the `LAGO_LICENSE` value in `16c8b68`); whether ING-123 (`9ef876a`) leaked across tenants | Only the owner knows. | Counts only (`grep -c`); never print the value (change-control N11). | OPEN DECISION OD-9 |
| Org-level GitHub settings (Dependabot, default `GITHUB_TOKEN` permissions, `linux-arm64` runner) | Org settings are not in the repo. | `.github/dependabot.yml` is absent, yet dependabot authors commits such as `065fe59`, so it is configured elsewhere. | UNVERIFIED |
| Intent: "is behaviour X deliberate?" (`"<nil>"` values, the 50 vs 72 subject limit) | Code shows what IS, not what was MEANT. | Precedent counts from history, labelled "de-facto". | OPEN DECISION OD-7 for the subject limit; otherwise ask. Settled 2026-10-02: the 12 h horizon stays as ADR-001's default retry max age (DECIDED OD-2); `Decimal(38,26)` may change (DECIDED OD-3) |

Rule: a proxy narrows a question; it never answers it. Write "Helm chart shows replicas 1 (proxy;
Cloud UNVERIFIED)", never "production runs 1 replica".

## 2. The owner-decision index (the register is change-control §9)

One namespace, OD-1..OD-24 plus sub-ids (OD-1b), owned by `change-control` §9. This index only helps
you find the right number and its status. Read the decision text, the default, who decides and the
closing evidence in change-control §9 before you rely on one; they are not copied here, so they
cannot drift. Status as of 2026-10-02: OD-1..OD-5 and OD-24 DECIDED, OD-1b OPEN (urgent),
OD-20 DEFAULT APPLIED, OD-21..OD-23 proposed (OPEN), all others OPEN.

| ID | Topic (one line) | Status |
|---|---|---|
| OD-1 | Does production run the memory cache (badger + Debezium)? | DECIDED OD-1 (owner, 2026-10-02): yes |
| OD-1b | Production Debezium column list, CDC Kafka SASL/TLS and broker list | OPEN DECISION OD-1b (owner); urgent, verify first |
| OD-2 | Delivery contract for retryable failures; is the 12 h horizon a product decision? | DECIDED OD-2 (owner, 2026-10-02), delegated: ADR-001 in `event-accounting-campaign` |
| OD-3 | Is a ClickHouse schema change acceptable? | DECIDED OD-3 (owner, 2026-10-02): yes |
| OD-4 | Is a paired lago-api PR mandatory for contract changes? | DECIDED OD-4 (owner, 2026-10-02): no, unless another repo depends on the contract |
| OD-5 | Is the Docker-free `ep-test.sh` recipe an accepted pre-PR gate? | DECIDED OD-5 (owner, 2026-10-02): yes |
| OD-6 | golangci-lint policy and config | open |
| OD-7 | Commit subject 50 vs 72, the `misc` type (de-facto counts below), branch naming | open |
| OD-8 | Production state of `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` | open |
| OD-9 | Was the leaked `LAGO_LICENSE` rotated; was ING-123 a cross-tenant leak? | open |
| OD-10 | Is the all-in-one `getlago/lago` image still supported; backfill missing tags; alert on a failed release build? | open |
| OD-11 | Delete the dead `release.yml` `repository_dispatch`? | open |
| OD-12 | Release-day fix policy: rebuild from `main` or cut a patch release? | open |
| OD-13 | Maintenance releases and the `latest` tag | open |
| OD-14 | Pin lago-front's `@main` call of the reusable build workflow? | open |
| OD-15 | Intent of v1.52.1 / v1.41.x; who owns the `deploy/*.yml` image tags? | open |
| OD-16 | Self-host default of `LAGO_SIDEKIQ_WEB` (security) | open |
| OD-17 | Is the HTTP connector ever publicly reachable; may it trust a client-sent `organization_id`? (security) | open |
| OD-18 | May the AWS account id stay in public workflows? (security) | open |
| OD-19 | Full event JSON in Sentry extras and a TTL-less DLQ under SOC2 (security) | open |
| OD-20 | Who owns memory-cache (badger + Debezium CDC) hardening? (sits next to OD-1) | DEFAULT APPLIED OD-20: `event-accounting-campaign` W6 (owner may reassign) |
| OD-21 | Rulings on the re-implementation kit's owner-ruled rebuild decisions, as one batch (`reimplementation-kit` RBD rows marked `owner`, KQ-3) | proposed 2026-10-02, open: corrected vectors ship as `ruling: proposed` (UNRULED) |
| OD-22 | Retry-topic name, env variable, headers and attempt count of ADR-001 (`reimplementation-kit` KQ-1) | proposed 2026-10-02, open: ADR-001 defaults stay CANDIDATE names |
| OD-23 | Legal review of the kit for proprietary rebuilds, and the lago-expression licence (`reimplementation-kit` KQ-7, KQ-8) | proposed 2026-10-02, open: no proprietary rebuild, the kit specifies the expression language |
| OD-24 | Clean-room isolation channel for kit acceptance (`reimplementation-kit` KQ-11) | DECIDED OD-24 (owner, 2026-10-02): option A, pack-only branch `kit-pack-v1` + fresh remote sessions |

OD-7 precedent is regex-dependent; quote the count with its regex (as of 2026-10-01):

```bash
git -C "$H" log --format=%s | grep -cE '^misc(\([^)]*\))?: '   # 279: strict misc(scope): / misc:
git -C "$H" log --format=%s | grep -cE '^misc(\(|:|!)'          # 283: also scopes without a colon, e.g. "misc(kafka) Add …"
```

A question that fits none of these is NEW. Raise it the way change-control defines "owner" (Terms): a
GitHub issue titled "OD-n: <topic>" carrying the evidence block, plus a C0 PR that adds the row to
change-control §9. The owner confirms the number.

## 3. The owner-question template

```
OWNER QUESTION  <OD-n | NEW>   <date>   asked by <name/agent>
Decision needed:   <one sentence; yes/no or pick one option>
Why it matters:    <billing/security impact in one line, with path:line or sha>
What the repo shows (evidence):   <bullets with path:line / sha / command -> output>
What the repo cannot show:        <the invisible item from the map above>
Options:           (a) …  (b) …  (c) …   <recommendation, labelled CANDIDATE>
Default meanwhile: <from change-control §9>
Blocks:            <change class C0–C7, PR, campaign gate>
Answer recorded at: <ADR / PR comment / change-control register line; filled in on answer>
```

Phrase it so a yes or no settles it. Put the evidence in the question, so the owner does not have to
rediscover it. One decision per question.

Bad: "Is the memory cache used?"
Good (the open half of OD-1, now OD-1b): "OD-1b: Production runs `LAGO_USE_MEMORY_CACHE=true`
(DECIDED OD-1). Does its Debezium `column.include.list` include `charges.pay_in_advance`,
`charges.accepts_target_wallet` and `billable_metrics.recurring`? They are absent from
`extra/debezium_config.json:2`. Without them, in-advance events silently stop after the first CDC
update. Which SASL/TLS settings and broker list do the CDC consumers get? They pass
`LAGO_KAFKA_BOOTSTRAP_SERVERS` as one seed with no auth (`events-processor/cache/consumer.go:27-35`)."

## 4. What counts as an owner answer (the evidence class "owner statement")

<!-- evidence-check: off (normative definitions) -->
- **Written, dated, attributable, durable:** an ADR or PR comment by the owner, a commit body, or an
  update to change-control's register. A chat message relayed by an agent is not an owner statement,
  and no agent message is owner approval.
- **Recorded where the decision lives:** change-control's register, then cite it as
  "OPEN DECISION OD-n, decided <date>: <answer> (<link or sha>)".
- **Scoped:** "production runs the memory cache" answers OD-1 for the date asked (2026-10-02). Re-ask
  when topology changes.
- **Delegated:** when the owner delegates a choice ("reason with industry best practices", OD-2 on
  2026-10-02), record the choice as an ADR with status ACCEPTED (delegated), cite the practice it
  relies on, and keep it amendable by the owner (ADR-001 in `event-accounting-campaign`).
- **Partial:** an answer that settles only part of a question closes that part (DECIDED OD-n); the
  rest becomes a new OPEN sub-id (OD-1b).
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
