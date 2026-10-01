# Dev stack, CI, release image and self-host: symptom tables

Read when SKILL.md section 7 pointed you here. "No daemon" = not runnable in a daemon-less sandbox;
verified by reading the cited file instead. Owners: bring-up and variants `run-and-operate`, variable
meaning `config-and-flags`, environment recipe `build-and-env`, release train `release-and-images`,
gates `change-control`. Dates/shas from the full-history clone
(`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`).

## D. Dev stack (`docker-compose.dev.yml`, project `lago_dev`)

Daemon-less checks that DO work here: `docker compose -f docker-compose.dev.yml config -q` (valid),
`... config --services` (25 services; 30 with `--profile '*'`), `... config --format json | jq ...`.

| # | Symptom (exact text when known) | Likely causes, ranked | Confirm | Fix / owner |
|---|---|---|---|---|
| D1 | `lago: command not found` / `unknown command "exec" for "lago"` | `lago` is an alias defined in `docs/dev_environment.md:53` that agent shells never load; lago-cli binary has no `exec` | `type lago` | `docker compose -f docker-compose.dev.yml <cmd>`; `build-and-env` |
| D2 | `failed to connect to the docker API at unix:///var/run/docker.sock; ...` | no Docker daemon (sandbox) | `docker info` | Docker-free recipe (`ep-test.sh`); compose `config` only |
| D3 | front container fails to start (exact text UNVERIFIED, no daemon; expected `external volume "lago_front_pnpm_store" not found`) | volume declared `external: true` (`docker-compose.dev.yml:11-12`, mounted at `:103`, added `195bbc0` 2026-09-02, undocumented) | `docker volume ls \| grep lago_front_pnpm_store` (no daemon) | `docker volume create lago_front_pnpm_store` |
| D4 | Traefik `ERR EntryPoint doesn't exist entryPointName=ws routerName=webhook@docker` | router label names an entrypoint not in `traefik/traefik.yml:13-17` (only `web`, `websecure`) | `grep -n 'entrypoints=' docker-compose.dev.yml` | use `web`/`websecure` (fixed `12b8101` #618) |
| D5 | `RedisClient::CannotConnectError: Connection refused - connect(2) for 127.0.0.1:6379` in `migrate`; `unable to create topics [...]: unable to dial: dial tcp 172.18.0.2:9092: connect: connection refused` | a dependency edge without `condition: service_healthy` (the `c80a7b5` #580 incident) | `docker compose -f docker-compose.dev.yml config --format json \| jq '.services.migrate.depends_on'` (works daemon-less) | add healthcheck + `service_healthy` (change-control N12) |
| D6 | re-running topic creation fails (`TOPIC_ALREADY_EXISTS`, exact text UNVERIFIED) | plain `rpk topic create` is not idempotent | `docker-compose.dev.yml:397-407` uses `scripts/create-topics.sh` | add topics to that list; never bypass it (`5477e39` #581) |
| D7 | root `docker compose config` -> `go-yaml load error in parser (while parsing a block mapping) at L21.C3-L67.C3: did not find expected key` | uncommented `# - SIDEKIQ_EVENTS=true` hint (list item inside the `x-backend-environment` mapping, `docker-compose.yml:67-73`) | `docker compose -f docker-compose.yml config -q` | write `"SIDEKIQ_EVENTS": "true"` (VERIFIED on a scratch copy) |
| D8 | jobs enqueued but never run after `SIDEKIQ_EVENTS=true` (no error) | the flag routes `Events::PostProcessJob` etc. to queue `events` (`$API/app/jobs/events/post_process_job.rb:5-11`), which `$API/config/sidekiq/sidekiq.yml` does not serve | `docker compose -f docker-compose.dev.yml ps --status running --services \| grep worker` (no daemon; the documented start `docs/dev_environment.md:127,135` runs only `api-worker` and `api-clock`) | start `api-events-worker` (`docs/dev_environment.md:174-190`) or set the flag false; `.env.development.default:45` warns about this |
| D9 | ClickHouse still used with `LAGO_CLICKHOUSE_ENABLED=false` | lago-api checks `.present?` (`$API/app/services/events/stores/store_factory.rb:10`, `$API/clock.rb:210`); `docs/dev_environment.md:154` is wrong | `config-and-flags` bool-semantics script | unset it or set it empty |
| D10 | `.env.development` value with `${VAR}` behaves unexpectedly | env files ARE interpolated (`docs/dev_environment.md:158` says otherwise) | `docker compose -f docker-compose.dev.yml config events-processor` shows resolved values | `config-and-flags` |
| D11 | API email delivery raises (dev has `raise_delivery_errors = true`, `$API/config/environments/development.rb:68`) | 1 Mailpit not started (profile `mailpit`, `docker-compose.dev.yml:354-366`); 2 CANDIDATE: lago-api dev SMTP host is `"mailhog"` (`$API/config/environments/development.rb:70-73`, same on lago-api main `b5500bc` 2026-10-01) but the service was renamed to `mailpit` in `8f8334e` (#777) with no network alias | `docker compose -f docker-compose.dev.yml --profile mailpit config --format json \| jq '.services.mailpit.networks'` -> `{"default": null}` | `docker compose -f docker-compose.dev.yml up -d --wait mailpit` (no daemon); if delivery still fails with a name-resolution error, it is cause 2: route to `run-and-operate` (change-class C6: add an alias) / lago-api. Runtime UNVERIFIED (no daemon) |
| D12 | events-processor in dev consumes nothing / wrong topic | raw topic is `events-raw` in dev (`.env.development.default:78`); `events-processor/README.md:41` still says `events_raw` | `docker compose -f docker-compose.dev.yml config events-processor \| grep RAW` | trust the env file (`0ca6cdf` / `16c8b68` unified it) |
| D13 | `lago_test` database missing | init scripts run only on an EMPTY PGDATA; the path typo lived 774 days (`2747b04` -> `e5392e9` #621) | `docker compose logs db` on a fresh volume (no daemon) | recreate the volume, or create the DB by hand |
| D14 | `error: cannot run ssh: No such file or directory` / `Permission denied (publickey).` on submodule update | `.gitmodules` uses SSH URLs | `git config -f .gitmodules --get-regexp url` | HTTPS `insteadOf` rewrite, or read-only `pinned-checkout.sh api` (`build-and-env`) |

## CI. CI

| # | Symptom | Likely causes, ranked | Confirm | Fix / owner |
|---|---|---|---|---|
| CI1 | a PR that edits only `.github/workflows/events-processor-tests.yml` shows no test run | PR `paths` filter is `events-processor/**` (`events-processor-tests.yml:7-13`); the workflow has no `workflow_dispatch` | read the `on:` block | the first real run happens on push to `main` (`:4-6`); run `actionlint` locally first (`release-and-images` ships a runner); change-class C5 gates in change-control |
| CI2 | actionlint: `the runner of "actions/checkout@v3" action is too old to run on GitHub Actions` (`:38`, `:41`), same for `actions/setup-go@v4` (`:59`) | old action majors, nothing SHA-pinned | actionlint v1.7.7 (VERIFIED 2026-10-01) | bump in a change-class C5 PR; whether GitHub fails the job today is UNVERIFIED from here |
| CI3 | EP tests green locally, red in CI (or the reverse) | lago-expression ref differs between the 4 pin places (change-control N3); network-dependent `cargo build`; Postgres service not ready (no health options in the service block) | change-control pin-sync check; CI log step "Build lago-expression" | align pins; re-run |
| CI4 | `Docker CI` red on `main` | `docker compose up -d --wait` of the ROOT compose with published images (`docker-ci.yml:16-25`), then `curl -f http://localhost:3000/health`; image tags in `docker-compose.yml:11,13` not yet published, or a lago-api boot failure | job log; `docker compose -f docker-compose.yml config --images` | `run-and-operate`, `release-and-images` |
| CI5 | image on `main` built from a commit whose tests failed | image builds (`build-processors-image.yaml`, paths `events-processor/**`) are not gated on tests | workflow `needs:` (none) | known gap; `release-and-images` |

## REL. Release: the all-in-one image (`docker/Dockerfile`) breaks on release day

Nothing builds `docker/Dockerfile` before a GitHub Release (`release-docker-image.yml:1-9` triggers on
`release: released` and `workflow_dispatch` only), so every drift surfaces on release day.

| # | Symptom (text from the fixing commit when it has one) | Cause | Fix commit | Still possible? |
|---|---|---|---|---|
| REL1 | `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY  Aborted removal of modules directory due to no TTY`; with `CI=true`: `sh: tsc: not found` | `corepack prepare pnpm@latest` pulled a new pnpm when Lago v1.35.0 was released (2025-10-29) | `18b26d0` (#617) | yes: `docker/Dockerfile:12` still says `pnpm@latest` (front pins `pnpm@10.34.5`) |
| REL2 | `bundle install ... --without development test` fails (exact text UNVERIFIED) | Bundler 4 (`57508c2`, 2026-03-23) removed `--without`; latent 15 days until v1.45.0 | `558814a` (#722), v1.45.1 cut | no (fixed form in place) |
| REL3 | Ruby / Node mismatch (Bundler: `Your Ruby version is X, but your Gemfile specified Y`, standard text, UNVERIFIED here) | `docker/Dockerfile:1-2` ARGs lag `$API/.ruby-version` (4.0.6) / front `engines.node` (24.20.0) after the v1.53.0 bump (`ba292b6`) | `b267320` (node, +33 min), `f719ef1` (ruby, +49 min) | yes, on every bump: compare `sed -n 1,2p docker/Dockerfile` with `cat "$API/.ruby-version"` |
| REL4 | apt cannot install `postgresql-15` / `software-properties-common` (inference; commit has no body) | `ruby:*-slim` base rolled to Debian trixie | `b6b98c8` (#592) | yes, on the next distro roll (base not pinned to a codename) |
| REL5 | signup seeding fails in the single image | `rake roles:seed_predefined` must run before `signup:seed_organization` (`docker/runner.sh`) | `fd77a74` (#687) | when lago-api changes its seed order |
| REL6 | release tag exists, `getlago/lago:<tag>` missing on Docker Hub (v1.48.0, v1.49.0, v1.50.0 return 404; v1.48.1 exists; as of 2026-10-01) | release-day build failures not re-run (cause UNVERIFIED: no run logs here) | `curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.49.0` -> 404 | `release-and-images` |

## S. Self-host (`docker-compose.yml`, `deploy/`)

| # | Symptom | Cause | Confirm | Owner |
|---|---|---|---|---|
| S1 | `unknown flag: --profile` | `deploy/README.md` puts `--profile` after `up`; it is a global flag | `docker compose -f deploy/docker-compose.local.yml up --profile all --dry-run` (VERIFIED) | `docker compose -f deploy/docker-compose.local.yml --profile all up -d`; `run-and-operate` |
| S2 | `failed to read .../.env: line 2: unexpected character "\x1b" in variable name "\x1b[32m✅ LAGO_DOMAIN is already set.\x1b(B\x1b[m"` | `deploy/deploy.sh:288-299` writes its coloured status line into `.env` on re-runs | `cat -A .env` | delete those lines; `run-and-operate` |
| S3 | Postgres refuses to start on an existing volume (`database files are incompatible with server`, standard text, UNVERIFIED here) | root compose moved `postgres:14-alpine` -> `getlago/postgres-partman:15.0-alpine` on the same volume (`97d1f0b`, 2026-01-27); no upgrade doc | `docker compose logs db` | dump/restore; `run-and-operate` |
| S4 | production `pdf-worker` restarts forever (runtime UNVERIFIED, no daemon; `restart: unless-stopped`) | `deploy/docker-compose.production.yml:346` runs `./scripts/start.pdf.worker.sh`, which does not exist in lago-api: only `start.pdfs.worker.sh`, both in v1.27.1 (the image that file pins, `:15`) and at the pinned `591ae90` | `ls "$API/scripts" \| grep pdf` | `run-and-operate` |
