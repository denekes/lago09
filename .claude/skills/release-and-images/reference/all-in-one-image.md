# The all-in-one image `getlago/lago` (`docker/`)

Read this before editing `docker/Dockerfile`, `docker/runner.sh` or `docker/Procfile`, before a
release when api/front changed toolchains, or when `release-docker-image.yml` failed.
Code facts as of 5308258 (events-processor tree 83e012866f29; the working branch may carry
skills-only commits on top), the pinned lago-api 591ae90 (`$API`) and lago-front 0c5e539 (`$FRONT`)
from `pinned-checkout.sh`; registry facts verified 2026-10-01. Building the image needs a Docker daemon and populated
`api/`+`front/`: NOT runnable in an agent sandbox. `docker/README.md:5` says the image is
"designed for testing and staging environments only". Runtime behaviour (what runs, where data
lands, PDF sidecar, insecure defaults) belongs to `run-and-operate` and `security-and-supply-chain`.

## 1. How it is assembled (`docker/Dockerfile`, 66 lines)

| Lines | Stage | What happens |
|---|---|---|
| 1-2 | args | `ARG NODE_VERSION=24`, `ARG RUBY_VERSION=4.0.6` |
| 5-13 | `front_build` on `node:$NODE_VERSION-alpine` | `COPY ./front/ .` (9); `apk add python3 build-base && corepack enable && corepack prepare pnpm@latest --activate && pnpm install && pnpm build` (11-13); no `--frozen-lockfile` |
| 16-34 | `api_build` on `ruby:$RUBY_VERSION-slim` | `ENV BUNDLER_VERSION=4.0.4` (18); apt nodejs/build tools/libpq/libclang/libyaml + rustup (23-25); copies `api/Gemfile` + `Gemfile.lock` (27-28); `gem install bundler -v $BUNDLER_VERSION`, `foreman`, `bundle config set without 'development test'`, `bundle install` (30-34) |
| 37-66 | final on `ruby:$RUBY_VERSION-slim` | apt: PGDG key + a BROKEN PGDG source line (43-44), Docker CE repo (45-47), `nginx xz-utils git libpq-dev postgresql-17 postgresql-17-partman redis-server docker-ce …` (49); `docker/nginx.conf` (52); front `dist` -> `/app/front` (54); gem bundle (55); `front/.env.sh` (57); whole `./api` (58); `docker/Procfile` -> `api/Procfile` (59); `docker/runner.sh` (60); `EXPOSE 80`, `EXPOSE 3000`, `VOLUME /data`, `ENTRYPOINT ["./runner.sh"]` (62-66) |

- Build context is the repo root; `.dockerignore:1-5` excludes only `front/node_modules` and `api/.env`.
- `docker/Procfile:1-3`: `web` (`rails s -b :: -p 3000`), `worker` (`sidekiq -C config/sidekiq/sidekiq.yml`),
  `clock` (`clockwork ./clock.rb`). They mirror `$API/scripts/start.api.sh`, `start.worker.sh`, `start.clock.sh`.
- `docker/runner.sh`: defaults + generated secrets (5-21), `/data/.env` (23-25), data dirs (28-37),
  `service redis-server|postgresql|nginx` (47-49), PDF sidecar through the host Docker socket (51-60),
  `front/.env.sh` (77-79), DB role (84), `rake db:create`, `db:migrate`, `roles:seed_predefined`,
  `rails signup:seed_organization` (88-91), `foreman start` (93). The seed order mirrors
  `$API/scripts/migrate.sh` (`db:migrate`, `roles:seed_predefined`, `signup:seed_organization`),
  but runner.sh has no `set -e`: a failed migration still starts the app.
- Which api/front code gets baked in: the gitlinks at the CHECKED-OUT ref. On a `released` event that
  is the tag; on a `workflow_dispatch` it is the dispatch ref (usually `main`), regardless of the
  `version` input (`release-docker-image.yml:28-30` has no `ref:`).
- PGDG line (`docker/Dockerfile:44`) has three faults: `| tee /etc/ap` (truncated path, the source
  list is never written), `ppc64e1` (typo for `ppc64el`), and `signed-by=/usr/share/keyrings/postgresql.gpg`
  while the key is written to `postgresql-archive-keyring.gpg` (:43). The build works ONLY because
  Debian trixie itself ships `postgresql-17` and `postgresql-17-partman`. Today `ruby:4.0.6-slim` has the
  same digest as `ruby:4.0.6-slim-trixie` (Docker Hub API). The day the Ruby base rolls to a Debian
  without PG17 in main, the build breaks (it already happened once: break 3 below).

## 2. Version sync requirements (what must match what)

| Item | `docker/Dockerfile` | Must match | Pinned value (2026-10-01) | Rule | Checked by |
|---|---|---|---|---|---|
| Ruby | `RUBY_VERSION=4.0.6` (:2) | `$API/.ruby-version`, `$API/Gemfile:6` `ruby "4.0.6"` | 4.0.6 / 4.0.6 | exact. Bundler refuses otherwise: probe on this host printed `Your Ruby version is 3.3.6, but your Gemfile specified 4.0.6`, exit 18 | `single-image-pins.sh` ruby |
| Node | `NODE_VERSION=24` (:1) | `$FRONT/package.json:192` `engines.node` | `24.20.0` | same major (policy). pnpm does not enforce the root `engines` (probe: pnpm 10.34.5 on Node 22 with `engines.node: 24.20.0` -> `pnpm install` exit 0). Node 20 built front requiring `>=22` (v1.35.0, v1.36.0) and `>=24.11.1`..`24.19.0` (v1.37.0 to v1.52.1; `single-image-pins.sh --ref vX` replays), then v1.53.0 needed `b267320` (exact failure UNVERIFIED) | node (FAIL = policy guard, not a proven breaker) |
| Bundler | `ENV BUNDLER_VERSION=4.0.4` (:18) | `$API/Gemfile.lock:1191-1192` `BUNDLED WITH 4.0.16`; `$API/Dockerfile:23-25` uses 4.0.19 | 4.0.4 vs 4.0.16 | same major required; Bundler's auto-switch to the locked version is skipped when `ENV BUNDLER_VERSION` is set (`autoswitching_applies?` in Bundler 4.0.17 `self_manager.rb:105-106`, read on this host), so gems install with 4.0.4 | bundler |
| pnpm | `corepack prepare pnpm@latest --activate` (:12) | `$FRONT/package.json:11` `"packageManager": "pnpm@10.34.5"` | latest = 12.8.1 on npm today | corepack runs the project's `packageManager` version inside `/app`: probe with corepack 0.34.0 -> outside a project `pnpm@latest` (12.8.1) even crashed (`Cannot find module …/pnpm/12.8.1/bin/pnpm.cjs`), inside a dir with `packageManager: pnpm@10.34.5` -> `pnpm --version` = 10.34.5. So `pnpm@latest` is downloaded every build but unused while `packageManager` exists | pnpm |
| lockfile | `pnpm install` (:13) | front's own `Dockerfile:24-25` uses `--frozen-lockfile` | n/a | CANDIDATE: add `--frozen-lockfile` | lockfile |
| Debian | `ruby:$RUBY_VERSION-slim` (:16, :37) | packages at :49 | trixie -> PG 17 | the Debian release behind the Ruby tag must ship `postgresql-17` in main | debian |
| Bundler flags | `bundle config set without` (:33) | Bundler 4 | n/a | never `bundle install --without` on Bundler >= 4 | without |
| Seed order | `runner.sh:88-91` | `$API/scripts/migrate.sh` | roles before org | diff runner.sh against `migrate.sh` each release | seed |

Drift from lago-api's own `Dockerfile` (`$API/Dockerfile`), impact UNVERIFIED: the all-in-one lacks
`pdfcpu` (`$API/Dockerfile:1-8,54`), `libjemalloc2` + `LD_PRELOAD` (:38-40), `postgresql-client` (:38),
the `BUNDLE_GEMS__CONTRIBSYS__COM` secret mount (:29), and `ARG SEGMENT_WRITE_KEY`/`GOCARDLESS_*` (:42-48).

## 3. Release-day breaks 1-7 (the pre-release checklist is built from these)

The commit-by-commit narrative of these breaks is `failure-archaeology` chain X1; the numbering below
is local to this file. Each break was found only when the release event built the image. "Pushed" = `getlago/lago:vX`
`last_updated` on Docker Hub. Shas verified in the history clone.

| # | Release | Symptom / cause | Fix | Guard (pre-release) |
|---|---|---|---|---|
| 1 | v1.21.0, 2025-02-12 (first all-in-one release) | two workflow fixes within 19 min of `52ab3b3`: wrong `needs:` job id, then checkout without submodules (empty api/front) | `023bfe1`, `c91af2b` | `single-image-pins.sh` workflow check |
| 2 | v1.27.1 / v1.28.1, 2025-05-13..16 | Ruby in the image did not match lago-api's Ruby 3.4; Ruby 3.4 needs `libyaml-dev`; packages.redis.io `redis` package; missing `LAGO_ENCRYPTION_*` keys at runtime | `e07e182`, `d0099a9`, `9eb8c3b`, `92b1af2` (`2e7ce41` Ruby 3.4.4 after) | ruby check; when api bumps Ruby minor, expect new apt deps |
| 3 | v1.33.0-v1.33.2 (never published), 2025-08-27..09-08 | `14fa1e0` Ruby 3.4.5 silently moved the base from bookworm to trixie (today's digests: `3.4.4-slim` == `-bookworm`, `3.4.5-slim` == `-trixie`; that the tag already pointed at trixie on 2025-08-27 is inferred); `postgresql-15` not installable | `b6b98c8` -> PG 17, then v1.33.3 | debian check (it compares TODAY's tag digests, also on `--ref` replays) |
| 4 | v1.35.0, 2025-10-29/30 | `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` in `pnpm prune --prod`; with `CI=true` the next error was `tsc: not found` (commit body). Attributed to "the pnpm version update" (pnpm issue 9966). lago-front v1.35.0 already declared `packageManager: pnpm@10.18.3`, so which pnpm ran (latest vs packageManager) is UNVERIFIED | `18b26d0`: removed `rm -rf node_modules` + `pnpm prune --prod`, added `.dockerignore` | pnpm + lockfile warnings |
| 5 | v1.41.1 -> v1.41.2, 2026-02-03 | runtime: organization seeding failed because roles were not seeded first (inferred from subject; no body) | `fd77a74` (`rake roles:seed_predefined`), tagged v1.41.2 | seed check |
| 6 | v1.45.0, 2026-04-07 | Bundler 4 (bumped by `57508c2`, 2026-03-23, latent 15 days) removed `bundle install --without` | `558814a`; v1.45.1 cut the same day | without check |
| 7 | v1.53.0, 2026-09-08 | image still had Node 20 / Ruby 4.0.2 while front needed Node 24 and api pinned Ruby 4.0.6 (`Gemfile:6`) | `b267320`, `f719ef1` (both after the tag) | ruby + node checks |

Workflow-level breaks that hit both release images:
- v1.37.0 (2025-12-09 -> 12-11): invalid runner labels `linux/amd64` and self-hosted `lago-runner`
  replaced by `ubuntu-latest` (`c6abc1e` all-in-one, `5439dd5` events-processor); images pushed two days late.
- 2026-01-02: `5077151` bumped lago-expression to v0.2.0 while `events-processor/Dockerfile` still used
  `rust:1.82`; `e8bbd60` "Fix prod release" moved it to `rust:1.85` (exact compiler error UNVERIFIED).
- 2026-01-08: `d4e3665` added `--tags` to `git clone https://github.com/getlago/lago-expression/` in both
  EP Dockerfiles (probable cause: a cached clone layer that predated the v0.2.0 tag; inferred).

Unexplained: v1.48.0, v1.49.0, v1.50.0 were never published although every pin matched releases that
were (see `release-history.md` §6).

## 4. Pre-release checklist for the all-in-one (run before tagging)

1. `.claude/skills/release-and-images/scripts/single-image-pins.sh` with the bump STAGED -> expect
   `# fails=0`. Today's expected WARNs: node (floating `24`), bundler (4.0.4 vs 4.0.16), pnpm
   (`pnpm@latest` unused), lockfile (not frozen). Any FAIL: sync the ARGs in `docker/Dockerfile` (`:1-2`
   Node/Ruby, `:18` Bundler) in the same bump PR, expect and explain change-control's
   `WARN G1-release-shape` for `docker/Dockerfile`, re-run; any other fix goes in its own PR
   (change-control `reference/change-classes.md` §7).
2. If lago-api changed Ruby minor or lago-front changed Node major since the last release, re-read
   `$API/Dockerfile` apt packages and `$FRONT/Dockerfile` for new system deps (break 2).
3. From the repo root, with the bump staged:
   `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api "$(git ls-files -s api | awk '{print $2}')")`, then
   `diff <(sed -n '/db:create/,/seed_organization/p' docker/runner.sh) <(sed -n '/db:create/,/seed_organization/p' "$API/scripts/migrate.sh")`
   and read the differences (break 5). Expected today: diff exits 1 on wording only (`rake` vs `rails`,
   log redirects, `LAGO_CREATE_ORG` guard in migrate.sh); the order create -> migrate -> roles -> org matches.
4. If you can build (daemon + populated submodules; not here):
   `docker buildx build -f docker/Dockerfile --platform linux/amd64 .` before tagging. CANDIDATE:
   a PR-time `push: false` build through the reusable workflow (target, not current state).
5. After the release: `artifact-verify.sh vX.Y.Z` must show `getlago/lago` OK; if MISS, see SKILL.md
   "Runbook: cut release vX.Y.Z", step 9.

## 5. Known residual risks (as of 2026-10-01)

- No PR-time build of `docker/Dockerfile`: breakage surfaces only on release day (7 breaks).
- `pnpm@latest` (:12) is downloaded on every build. It is inert while front keeps `packageManager`;
  it becomes live if that field is removed, and the extra download is one more thing that can fail.
  CANDIDATE fix: drop `corepack prepare pnpm@latest --activate` (corepack reads `packageManager`) and add
  `--frozen-lockfile`, as front's own Dockerfile does.
- Floating bases: `node:24-alpine`, `ruby:4.0.6-slim` (Debian codename floats), Docker CE repo,
  buildx `version: latest` in the workflow.
- Node beyond 24: CANDIDATE risk, UNVERIFIED here: newer Node majors are reported to stop bundling
  corepack; check `corepack` exists in the new `node:<N>-alpine` before raising `NODE_VERSION`.
- `LAGO_VERSION` and `SEGMENT_WRITE_KEY` never reach the image (see `workflows.md`).
- Every image with a release-day fix was rebuilt from `main` (8 cases), so "image == tag tree" does not hold.
