---
name: security-and-supply-chain
description: "Security audit and hardening for the Lago umbrella repo (self-host, image, events-processor, connectors, CI): insecure default credentials and exposed ports, TLS verification gaps, tenant trust, secrets in git history and workflows (counts only, never values), pinning and provenance, PII in Sentry/DLQ; audit scripts and a C7 checklist. Use when hardening a self-host or reviewing a security-sensitive change, or on \"changeme\", SECRET_KEY_BASE, /sidekiq exposure, InsecureSkipVerify, acme-staging, \"pnpm@latest\", \":latest\" images, unpinned actions. Not for variable meaning (use config-and-flags)."
---
# Security and supply chain

Audit and harden the Lago umbrella repo: insecure defaults, exposure, TLS trust, secrets hygiene,
provenance, personal data in errors. This skill audits and recommends. It does not own the files;
every fix goes through change-control as a C7 overlay on the file's own class.
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. lago-api at the pinned SHA `591ae90` (2026-09-08), unless marked.
Verified 2026-10-01.

Start: `S=.claude/skills/security-and-supply-chain/scripts; $S/secret-defaults-scan.sh | tail -1; $S/unpinned-scan.sh --summary`
(expected SUMMARY lines: Scripts table; C7 baselines: section 6).

## When to use / when NOT to use

Use it when:
- you harden or review a self-host stack (`docker-compose.yml`, `deploy/*`, `docker/`);
- a diff touches secrets, TLS options, ports, `docker.sock`, `.gitignore`, auth, workflow
  permissions, images, actions, tools or vendored binaries (the C7 overlay);
- you must answer "was a secret ever committed?" without leaking it;
- you add a Sentry call, a log field or a DLQ field that carries event data.

Do NOT use it for:
- what a variable does, its default per plane or its boolean parsing -> `config-and-flags`;
- how to bring a stack up or operate it -> `run-and-operate`;
- release trains, image tags on registries, the reusable build workflow -> `release-and-images`;
- the gates, reviewers and doctrine for a commit or PR -> `change-control` (C7 row, change-control N11);
- the story behind an incident (`16c8b68`, `18b26d0`) -> `failure-archaeology`;
- events-processor topology and delivery rules -> `architecture-contract`;
- silent event loss or DLQ semantics -> `event-accounting-campaign`;
- probe harnesses (miniredis, kfake, scratch PG) -> `diagnostics-and-tooling`.

## Terms

- **Plane**: one way of running Lago with its own config files: root self-host
  (`docker-compose.yml`), deploy local/light/production (`deploy/docker-compose.*.yml`), all-in-one
  image (`docker/`), dev (`docker-compose.dev.yml` + `.env.development.default`).
- **Placeholder default**: `${VAR:-public-string}` in compose. If the operator does not set `VAR`,
  the app runs with the public string. Labels used here: `changeme`, `your-secret-key-base`,
  `your-encryption-key`, `azerty123456`.
- **Published port**: a compose `ports:` entry; without an IP prefix it binds all host interfaces
  and bypasses host firewalls such as UFW (Docker's own iptables chains; standard Docker
  behaviour, not exercised here).
- **History class** (secret-defaults-scan): EMPTY, INTERPOLATION (`${...}`), PLACEHOLDER, LITERAL.
  LITERAL is a lead to read yourself, not a verdict.
- **Pin class** (unpinned-scan): DIGEST (immutable) > EXACT `X.Y.Z` > MINOR `X.Y` > MAJOR `X` > LATEST.
- **C7**: change-control's security overlay class. It adds owner (security) review to the file's
  own class (C5 pins/CI, C6 compose/deploy, C2-C4 events-processor).
- **CANDIDATE**: proposed fix, not built or deployed here. **UNVERIFIED**: not proven by a file
  line, a commit or a command. **OPEN DECISION OD-n (owner)**: see change-control section 9.

## 0. Safety rule (change-control N11)

Never print a secret value: not in a terminal you paste from, not in a PR, not in a skill. Report
`sha`, `file:line`, KEY name and counts. To compare two historic values, compare them in-shell and
print only `SAME`/`DIFFERENT` (recipe in `reference/history-and-workflows.md` section 2). The scripts
here print KEY names and labels only.

## 1. Self-host defaults and exposure

Each row: where the default lives (file:line per plane), what it exposes, the hardening action.
Severity is this skill's CANDIDATE ranking. Full table, impact chains and the `.env` recipe:
`reference/selfhost-defaults.md` (read when you harden or review a plane).

| # | Insecure default | Root `docker-compose.yml` | deploy local / light / production | All-in-one `docker/runner.sh` | Dev | Impact | Hardening action |
|---|---|---|---|---|---|---|---|
| SD1 HIGH | `SECRET_KEY_BASE=your-secret-key-base-hex-64` | `:24` | `:27` / `:30` / `:30` | random, 16 bytes (`:9`) | `.env.development.default:71` | Signs the session JWT (HS256, `$API/app/services/utils/auth_token.rb:6,12,18`) and customer-portal tokens (`$API/app/controllers/concerns/customer_portal_user.rb:9`): forgeable by anyone who knows an id (inferred) | `SECRET_KEY_BASE=$(openssl rand -hex 64)` in `.env` |
| SD2 HIGH | `LAGO_ENCRYPTION_*=your-encryption-*` | `:29-31` | `:32-34` / `:35-37` / `:35-37` | random (`:12-14`) | `.env.development.default:72-74` (typo `encrpytion`) | Keys of ActiveRecord encryption of payment-provider and integration `secrets` (`$API/config/application.rb:35-37`, `app/models/concerns/secrets_storable.rb:7`) | generate before first start; rotating later needs the old keys kept (UNVERIFIED for lago-api) |
| SD3 HIGH | `POSTGRES_PASSWORD=changeme` + DB published on all interfaces | `:97` + `:104` | `:87`+`:94` / `:111`+`:118` / `:111`+`:118` | random (`:8`), not published | `docker-compose.dev.yml:46`, `:54` | Remote DB login with a public password; with SD2 also decrypts provider secrets | strong password; drop `ports:` or bind `127.0.0.1:5432:5432` |
| SD4 HIGH | Redis published on all interfaces, no `--requirepass` | `:119` (svc `:106`) | `:113` / `:137` / `:137` | not published | `docker-compose.dev.yml:78` (password only if `REDIS_PASSWORD` set, `:70`) | Sidekiq queue and cache readable and writable by anyone who reaches 6379 | drop `ports:`; add `--requirepass` (CANDIDATE) |
| SD5 HIGH | Sidekiq Web on, no auth: `LAGO_SIDEKIQ_WEB=true` | `:28` | `:31` / `:34` / `:34` | unset (OFF) | `.env.development.default:6` | `$API/config/routes.rb:4-6` mounts `/sidekiq` + `/sidekiq/prometheus/metrics`; `$API/config/initializers/sidekiq.rb:22-28` adds only cookies/session; 0 auth middleware in `$API`. Reach: `http://<host>:3000/sidekiq`; light/prod `https://<domain>/api/sidekiq` (Traefik strips `/api`, `production.yml:203-205`) | `LAGO_SIDEKIQ_WEB=false` (verified to resolve to `"false"` via `docker compose config`); OPEN DECISION OD-16 (owner): default to false? |
| SD6 HIGH | Traefik dashboard `--api.insecure=true` on published 8080 | - | - / `:80`,`:89` / `:80`,`:89` | - | `traefik/traefik.yml:19-21`, router `traefik.lago.dev` (`docker-compose.dev.yml:33-37`) | unauthenticated view of routers, services, backends | remove the flag and the 8080 mapping, or bind to 127.0.0.1 |
| SD7 MED | Let's Encrypt **staging** CA hard-coded | - | - / `light.yml:87` / `production.yml:87` | - | - | certificates browsers reject; operators click through warnings | delete the `caServer` line after a staging dry run |
| SD8 MED | Portainer `ADMIN_PASSWORD=${PORTAINER_PASSWORD:-changeme}`, `portainer-ce:latest`, docker.sock | - | - / - / `:465`, `:457`, `:461` | - | - | host control via `https://<domain>/portainer` (`:469`) if the env is honoured (UNVERIFIED) | real password, pinned tag, or drop Portainer |
| SD9 MED | docker.sock mounted (`:ro` does not limit the API) | - | - / `:92` / `:92`, `:461` | `runner.sh:52-57`, `docker/README.md:28` | `docker-compose.dev.yml:31` | root-equivalent on the host for whoever controls the container | socket proxy with read-only endpoints; see section 4 |
| SD10 LOW | Segment telemetry on unless `LAGO_DISABLE_SEGMENT=true` | `:52` (no default) | `:53` / `:56` / `:56` (empty) | unset (on; key falls back to `"changeme"`) | `.env.development.default:9` (`true`) | Documented, intentional: `README.md:262`; `$API/config/initializers/analytics_ruby.rb:3,20` | opt out with `LAGO_DISABLE_SEGMENT=true` if required |
| SD11 LOW | S3 keys `azerty123456` | `docker-compose.yml:33-34` | `local.yml:36-37` / `light.yml:39-40` / `production.yml:39-40` | - | - | only when `LAGO_USE_AWS_S3=true` | set real keys or leave S3 off |
| SD12 LOW | `./extra/certbot` (Let's Encrypt private keys) not git-ignored | `extra/init-letsencrypt.sh:10` vs `.gitignore:8` (`/extra/ssl/certbot`) | - | - | - | `git add -A` would commit private keys | add `/extra/certbot` to `.gitignore` (C6+C7) |
| SD13 LOW | secrets persisted in plaintext | - | - | `/data/.env` (`runner.sh:64-74`) | - | anyone reading the volume reads every secret | restrict volume access |

Also: `/metrics` (Yabeda) is always mounted (`$API/config/routes.rb:10`); Gotenberg runs with
`--chromium-ignore-certificate-errors=true` (`deploy/docker-compose.local.yml:243`, `light.yml:304`,
`production.yml:452`). Dev-only weak settings (ClickHouse `default`/`default` from `::/0`,
`extra/clickhouse/users.d/users.xml:15-17`; Kafka 9092/19092 and Connect REST 8083 published,
`docker-compose.dev.yml:382-383,441`) matter only on an untrusted network.

Check a plane without printing secrets (runnable without a Docker daemon):

```bash
docker compose -f docker-compose.yml config 2>/dev/null | grep -c -E 'your-secret-key-base|your-encryption-|changeme'
# 26 with an empty environment (2026-10-01); 0 once SECRET_KEY_BASE, the 3 LAGO_ENCRYPTION_* and POSTGRES_PASSWORD are set
```

## 2. TLS and trust

Matrix and fixes: `reference/tls-and-trust.md` (read when a change touches a TLS option, a Redis,
Kafka or OTEL client, or a connector).

| Finding | Where | Status |
|---|---|---|
| events-processor Redis TLS never verifies the server | `events-processor/config/redis/redis.go:44` (`InsecureSkipVerify: true`); TLS on via `LAGO_REDIS_STORE_TLS` or legacy `ENV=production` (`processors/main_processor.go:84-91`) | VERIFIED by reading; go-redis v9.17.1 reads `TLSConfig` at dial time, so it takes effect |
| lago-api Redis TLS: Sidekiq and cache always `VERIFY_NONE`; the store reader verifies unless `LAGO_REDIS_STORE_DISABLE_SSL_VERIFY` | `$API/lib/lago/redis_config_builder.rb:56,76`; `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:63-69` | VERIFIED by reading; fix needs a paired lago-api PR (change-control N6, OD-4) |
| Memory-cache CDC consumers: no TLS, no SASL | `events-processor/cache/consumer.go:27-35` | only with `LAGO_USE_MEMORY_CACHE=true`; prod use OPEN DECISION OD-1 (owner); hardening unowned, OPEN DECISION OD-20 (as-is defects: `architecture-contract` WP6-WP10) |
| Positive controls | Kafka `kgo.DialTLS()` (`config/kafka/kafka.go:66-69`); OTEL secure unless `OTEL_INSECURE=true` (`config/tracing/tracer.go:128-129`); lago-api HTTP client verifies outside dev/test (`$API/lib/lago_http_client/lago_http_client/session_client.rb:52-55`) | VERIFIED |
| HTTP connector trusts the client's `organization_id`, no auth | `connectors/http.yml:25` (`root.organization_id = this.event.organization_id`), `:1-7` (`http_server` on `0.0.0.0:3000`, no auth) | VERIFIED by reading; SQS and Kinesis pin `${ORGANIZATION_ID}` (`sqs.yml:27`, `kinesis.yml:31`) |

Tenant risk of `connectors/http.yml` (inferred, not exercised): anyone who reaches the port writes
straight to the raw topic, skipping lago-api's API-key check, and picks the tenant. An event that
carries another org's `organization_id` and a matching `external_subscription_id` is enriched
against that org's subscription and billed to it. Fix (CANDIDATE, C4+C7): pin
`root.organization_id = "${ORGANIZATION_ID}"` as SQS/Kinesis do, or front it with an authenticating
gateway. OPEN DECISION OD-17 (owner): is it ever reachable from outside a private network?

## 3. Secrets in history and workflows

Details and the safe-inspection protocol: `reference/history-and-workflows.md` (read before you
inspect any historic secret or touch a credentialed workflow).

- **`LAGO_LICENSE`** (OPEN DECISION OD-9, owner): a real value was added to
  `.env.development.example` in `16c8b68` (authored 2025-01-23 on branch `feat/improv-dev-env`),
  carried into `.env.development.default` by the rename `84b6eef` the same day, and blanked by
  `6dd7e56` (#477). Exposure: 37 days on `main` (merge `0a67ac0` #455 2025-01-29 -> `6dd7e56`
  2025-03-07); up to 43 days if the feature branch was public from 2025-01-23 (UNVERIFIED); still
  in history. Removed value == added value (in-shell compare: SAME). Rotation is UNVERIFIED (OD-9).
  Treat it as leaked until the owner records a rotation date. Never rewrite history to "fix" it
  (change-control N2).
- **AWS account id** in public workflows: `.github/workflows/build-processors-image.yaml:15`
  (`4955f79`) and `build-connectors-image.yaml:19` (`2146a18`). The `5308258` commit message says the
  staging Dockerfile copy "sat in the private lago-deploy repo specifically to keep ECR URLs and the
  AWS account id out of a public repository". Policy and practice disagree: OPEN DECISION OD-18 (owner).
- **OIDC plumbed, unused**: `role-to-assume` input (`docker-build-multi-arch.yaml:90-94`, "Preferred
  over registry-user/registry-token") and `id-token: write` (`:126-129`) since `5ee8e98`. Both ECR
  callers still pass long-lived `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
  (`build-processors-image.yaml:21-23`, `build-connectors-image.yaml:26-28`). CANDIDATE: IAM role +
  `role-to-assume`, then delete the static keys.
- **Workflow script injection / fingerprint** (latent): `secrets.build-secrets` is pasted into a
  bash script (`docker-build-multi-arch.yaml:255`) and hashed into a public 8-hex tag suffix
  (`:271-274`). No caller passes it explicitly (as of 2026-10-01); `release-images.yml:42` uses
  `secrets: inherit`, so it applies only if a repository secret named `build-secrets` exists
  (UNVERIFIED, repository settings).
- **Positive controls**: no `pull_request_target`/`workflow_run` triggers
  (`grep -n 'pull_request_target\|workflow_run' .github/workflows/*` is empty); 0 history hits for AWS
  access keys, private keys, GitHub/Slack tokens or Stripe live keys (`git log -G` counts in
  `reference/history-and-workflows.md` section 1).

Scan history safely (prints sha, file, KEY and class; never values):

```bash
.claude/skills/security-and-supply-chain/scripts/secret-defaults-scan.sh --history        # env-style files
.claude/skills/security-and-supply-chain/scripts/secret-defaults-scan.sh --history-wide   # every path
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)
git -C "$H" log --format=%h -G'AKIA[0-9A-Z]{16}' HEAD | wc -l                              # count only; expect 0
```

## 4. Pinning and provenance

Full inventory with fixes: `reference/supply-chain.md` (read when you add or bump an image, action,
tool or binary). `scripts/unpinned-scan.sh` regenerates it.

| Item | Where | Risk | Recommended fix (CANDIDATE) | Class |
|---|---|---|---|---|
| `pnpm@latest` | `docker/Dockerfile:12` | unpinned tool fetched at build time. The v1.35.0 release build failed in this `corepack prepare pnpm@latest` / `pnpm prune` RUN step (`18b26d0`, #617, whose message blames a pnpm update); which pnpm ran then is UNVERIFIED. lago-front pins `packageManager` `pnpm@10.34.5`; corepack runs that version inside the project (probe recorded in `release-and-images`), so `pnpm@latest` is downloaded but inert today; a conditional risk if front drops `packageManager` | `corepack enable` only, or `pnpm@10.34.5` | C5+C7 |
| `curl https://sh.rustup.rs \| bash` | `docker/Dockerfile:25` | unverified installer, floating Rust | pinned toolchain or copy from a pinned `rust:` image | C5+C7 |
| lago-expression cloned by tag, no commit check | `events-processor/Dockerfile:3-5`, `Dockerfile.dev:3-5`, `Dockerfile.staging:23-27`, `events-processor-tests.yml:40-45` | a moved tag changes the linked FFI lib; `v0.2.0` = `a22ab02` (as of 2026-10-01) | assert `git rev-parse HEAD` = `a22ab022ae6f2ebd287244e670626cac98f449f1`; `cargo build --release --locked`; move all 4 together (change-control N3) | C5+C7 |
| Floating bases | `events-processor/Dockerfile:1,7,17` (`rust:1.85`, `golang:1.25`, `debian:13-slim`); `docker/Dockerfile:5` (`node:24-alpine`) | image content changes between builds of one commit | digest pins with scheduled bumps | C5+C7 |
| `:latest` images | `Dockerfile.staging:12-13` (SOC2 "hardened" bases); `production.yml:457` Portainer; dev `:355,436,495`; `deploy/deploy.sh:310` `getlago/lago:latest` | anything can arrive, including breaking majors | digest or exact tag | C5/C6+C7 |
| Actions not SHA-pinned | 44 mutable `uses:` refs, 0 SHA; `checkout@v3`/`setup-go@v4` (`events-processor-tests.yml:38,41,59`) | a re-tagged action runs with Docker Hub/AWS secrets | full-SHA pins with `# vX.Y.Z` comments; dependabot for actions (owner) | C5+C7 |
| Vendored jars, no checksums | `extra/kafka-connect/` (8 jars, `d7355a6`) | binaries with no recorded provenance | all 8 MATCH upstream (as of 2026-10-01, `vendored-jar-verify.sh`); commit `SHA256SUMS` | C6+C7 |
| docker.sock mounts | see SD9 (e.g. `deploy/docker-compose.production.yml:92,461`) | root-equivalent | socket proxy / separate gotenberg | C6+C7 |
| Production EP image runs as root | `events-processor/Dockerfile` (no `USER`; staging has `USER 65532`, `Dockerfile.staging:45`) | container compromise = root | add a non-root `USER` | C5+C7 |
| `buildx version: latest` | `release-docker-image.yml:42`, `release-processors-image.yml:42` | builder drift in release builds | pin | C5 |

`govulncheck` could not run here (proxy returns `Forbidden` for `vuln.go.dev`); the pinned command
is in `reference/supply-chain.md` section 3. Result: UNVERIFIED.

## 5. Data in errors (PII)

Details: `reference/data-in-errors.md` (read before adding any Sentry extra, log field or DLQ field).

- Sentry extra `event` = the whole raw event, including the free-form `properties` map:
  `processors/events_processor/processor.go:71` (capturable enrichment failure) and
  `event_producer_service.go:72` (DLQ produce failure), via `utils/error_tracker.go:13-24`. Sentry
  is on only when `SENTRY_DSN` is set (`main.go:53-58`); no `BeforeSend` scrubber exists.
- DLQ: `FailedEvent` carries the full event (`event_producer_service.go:51-68`,
  `models/event.go:50-56`); lago-api lands it in ClickHouse `events_dead_letter` (JSON column
  `event`, MergeTree, no TTL anywhere in `$API/db/clickhouse_migrate`).
- OPEN DECISION OD-19 (owner): is raw event data in Sentry and an un-expiring DLQ table
  acceptable under the data-handling policy? `events-processor/Dockerfile.staging:3` cites SOC2;
  `README.md:192` claims SOC 2 Type II. Until decided: add no new payload-carrying extras or log fields. CANDIDATE:
  send `organization_id`, `transaction_id`, `code`, `error_code` instead of `event` in the two
  Sentry calls.

## 6. Security review checklist for C7 changes

Route through change-control (C7 row: owner (security) sign-off; evidence = counts and file:line
only). Tick every line that applies and paste the script SUMMARY lines into the PR.

- [ ] Classified: the file's own class (C2-C6) plus C7 (change-control section 2).
- [ ] No secret value in the diff, PR body, commit message or terminal paste (change-control N11). Placeholders
      stay obviously fake; no real key in `*.default`, `*.example`, compose, docs or skills.
- [ ] `secret-defaults-scan.sh` SUMMARY: `placeholders`, `sensitive_ports`, `redis_noauth` did not
      go up (or each increase is explained). Baseline 50 / 18 / 4 (2026-10-01).
- [ ] `unpinned-scan.sh --summary`: `images_latest`, `tools_latest`, `actions_mutable` did not go up.
      Baseline 7 / 3 / 44. New third-party actions are SHA-pinned.
- [ ] New or changed `ports:` bind to `127.0.0.1` unless public exposure is the point; no new
      `docker.sock` mount without owner sign-off.
- [ ] Auth: no new unauthenticated endpoint; `sidekiq-web-exposure.sh` verdicts did not get worse.
- [ ] TLS: no new `InsecureSkipVerify`, `VERIFY_NONE`, `--insecure` or `ignore-certificate-errors`;
      an existing one is not widened.
- [ ] Tenant scoping: new events-processor SQL has `organization_id` and a pinned sqlmock (change-control N4); no
      ingest path takes `organization_id` from an unauthenticated client.
- [ ] Data: no new Sentry extra, log field or DLQ field carries `properties` or a whole event.
- [ ] Workflows: no new `pull_request_target`; secrets via `env:` not `${{ }}` inside `run:`;
      `permissions:` declared; OIDC preferred over static cloud keys.
- [ ] Binaries/vendored files: checksum recorded or verified (`vendored-jar-verify.sh`).
- [ ] `.gitignore` covers any new path that can hold keys or certificates.
- [ ] If something secret was ever pushed: rotate it, record the date (not the value), tell the
      owner (OD-9 pattern). History rewriting is not a remedy (change-control N2).
- [ ] OPEN DECISIONS you rely on are labelled (OD-1/OD-20 memory cache, OD-4 paired lago-api PR, OD-9,
      OD-16..OD-19; register: change-control section 9).

## 7. If you see X, do Y

<!-- evidence-check: off routing table; evidence in sections 1-5 -->
| You see | Do |
|---|---|
| a real-looking value in a diff of `*.default` / `*.example` / compose | stop; do not echo it; `precommit-guard.sh` (change-control) G2 flags it; replace it with an empty or obviously fake value; if it was pushed, rotate it |
| a request to "show the old licence key" | refuse; give sha, file and dates from section 3 |
| `LAGO_SIDEKIQ_WEB` left at `true` on a reachable plane | set `false` in `.env`; run `sidekiq-web-exposure.sh` |
| a self-hoster's `docker compose config` still contains `changeme` / `your-` | run the count check in section 1; generate secrets (`reference/selfhost-defaults.md` section 6) |
| a new `InsecureSkipVerify` / `VERIFY_NONE` | block; ask for a verifying config with an explicit opt-out variable |
| a PR adds `uses: owner/action@vN` | ask for a full SHA pin |
| a PR bumps lago-expression | all 4 places + a commit check (change-control N3); `unpinned-scan.sh` CLONE rows |
| a PR changes `connectors/http.yml` mapping | C4 + C7; check who sets `organization_id` |
| a new `utils.CaptureErrorResultWithExtra(..., "event", event)` | ask for identifiers instead of the event |
<!-- evidence-check: on -->

## Scripts

All read-only on the repo. Run from the repo root with `S=.claude/skills/security-and-supply-chain/scripts`.
Outputs recorded 2026-10-01.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `secret-defaults-scan.sh` | placeholder secrets (KEY + label), published ports, bundled-Redis auth; `--history` / `--history-wide` classify secret-ish KEY additions in git history; never prints values. Exit 0; 1 with `--fail-on-findings` and findings; 2 usage (unknown option or missing option value); 3 no history clone | `$S/secret-defaults-scan.sh`; `$S/secret-defaults-scan.sh --history` | tree mode: `SUMMARY secret-defaults-scan: placeholders=50 (selfhost=35) sensitive_ports=18 (selfhost=12) redis_noauth=4 history_literal=0`. `--history`: same with `history_literal=2`; HIST LITERAL rows `16c8b68 .env.development.example LAGO_LICENSE` and `84b6eef .env.development.default LAGO_LICENSE`; `history_commits_in_scope=30`. `--history-wide`: 5 LITERAL rows, 84 commits in scope |
| `unpinned-scan.sh` | IMAGE/TOOL/ACTION/CLONE/VENDOR/SOCK rows with pin classes. Exit 0; 1 with `--fail-on-latest` and any LATEST; 2 usage (incl. missing option value) | `$S/unpinned-scan.sh --summary` | `SUMMARY unpinned-scan: images_digest=0 images_latest=7 images_major_or_minor=29 actions_sha=0 actions_mutable=44 tools_latest=3 clones=4 jars_no_checksum=8 docker_sock=7`; `--fail-on-latest` exits 1 |
| `sidekiq-web-exposure.sh` | `LAGO_SIDEKIQ_WEB` default per plane, API reachability, lago-api mount and auth middleware. Exit 0; 3 if no lago-api checkout | `$S/sidekiq-web-exposure.sh` | VERDICT `EXPOSED-UNAUTH` for root, local, light, production; `DEV-ONLY` dev; `OFF` all-in-one; `SUMMARY sidekiq-web-exposure: planes_exposed_unauth=4 api_auth_hits=0` |
| `vendored-jar-verify.sh` | network: compares the 8 Kafka Connect jars with Maven Central sha1 / the ClickHouse GitHub release zip; `--manifest` prints sha256 lines offline. Exit 0 all match; 1 mismatch; 4 unreachable | `$S/vendored-jar-verify.sh` | `SUMMARY vendored-jar-verify: jars=8 match=8 mismatch=0 unreachable_or_unknown=0` (a transient proxy error gives exit 4; rerun) |

Foundation scripts used:
`.claude/skills/research-methodology/scripts/history-setup.sh` (history) and
`.claude/skills/research-methodology/scripts/pinned-checkout.sh api` (`$API`).

## Provenance and maintenance

Sources: `docker-compose.yml`, `docker-compose.dev.yml`, `deploy/docker-compose.{local,light,production}.yml`,
`deploy/deploy.sh`, `.env.development.default`, `docker/Dockerfile`, `docker/runner.sh`, `traefik/traefik.yml`,
`extra/`, `connectors/*.yml`, `.github/workflows/*`, `events-processor/{config/redis/redis.go,cache/consumer.go,utils/error_tracker.go,processors/events_processor/*.go,Dockerfile*}`;
`$API/config/{routes.rb,initializers/sidekiq.rb,initializers/analytics_ruby.rb,application.rb}`,
`$API/lib/lago/redis_config_builder.rb`, `$API/app/services/utils/auth_token.rb`,
`$API/db/clickhouse_migrate/20251110*`; commits `16c8b68`, `84b6eef`, `0a67ac0`, `6dd7e56`, `2146a18`, `4955f79`,
`5ee8e98`, `5308258`, `55644b8`, `18b26d0`, `d7355a6`, `9ef876a`.

Volatile facts and one-line re-verification (expected as of 2026-10-01; run from repo root,
`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`,
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`):
- `git rev-parse --short=12 5308258:events-processor` -> `83e012866f29`; `git ls-tree HEAD api` -> `591ae90...` (as-of anchors)
- `grep -n 'SECRET_KEY_BASE' docker-compose.yml deploy/*.yml | cut -d: -f1,2` -> `:24`, light `:30`, local `:27`, production `:30`
- `grep -n 'acme-staging' deploy/*.yml | cut -d: -f1,2` -> light `:87`, production `:87`
- `grep -n 'api.insecure' deploy/*.yml | cut -d: -f1,2` -> light `:80`, production `:80`
- `grep -n 'LAGO_SIDEKIQ_WEB' "$API/config/routes.rb"` -> `4:  if ENV["LAGO_SIDEKIQ_WEB"] == "true"`
- `grep -n 'InsecureSkipVerify' events-processor/config/redis/redis.go` -> `44:`
- `grep -n 'VERIFY_NONE' "$API/lib/lago/redis_config_builder.rb"` -> `:56`, `:76`
- `grep -n 'organization_id = this' connectors/http.yml` -> `25:`
- `git -C "$H" log --format=%h -G'^LAGO_LICENSE=' HEAD -- .env.development.default .env.development.example` -> `6dd7e56 16c8b68`
- `git -C "$H" log --ancestry-path --merges --format='%h %cd' --date=short 84b6eef..HEAD | tail -1` -> `0a67ac0 2025-01-29` (the licence reached `main` here)
- `grep -c '[0-9]\{12\}\.dkr' .github/workflows/build-*-image.yaml` -> 1 per file
- `grep -n 'role-to-assume' .github/workflows/*.yaml | cut -d: -f1 | sort -u` -> only `docker-build-multi-arch.yaml`
- `grep -n 'pnpm@latest' docker/Dockerfile` -> `12:`
- `git ls-remote --tags https://github.com/getlago/lago-expression | grep 'v0.2.0$'` -> `a22ab022ae6f...`
- `grep -n '"event", event' events-processor/processors/events_processor/*.go` -> `event_producer_service.go:72`, `processor.go:71`
- `S=.claude/skills/security-and-supply-chain/scripts; $S/unpinned-scan.sh --summary | tail -1; $S/secret-defaults-scan.sh | tail -1` -> the SUMMARY lines in the Scripts table

Update triggers: an `api` gitlink bump (re-read `$API` routes, Sidekiq, Redis TLS, Segment, DLQ
migrations); any change to compose, `deploy/`, `docker/`, `traefik/`, `extra/`, `connectors/` or
`.github/workflows/`; a new Sentry call or DLQ field; a lago-expression, Go, Rust or base-image bump;
an owner answer to OD-1, OD-9, OD-16..OD-19 (Sidekiq default, HTTP connector exposure, AWS
account id policy, PII in Sentry/DLQ) or OD-20 (memory-cache hardening owner).
