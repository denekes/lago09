# Image builds: which Dockerfile is for what, and how to build one locally

Read when you need to build an image yourself (to test a Dockerfile or pin change before a PR), or
when you need to know which Dockerfile a workflow or compose service uses. Publishing, tags,
registries and the release train are the `release-and-images` skill; this file stops at "the image
builds on my machine".

Nothing here is runnable in a daemon-less sandbox: `docker build --check -f events-processor/Dockerfile
events-processor` fails with `failed to connect to the docker API at unix:///var/run/docker.sock …`
(2026-10-01). Every build command below is a CANDIDATE derived from the cited workflow lines; the
facts about the files are VERIFIED by reading them (code facts as of `5308258`, events-processor tree
`83e012866f29`; the working branch may carry skills-only commits on top). CI never builds an image on a PR
(only `events-processor-tests.yml` runs on PRs), so a local build is the only pre-merge check.
Changing a Dockerfile is change class C5 (change-control).

## The Dockerfiles

| File | Purpose | Stages / base images | Built by | Build context |
|---|---|---|---|---|
| `events-processor/Dockerfile` | production events-processor image | `rust:1.85` (lago-expression `v0.2.0`, `:1-5`) -> `golang:1.25` (`go build -o event_processors`, `:7-15`) -> `debian:13-slim`, runs as root (no `USER`), `ENTRYPOINT ["./event_processors"]` (`:17-24`) | `release-processors-image.yml:52-53` (Docker Hub), `release-images.yml:40-41` (GHCR), `build-processors-image.yaml:19-20` (ECR on push to main) | `events-processor/` |
| `events-processor/Dockerfile.dev` | dev container with hot reload | same Rust stage; `golang:1.25` + `dlv@v1.25` + `air@v1.62` (`:11-12`), `.so` in `/usr/lib` (`:14`), `CMD ["air", "-c", ".air.toml"]` (`:21`); source is bind-mounted, not copied | `docker-compose.dev.yml:323-325` (service `events-processor`, image `events-processor_dev`, `pull_policy: never`) | `events-processor/` |
| `events-processor/Dockerfile.staging` | hardened staging image (Wolfi/apko bases from getlago/lago-packages) | `ghcr.io/getlago/events-processor-build:latest` -> `ghcr.io/getlago/events-processor-base:latest` (`:12-13`), `ARG LAGO_EXPRESSION_REF=v0.2.0` (`:23`), `USER 65532` (`:45`) | private `lago-deploy` workflow (`:8-10`); not built by this repo | `events-processor/` |
| `docker/Dockerfile` | all-in-one `getlago/lago` image (front + api + Postgres 17 + Redis + nginx in one container; "testing and staging only", `docker/README.md:5`) | `node:24-alpine` front build (`:1,5-13`) -> `ruby:4.0.6-slim` api bundle (`:2,16-34`) -> `ruby:4.0.6-slim` runtime (`:37-66`) | `release-docker-image.yml:56-57`, with `submodules: true` (`:28-30`) | repo root (needs populated `api/` and `front/`) |
| `connectors/Dockerfile` | Redpanda Connect with the `http`/`kinesis`/`sqs` pipelines | `docker.io/redpandadata/connect:4.83.0` (`:6`), `COPY *.yml ./` (`:8`) | `build-connectors-image.yaml:24-25` (ECR) | `connectors/` |
| `api/Dockerfile(.dev)`, `front/Dockerfile(.dev)` | lago-api / lago-front images (submodules, read-only here) | see `reference/toolchain-matrix.md` §5 | their own repos' workflows; dev compose builds the `.dev` ones (`docker-compose.dev.yml:93-95,145-147`) | `api/`, `front/` |

## Local build commands (CANDIDATE; need a Docker daemon)

```bash
cd "$(git rev-parse --show-toplevel)"
docker build -t lago-events-processor:local events-processor                     # = release-processors-image.yml:52-53
docker build -f events-processor/Dockerfile.staging -t lago-ep-staging:local events-processor
.claude/skills/build-and-env/scripts/dc.sh build events-processor                # Dockerfile.dev via compose
docker build -f docker/Dockerfile -t lago-all-in-one:local .                      # needs api/ and front/ populated
docker build -t lago-connectors:local connectors
```
Smoke a freshly built events-processor image the way `reference/traps.md` B2 smokes the binary:
with no env it must log `brokers not found` and panic (link and loader are fine). Deeper binary and
image smoke tests are the `diagnostics-and-tooling` skill.

## Traps when building images

| Trap | Evidence | What to do |
|---|---|---|
| No `.dockerignore` in `events-processor/` or `connectors/`; `COPY . /app/` copies whatever is there (stray `event_processors` binary, `.env`, `tmp/`) | `events-processor/Dockerfile:11`; root `.dockerignore` excludes only `front/node_modules` and `api/.env` and applies only to root-context builds | Build from a clean tree (`git status --porcelain events-processor` empty, no untracked files) |
| Cached `git clone` layer predates a new lago-expression tag, so `git checkout vX` fails | `d4e3665` added `--tags` to the clone (`events-processor/Dockerfile:3`) | After a ref bump, build with `--no-cache` once, or prefer `git clone --depth 1 --branch <tag>` (CANDIDATE, a C5 change) |
| Rust image too old for the lago-expression ref | `5077151` -> `e8bbd60` (`rust:1.82` -> `rust:1.85`) | Bump the ref and the Rust image together (change-control N3) |
| `@latest` tools break builds | `d589940` (air needed Go 1.25); `18b26d0` (v1.35.0 failed in the `pnpm@latest` / `pnpm prune` step; which pnpm ran is UNVERIFIED, `toolchain-matrix.md` §5); `docker/Dockerfile:12` still uses `pnpm@latest` | Pin; never add `@latest` (change-control N3) |
| `docker/Dockerfile` with empty submodules | `COPY ./front/ .` (`:9`), `COPY ./api/Gemfile` (`:27`) | Populate `api/` and `front/` first (`reference/dev-stack.md` §1); failure text UNVERIFIED (no daemon) |
| `docker/Dockerfile` PGDG apt line is broken (`tee /etc/ap`, `ppc64e1`, wrong keyring name) | `docker/Dockerfile:43-44` | Builds today only because the `ruby:4.0.6-slim` base is Debian trixie (same Docker Hub digest as `ruby:4.0.6-slim-trixie`, as of 2026-10-01), whose own archive ships `postgresql-17`; the image build itself is UNVERIFIED here (no daemon); owned by `release-and-images` |
| Docker Hub anonymous pull rate limit (429) | `986f29b` (two `build-connectors-image.yaml` runs failed with 429 on 2026-08-25/26; fix: pull `docker.io/redpandadata/connect` instead of the redpanda mirror); comment at `connectors/Dockerfile:1-5` | Log in to Docker Hub before large local builds; keep `docker.io/` bases in CI |
| Floating bases: `golang:1.25`, `debian:13-slim`, `node:24-alpine`, `*:latest` staging bases | see `reference/toolchain-matrix.md` | Expect patch drift between two builds of the same commit |
