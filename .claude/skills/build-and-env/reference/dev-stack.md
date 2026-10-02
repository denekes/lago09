# Full dev stack from zero (docker-compose.dev.yml), alias-free

Read when you must bring up the real multi-service dev environment on a workstation with a Docker
daemon (to run lago-api specs, the front, or the events-processor container), or when you need the
alias-free form of a command from `docs/dev_environment.md`. This file recreates the ENVIRONMENT;
operating the running services (what lands where, logs, topics) is the `run-and-operate` skill.
Variable meanings are the `config-and-flags` skill.

Legend: **[here]** = run in the daemon-less agent sandbox on 2026-10-01 with the output shown;
**[daemon]** = not runnable in a daemon-less sandbox, verified by reading the cited file:line.
Changing compose/dev config is change class C6 (change-control); one env source of truth and the
`depends_on` conditions (infra `service_healthy`, one-shot jobs `service_completed_successfully`,
app -> api `service_started`) are change-control N12. This file covers PREREQUISITES; bring-up order,
checks and teardown are `run-and-operate` R1 (its `dev-preflight.sh` checks sections 0-5).

## 0. Prerequisites

| Need | How | Status |
|---|---|---|
| Docker Engine + Compose v2 | `docker compose version` (here: Docker 29.6.2, Compose v5.3.1) | [here] CLI only, no daemon |
| git with access to GitHub | SSH key, or the HTTPS rewrite in step 1 | [here] |
| mkcert (+ NSS tools for browsers) | macOS: `brew install mkcert nss` (`docs/dev_environment.md:82`); Ubuntu 24.04: `sudo apt install mkcert libnss3-tools` (apt candidate `mkcert 1.4.4-1ubuntu3.2`) | [here] cert generation verified in scratch, see step 3 |
| openssl | `docs/dev_environment.md:21-30` | not needed by compose itself |
| Host ports 80, 443, 5432 free (RAM needs are not documented) | traefik binds 80/443 (`docker-compose.dev.yml:24-26`), db binds 5432 (`:53-54`) | [daemon] |

Port 5432 trap: the dev `db` service publishes 5432, the same port a host Postgres for Docker-free tests
uses. Run only one, or move one of them.

## 1. Clone with submodules

Docs form (needs an SSH key: `.gitmodules:3,6` use `git@github.com:`):
```bash
git clone --recurse-submodules git@github.com:getlago/lago.git && cd lago      # docs/dev_environment.md:39
```
HTTPS form without an SSH key **[here, 10 s, pins 591ae90 / 0c5e539]**:
```bash
git -c url."https://github.com/".insteadOf="git@github.com:" \
  clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/getlago/lago.git && cd lago
git submodule status        # expect two lines without a leading '-'
```
Already cloned with empty `api/` and `front/`? Either one-shot:
```bash
git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --depth 1
```
or persistent for this clone only (writes `.git/config`, no tracked diff):
```bash
git submodule init && git config submodule.api.url https://github.com/getlago/lago-api.git \
  && git config submodule.front.url https://github.com/getlago/lago-front.git && git submodule update --depth 1
```
Both verified on a scratch clone (`reference/traps.md` B9). Neither moves a gitlink, but
`docs/dev_environment.md:266-278` ("Updating a reference" … `git add api` … `git push origin main`) does:
never follow that outside a release bump PR (change-control N1); bumps land through a PR (e.g. `ba292b6` "Bump version to v1.53.0 (#792)"), not `git push origin main`.
`--depth 1` gives a shallow clone; for history use `research-methodology`'s `history-setup.sh`.

## 2. The `lago` command, without the alias

The docs ask you to append `export LAGO_PATH=…` and `alias lago="docker compose -f $LAGO_PATH/docker-compose.dev.yml"`
to your rc file (`docs/dev_environment.md:47-71`). That alias exists only in interactive shells; agent
and CI shells never see it, and a getlago/lago-cli `lago` binary shadows it in scripts. Use either:
```bash
export LAGO_PATH="$(git rev-parse --show-toplevel)"
docker compose -f "$LAGO_PATH/docker-compose.dev.yml" <args>          # literal expansion of the alias
.claude/skills/build-and-env/scripts/dc.sh <args>                      # same, cwd-independent
```
The compose project name is fixed (`name: lago_dev`, `docker-compose.dev.yml:1`) and relative paths
resolve against the file's directory, so the cwd does not matter. **[here]**:
```
$ .claude/skills/build-and-env/scripts/dc.sh config --services | wc -l
25
$ .claude/skills/build-and-env/scripts/dc.sh --profile '*' config --services | wc -l
30
```

## 3. TLS certificates for Traefik

```bash
mkcert -install                                   # trusts a local CA in system + browser stores (once per machine)
mkdir -p traefik/certs && (cd traefik/certs && mkcert -cert-file lago.dev.pem -key-file lago.dev-key.pem lago.dev "*.lago.dev")
```
Names must match `traefik/dynamic.yml:3-4`; `traefik/certs/*` is git-ignored (`.gitignore:11`).
**[here]** the generation step (without `-install`, `CAROOT` in a scratch dir) produced a cert with
`X509v3 Subject Alternative Name: DNS:lago.dev, DNS:*.lago.dev`. `mkcert -install` was not run here
(it changes the trust store).

## 4. Hosts entries

The doc's list (`docs/dev_environment.md:97-106`) is stale: it has `license.lago.dev` (no such service)
and lacks `console.lago.dev` and `pghero.lago.dev`. Generate the list from the compose file instead
**[here]**:
```bash
grep -ohE 'Host\(`[^`]+`\)' docker-compose.dev.yml | sed -E 's/Host\(`([^`]+)`\)/127.0.0.1 \1/' | sort -u
```
```
127.0.0.1 api.lago.dev
127.0.0.1 app.lago.dev
127.0.0.1 console.lago.dev
127.0.0.1 mail.lago.dev
127.0.0.1 pdf.lago.dev
127.0.0.1 pghero.lago.dev
127.0.0.1 traefik.lago.dev
127.0.0.1 webhook.lago.dev
```
Append that to `/etc/hosts` (needs root; review before writing).

## 5. API files and the external volume

```bash
cp ./api/.env.dist ./api/.env && touch ./api/config/master.key      # docs/dev_environment.md:110-114
docker volume create lago_front_pnpm_store                          # NOT in the docs
```
- `$API/.env.dist` is one line: `DATABASE_URL=postgresql://lago:changeme@localhost:5432/lago_test`.
- `lago_front_pnpm_store` is `external: true` (`docker-compose.dev.yml:11-12`, mounted by `front` at
  `:103`, added by `195bbc0`), so Compose will not create it and `front` will not start without it
  **[daemon]** (exact error text UNVERIFIED). `dc.sh config --volumes` lists it **[here]**.
- Overrides go in `.env.development` (git-ignored, `.gitignore:4`), never in `.env.development.default`
  (`docs/dev_environment.md:152-156`). Two doc claims there are wrong: `.env` files ARE interpolated
  (contrary to `:158`)
  (`dc.sh config events-processor` shows `DATABASE_URL: postgresql://lago:changeme@db:5432/lago` from
  `.env.development.default:24`, which is `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}`),
  and `LAGO_CLICKHOUSE_ENABLED=false` (`:154`) is MIXED: most lago-api sites (`.present?`) stay ON,
  while org creation (`Boolean.cast`) turns the ClickHouse store OFF for new orgs (details:
  `config-and-flags`; stale-claim register: `docs-and-writing`).

## 6. Docs commands, alias-free **[daemon]**

Start order, `--wait` targets, the event pipeline and teardown: `run-and-operate` R1. This table only
translates each `lago …` line of the docs (section 2).

| Docs (`docs/dev_environment.md`) | Alias-free |
|---|---|
| `lago up -d --wait db redis traefik clickhouse webhook` (`:121`) | `dc.sh up -d --wait db redis traefik clickhouse webhook` |
| `lago up -d --wait front api api-worker api-clock` (`:135`) | `dc.sh up -d --wait front api api-worker api-clock` |
| `lago exec api bundle exec rails console` (`:145`) | `dc.sh exec api bundle exec rails console` |
| `lago up -d api-events-worker` (`:183`) | `dc.sh up -d api-events-worker` |
| `lago config --services \| grep worker` (`:189`) | `dc.sh config --services \| grep worker` **[here]** |
| `lago --profile redis-sentinel up -d` (`:206`) | `dc.sh --profile redis-sentinel up -d` (`--profile` is a global flag, not an `up` flag) |
| `lago exec -e LAGO_DISABLE_SCHEMA_DUMP=true -e RAILS_ENV=test api bundle exec rails db:create db:migrate` (`:214`) | `dc.sh exec -T -e LAGO_DISABLE_SCHEMA_DUMP=true -e RAILS_ENV=test api bundle exec rails db:create db:migrate` |
| `lago exec api bundle exec rspec <file>` (`:231`; `$API/AGENTS.md:8`) | `dc.sh exec -T api bundle exec rspec <file>` |
| `lago up -d --wait mailpit` (`:295`) | `dc.sh up -d --wait mailpit` (profile `mailpit`, `docker-compose.dev.yml:359-360`) |
| `lago up -d events-processor` (`events-processor/README.md:23`) | `dc.sh up -d --wait events-processor` (waits for db, redis, redpanda: `docker-compose.dev.yml:326-332`) |
| `lago exec events-processor go test ./...` (`events-processor/CLAUDE.md:7`) | `dc.sh exec -T events-processor go test ./...`; daemon-less: `.claude/skills/build-and-env/scripts/ep-test.sh` |

`-T` disables TTY allocation (`docker compose exec --help`: "-T, --no-tty"); use it from agent and CI
shells. Inside the events-processor container the `.so` is at `/usr/lib/libexpression_go.so`
(`events-processor/Dockerfile.dev:14`) and `DATABASE_URL=postgresql://lago:changeme@db:5432/lago`, so
plain `go test` works there. The container runs `air` with a 10 s kill delay (`events-processor/.air.toml:5`).

Profiles (`dc.sh --profile '*' config --profiles` **[here]**): `mailpit`, `redis-sentinel`. Default
services: 25; with all profiles: 30 (adds mailpit, redis-replica, redis-sentinel-1..3).

## 7. Environment checks after bring-up **[daemon]**

Service-level verification and runtime outputs: `run-and-operate` R1. Environment-level facts only:
- `dc.sh ps` shows `healthy` only for services that define a healthcheck (db, redis, redpanda,
  clickhouse, api, pghero); traefik, webhook, front, api-worker, api-clock and events-processor stay
  plain `Up` (`dc.sh config --format json` **[here]**).
- `https://app.lago.dev` loads without a browser warning only after `mkcert -install` (section 3).
- `dc.sh exec -T events-processor go test ./...` → the same 6 `ok` packages as `ep-test.sh`.
