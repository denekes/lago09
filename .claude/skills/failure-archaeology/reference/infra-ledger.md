# Infra ledger: release, CI, deploy, dev env, repository hygiene

Read this when a release, image build, compose file, deploy script or workflow is involved and you
want the full record of what already went wrong there. Narrated chains are in `chains.md`
(X1–X13); this file is one row per commit (or per tightly coupled group of commits).

Scope: every non-dependabot commit outside `events-processor/` and `events_processor/` that is a
fix, revert, hotfix or removal, as found by
`.claude/skills/failure-archaeology/scripts/incidents.sh --infra --list` (119 lines as of 2026-10-01,
release bumps excluded), plus the feature commits that started a chain. Docs-only link and typo fixes
are grouped in one row at the end. Facts verified 2026-10-01 against the history clone, the working
tree at `5308258`, and the Docker Hub tag API. "Inferred" = read from code or subject, no commit body.

Kinds: FIX, HOTFIX, REVERT, REGRESSION, REMOVAL, FEAT, RELEASE-DEFECT (a release that shipped wrong
content without a fixing commit). Status words: see SKILL.md Terms.

## 1. Release train and the all-in-one image (`docker/`, `release-docker-image.yml`)

| Date | Sha | PR | Kind | Symptom | Root cause | Fix | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2025-02-12 | `52ab3b3` | #464 | FEAT | – | n/a | single image `docker/Dockerfile` + release workflow; unused `scripts/bootstrap.sh` ×2 | superseded by fixes below | X1 |
| 2025-02-12 | `023bfe1` | #466 | FIX | first release workflow failed (6 min after `52ab3b3`) | `needs:` named a non-existent job | correct job id | settled | X1 |
| 2025-02-12 | `c91af2b` | #467 | FIX | build had no api/front sources | `actions/checkout` without `submodules: true` | `submodules: true` | settled | X1 |
| 2025-03-14 | `f145388` | #486 | FIX | submodule pins ≠ release tag | pins drifted | re-align pins | settled; class residual | X6 |
| 2025-05-13 | `e07e182` | #527 | FIX | single image broken after Ruby 3.4 | Ruby ARG behind lago-api | 3.3.6 → 3.4.3 | settled | X1 |
| 2025-05-13 | `d0099a9` | #528 | FIX | Ruby 3.4 gem build failed | `libyaml-dev` missing | add package | settled | X1 |
| 2025-05-15 | `9eb8c3b` | #532 | FIX | redis install failed | `packages.redis.io` `redis` package | Debian `redis-server`, `service … start` | settled; `docker/redis.conf` dead since (residual) | X1 |
| 2025-05-16 | `92b1af2` | #534 | FIX | app failed without encryption keys | `LAGO_ENCRYPTION_*` not generated | generate in `docker/runner.sh` | settled | X1 |
| 2025-09-15 | `b6b98c8` | #592 | FIX | single-image build failed | inferred: base moved to Debian trixie (no `postgresql-15`, no `software-properties-common`) | `postgresql-17` | settled; PGDG line still broken (`docker/Dockerfile:43-44`) | X1 |
| 2025-10-30 | `18b26d0` | #617 | FIX | v1.35.0 build: `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` | `corepack prepare pnpm@latest` | drop `pnpm prune --prod`; `.dockerignore` | settled; `pnpm@latest` remains (`docker/Dockerfile:12`) | X1 |
| 2025-12-11 | `c6abc1e` | #659 | FIX | v1.37.0 image 2 days after the bump `9faa659` | runner labels `linux/amd64` / `lago-runner` (inferred: no longer served) | `ubuntu-latest` | settled | X1 X7 |
| 2025-12-11 | `5439dd5` | #660 | FIX | same for `release-processors-image.yml` | same | same | settled | X7 |
| 2026-02-03 | `fd77a74` | #687 | FIX | image seeding failed (inferred from title) | lago-api needs `roles:seed_predefined` first | `docker/runner.sh:90-91` | settled; `runner.sh` duplicates lago-api start logic (residual) | X1 |
| 2026-03-23 | `57508c2` | #714 | REGRESSION | – (latent 15 days) | Ruby 4.0.2 + Bundler 4.0.4; Bundler 4 dropped `--without` | – | fixed by `558814a` | X1 |
| 2026-04-07 | `558814a` | #722 | FIX | v1.45.0 build broke (20 min after bump `074fc9a`) | `bundle install --without` removed | `bundle config set without` | settled | X1 |
| 2026-06-10..07-07 | – | – | RELEASE-DEFECT | `getlago/lago` has no `v1.48.0`, `v1.49.0`, `v1.50.0` (Docker Hub 404, 2026-10-01) | UNVERIFIED | none | open | X1 |
| 2026-08-27 | `01cfbc6` | #784 | RELEASE-DEFECT | v1.52.1 bump changed only compose tags | gitlinks left at lago-api/front v1.52.0 | none | `getlago/lago:v1.52.1` built from v1.52.0 api/front (inferred) | X1 X6 |
| 2026-09-08 | `b267320` | #793 | FIX | v1.53.0 image (33 min after bump `ba292b6`) | Node 20 too old for front (inferred) | Node 24 | settled | X1 |
| 2026-09-08 | `f719ef1` | #794 | FIX | v1.53.0 image (+16 min) | Ruby 4.0.2 vs lago-api 4.0.6 (inferred) | Ruby 4.0.6 | settled; image pushed after it (15:26Z) | X1 |

## 2. CI workflows and image pipelines

| Date | Sha | PR | Kind | Symptom | Root cause | Fix | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2022-03-21..05-10 | `4aaa93b` … `42d40cd` | – | FIX ×19, REMOVAL | 42 commits on preview workflows in 50 days (`f097644`, `bbd8895`, `dcd09b1`, `28e0fa7`, `bfcf916`, `562e349`, `95b47a0`, `253c2e5`, `fea9a8a`, `f9a8243`, `da05968`, `8331b0c`, `c6e1748`, `5592575`, `97c9997`, `7747640`, `a15b7e8`, `0d4d18f`, …) | workflows could only be tested by pushing to `main` | `42d40cd` "remove deployments from public repo" | removed | X2 |
| 2025-08-01 | `9d40e82` | #559 | FEAT | – | n/a | `release-processors-image.yml` | settled | X7 |
| 2025-08-20 | `6ff3a2f` → `ca4a4fb` | #572 → #573 | REMOVAL | duplicate EP release workflow | added `release-processor-image.yaml` (singular) | removed 3 min later | removed | X7 |
| 2025-11-13 | `b61044f` | #631 | FEAT | – | n/a | reusable `docker-build-multi-arch.yaml` (with `push` input) | superseded | X7 |
| 2025-12-03 | `fd427a2` | – | FIX | multi-stage `target` broke default builds | `58ea88f` (previous day) defaulted `target` to `'default'` | default `''` | settled | X7 |
| 2026-01-23 | `fdfeb91` | – | REGRESSION | – | refactor removed the `push` input | – | re-added `5070e24` | X7 |
| 2026-02-10 | `6a595fb` | #683 | FIX | connectors base image floated | `FROM …/connect` unpinned | pin `4.78.0` | settled | X8 |
| 2026-08-24 | `76159bd` → `2146a18` | – | REMOVAL | connectors image had no CI ("a person's local `docker push`") | n/a | dispatch to lago-deploy, replaced 13 min later by a direct reusable-workflow call | settled | X8 |
| 2026-08-25 | `4955f79` | – | FIX | ECR EP image "carried only an amd64 manifest" | plain build-push step | reusable workflow, amd64+arm64 | settled | X7 |
| 2026-08-25 | `5070e24` | – | FEAT | no build-only mode for PRs | `push` input removed in `fdfeb91` | re-added (default true) | residual: no in-repo caller uses `push: false` | X7 |
| 2026-08-25 | `5ee8e98` | – | FEAT | – | n/a | OIDC `role-to-assume` | residual: no caller | X7 |
| 2026-08-26 | `986f29b` | – | FIX | two connectors builds failed `429 Too Many Requests` | anonymous Docker Hub pulls via the redpanda mirror | pull `docker.io/redpandadata/connect` | residual: ECR mode never logs in to Docker Hub | X8 |

## 3. Deploy and self-host (`deploy/`, root `docker-compose.yml`)

| Date | Sha | PR | Kind | Symptom | Root cause | Fix | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2023-02-24 | `ed6f687` | #200 | FIX | custom `REDIS_PORT` ignored | redis ran on 6379 | `--port ${REDIS_PORT}` | partial: healthcheck left on default port | X9 |
| 2025-03-22 | `8a6ce39` | #491 | FEAT | – | n/a | `deploy/deploy.sh` + traefik compose; bare emoji line executed as a command | fixed `2453945` | X3 |
| 2025-05-09 | `b1e40bd` | #524 | FIX | Redis healthcheck failed with a custom port | `redis-cli ping` without `-p` | `-p ${REDIS_PORT}` in `docker-compose.yml:111` | residual: `deploy/*.yml` not ported | X9 |
| 2025-05-20 | `cd9f0fa` | #529 | REGRESSION | Light/Production: `check_domain_dns: command not found` | function called (line 212) before defined (line 277) | – | fixed `2453945`; same commit pinned `deploy/*.yml` to `v1.27.1` and references `./scripts/start.pdf.worker.sh` (absent from lago-api at the pin; residual) | X3 |
| 2025-07-22 | `d54c463` | #537 | FIX | local profile env download | `.env.local.example` not served | removed the download | settled | X3 |
| 2026-09-03 | `2453945` | #762 | FIX | (as `cd9f0fa`) | (as above) | function moved; `$pid` quoted; `echo` added | settled after 471 days; other bugs residual (`deploy/deploy.sh:58,106,169-191,314-326`) | X3 |

## 4. Dev environment (`docker-compose.dev.yml`, `.env.development.default`, `scripts/`)

| Date | Sha | PR | Kind | Symptom | Root cause | Fix | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2022-05-10 | `d07887a` | #19 | FIX | CORS issue in production | `LAGO_FRONT_URL` missing | add it; the root-compose line read `LAGO_FRONT_URL"${…}` (quote instead of `=`), fixed 2 days later by `9ca67f7` | settled | X13 |
| 2022-05-16 | `2546628` | – | FIX | RSA config missing in compose | n/a | add RSA key env | settled | X13 |
| 2022-06-02 | `3a5c339` | #38 | FIX | compose used `:latest` images | unpinned tags | pin versions | settled | – |
| 2022-06-07 | `b218f54` | – | FIX | image tag not found | tag case (`V0.1.2-alpha`) | correct case | settled | – |
| 2022-06-23 | `1a9bea1` | – | HOTFIX | encryption salt not interpolated | `={VAR:-x}` missing `$` (6 lines) | add `$` | settled | X13 |
| 2022-07-06 | `48f6529` | – | FIX | local PDF URL wrong | default pointed at `https://pdf.lago.dev` | `http://pdf:3000` | settled | X13 |
| 2022-07-12 | `1e54772` | – | FIX | variable issues | S3/RSA env wiring | rework env | settled | X13 |
| 2022-08-04 | `d2cadc7` | – | FIX | Segment disabled by default | default `true` | no default | settled | X13 |
| 2022-08-08 | `f6581fb` | #85 | FIX | empty-var warnings | `${VAR}` without default | `${VAR:-}` | settled | X13 |
| 2022-08-11 | `5925130` | #89 | FIX | api container lacked `LAGO_API_URL` | missing env | add default | settled | X13 |
| 2022-09-22 | `bfb4d5f` | – | FIX | `LAGO_DISABLE_SIGNUP` empty | no default | `:-false` | settled | X13 |
| 2022-09-27 | `c44b5f5` | – | REMOVAL | S3 env on api-worker unused | n/a | removed | settled | – |
| 2022-09-28 | `82447cd` | – | FIX | local storage lost on restart | no volume | `lago_storage_data` volume | settled | – |
| 2022-11-15..28 | `7449f47`, `3162d86`, `8eb4046` | #130, #139, #140 | FIX | self-signed / letsencrypt nginx setup broken | config `proxy_pass`, wrong `data_path` | fixed configs and script | settled | – |
| 2022-11-30 | `635a057`, `cd67b4e` | #142, #144 | FIX | OAuth proxy URL unset | env left to the user | hard-coded `https://proxy.getlago.com`; GoCardless env removed | settled | – |
| 2023-04-11 | `a791efb` | #219 | FIX | local dev mail sender missing | `LAGO_FROM_EMAIL` absent | add default | settled | X13 |
| 2023-04-20 | `81a0df4` | #224 | REMOVAL | `docker-compose.arm64.yml` (38 commits since `22a1685`, 2022-09-13) | duplicated file | deleted | removed | X10 |
| 2023-09-22 | `2747b04` | #283 | REGRESSION | `lago_test` DB never created | init-script volume path `./pg-init-scripts` (real `./scripts/pg-init-scripts`) | – | fixed `e5392e9` (25.4 months later) | X4 |
| 2024-01-11 | `55540ce` | #311 | FIX | typo in `LAGO_ENCRYPTION_*` placeholder defaults | spelling | corrected placeholder strings (changes effective keys for default-config users, inferred) | settled | X13 |
| 2024-01-31 | `d961560` | #317 | FIX | api healthcheck logic wrong | `curl -f http://localhost:3000` | `/health`, interval, start period | settled | – |
| 2024-02-07 | `688e4e7` | – | FIX | Kafka env missing in dev | n/a | raw topic env per service (`events-raw`) | superseded `16c8b68` | X5 |
| 2024-06-18 | `17a8f95` | #364 | FIX | duplicate `container_name` | pdfs worker reused the events worker name | unique name | settled | – |
| 2024-08-26 | `4515af3` | #395 | REMOVAL | compose `version:` warning | obsolete key | removed | settled | – |
| 2024-09-06 | `bf02b8d`, `b9dfc8b` | #398, #400 | FIX | `NANGO_SECRET_KEY` warning; Google SSO env missing | defaults | add defaults/env | settled | X13 |
| 2024-09-24/25 | `15961be` → `84013d6` | – (merge #412) | REVERT | front codegen split into two endpoints | front/api not ready | reverted next day | settled | X12 |
| 2024-11-04 | `0ca6cdf` | #424 | REGRESSION | titled "Fix dev events_raw topic" | set only `api-worker` to `events_raw`; others and topic creation used `events-raw` (`git show 0ca6cdf:docker-compose.dev.yml`); the commit also moved the `api` pin | – | superseded `16c8b68` | X5 X6 |
| 2024-11-04 | `f8f66ac` | – | FIX | events worker image `api_deb` | typo | `api_dev` | settled | – |
| 2024-11-08 / 2025-01-16 | `a46d806`, `73fffbb` | –, #449 | FIX | migrate container: script not found | lago-api renamed `start.migrate*.sh` → `migrate*.sh` | compose updated | settled; same class: `start.pdf.worker.sh` (deploy) | X4 |
| 2025-01-23 | `16c8b68`, `84b6eef` | – | FIX | env duplicated per service | n/a | one env file `.env.development.default` (`events-raw`) — also carried a real `LAGO_LICENSE` value | settled; licence see §5 | X5 |
| 2025-01-23 | `dfb7b73` | #454 | FIX | codegen path | external URL | `http://api:3000/graphql` | settled | X12 |
| 2025-03-13 | `aecb8be` | #482 | FIX | dev EP service build path `./events_processors` (plural) | typo in `4100da0` | `./events_processor` | settled | – |
| 2025-09-03 | `c80a7b5` | #580 | FIX | random `lago up -d` failures (Redis/ClickHouse refused, topic creation refused) | no health conditions | `condition: service_healthy` | settled; residual bare lists (`front`, `redpanda-console`) | X4 |
| 2025-09-04 | `5477e39` | #581 | FIX | re-running topic creation failed | `rpk topic create` not idempotent | `scripts/create-topics.sh` | settled | X4 |
| 2025-10-14 | `39f77fc` | #604 | REMOVAL | compose required `$LAGO_PATH` | absolute paths | relative paths | settled (the `lago` alias still needs it, see `build-and-env`) | – |
| 2025-10-23 | `3cd78f1` | #611 | FIX | dev charge-usage cache never expired | EP Redis cache DB 0 vs API DB 3 (since `3a6ed00`) | `LAGO_REDIS_CACHE_DB=3` | settled (EP expiry later removed) | F X5 |
| 2025-11-04 | `12b8101` | #618 | FIX | Traefik `EntryPoint doesn't exist entryPointName=ws` | labels used an undefined `ws` entrypoint (`traefik/traefik.yml:13-17` defines `web`, `websecure`) | removed `ws`; ALSO moved api/front pins | settled; pins reverted `647de3e` | X6 |
| 2025-11-04 | `e5392e9` | #621 | FIX | `lago_test` never created (see `2747b04`) | path typo | path fixed; bootstraps deleted | settled | X4 |
| 2025-12-15 | `f6852c0` | #663 | FIX | `events_enriched_expanded` topic missing in dev | env mandatory since `3dae52f` (112 days) but topic not created | add topic | removed with the topic in `d9c32b6` | M |
| 2026-02-12 | `4cba248` | #696 | FIX | pg_cron setup doc wrong | `cron.database_name = 'lago'` | `'postgres'` | settled | – |
| 2026-03-19 | `330b048` | #718 | FIX | security logs topic missing in dev | not created | add env + topic | settled | – |
| 2026-07-10..09-01 | `0e5937e`, `f0bb135` → `4230f1f` | #760 → #786 | REMOVAL | Meilisearch dev service and worker | no body; lago-api at the pin has no Meilisearch code | removed after 53 days | removed | X10 |

## 5. Repository hygiene and security incidents

| Date | Sha | PR | Kind | Symptom | Root cause | Fix | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| 2022-07-26 | `efb1a61` | – | REMOVAL | `.DS_Store` committed | local file | removed | settled | – |
| 2023-10-05 → 10-23 | `c8f4133` → `1035ffa` | #285 → #288 | REMOVAL | 269 files incl. 133 `:Zone.Identifier` + connector jars in a "sidekiq worker" PR | `git add` of a download dir | removed after 18 days | blobs remain in history | X11 |
| 2025-01-23 → 03-07 | `16c8b68` → `6dd7e56` | → #477 | REMOVAL | real `LAGO_LICENSE` value in the public defaults file (43 days) | personal env copied into the versioned file | blanked | rotation OPEN DECISION OD-9 (owner); never print the value (change-control N11) | X5 X11 |
| 2025-01-28 → 02-13 | `16eb537` → `a41c6dc` | – | REMOVAL | `LAGO_LICENSE_URL` added, then "useless" | n/a | removed after 16 days | removed | – |
| 2025-11-04 | `12b8101` → `647de3e` | #618 → #620 | REVERT | a Traefik PR moved api/front pins | `git commit -a` with drifted submodules (inferred) | pins reverted 3 h later | instance settled; 15 non-release pin moves since 2025 (residual) | X6 |
| 2026-06-19 | `d13e62a` | – | REMOVAL | `FUNDING.yml` (added `4d0a612`, 2024-01-31) | n/a | removed | removed | – |
| 2026-09-18 | `5308258` | (#800) | – | PR #800 lost: "force-pushed onto main before being closed … unrecoverable" | force-push of an open PR branch | rebuilt from lago-deploy#3331 | recovered (change-control N2) | X11 |

An AWS account id was added to two public workflows in `2146a18` and `4955f79`, while `5308258`'s
message says the private copy existed to keep it out of a public repo. Counts and policy belong to
`security-and-supply-chain`; this skill only records the contradiction.

## 6. Docs-only fixes (grouped)

Broken links and typos, no runtime effect: `5328de2` (#141), `dc637a3` (#207), `220b842` (#273),
`2922bc9`, `9946c06` (#587), `bd35c98` (#595), `b95fba8` (#627), `aebe7f4`, `b90031a`, `37833b2`,
`7e11021` (#682), `c8b8c93` (#736), `20d778f` (#743), `7ec5d8a` (#522), `dc64319` (issue template).
`d93c9aa` and `eb1ce49` (2022-03) are front-pin moves titled as fixes. The stale-claim register lives
in `docs-and-writing`.
