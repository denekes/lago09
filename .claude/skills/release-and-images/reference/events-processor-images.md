# events-processor and connectors images

Read this before editing any `events-processor/Dockerfile*` or `connectors/Dockerfile`, or when an
events-processor image is missing or differs between registries. Code facts as of 5308258
(events-processor tree 83e012866f29; the working branch may carry skills-only commits on top);
registry facts verified 2026-10-01. No Dockerfile can be built or `docker build --check`-ed without a daemon: everything
below is read from files, history and registry APIs. Local (Docker-free) builds and tests of the Go
binary belong to `build-and-env`; the pin rules (change-control N3) belong to `change-control`.

## 1. Four Dockerfiles

| File | Bases | Key lines | Used by |
|---|---|---|---|
| `events-processor/Dockerfile` (prod) | `rust:1.85` -> `golang:1.25` -> `debian:13-slim` | `git clone --tags https://github.com/getlago/lago-expression/` (:3); `git checkout v0.2.0 && cargo build --release` in `expression-go/` (:4-5); `COPY . /app/` (:11); `go mod download` (:13); `.so` -> `/usr/lib` (:14); `go build -o event_processors .` (:15); runtime `apt-get upgrade` + `ca-certificates` (:19); `.so` + binary (:22-23); `ENTRYPOINT ["./event_processors"]` (:24); no `USER` (runs as root) | `release-processors-image.yml` (Docker Hub), `release-images.yml` (GHCR), `build-processors-image.yaml` (ECR) |
| `events-processor/Dockerfile.dev` | `rust:1.85` -> `golang:1.25` | same Rust stage (:1-5); `dlv@v1.25`, `air@v1.62` pinned (:11-12, after `d589940` where `@latest` air required a newer Go); `EXPOSE 2345` (:19); `CMD ["air", "-c", ".air.toml"]` (:21) | `docker-compose.dev.yml:318-325` (`dockerfile: Dockerfile.dev`) |
| `events-processor/Dockerfile.staging` (added in `5308258`, 2026-09-18) | `ARG BUILD_IMAGE=ghcr.io/getlago/events-processor-build:latest`, `ARG RUNTIME_IMAGE=ghcr.io/getlago/events-processor-base:latest` (:12-13); Wolfi/apko bases from getlago/lago-packages (:3-6) | `# syntax=docker/dockerfile:1.26` (:1); "Staging-only hardened image … built for SOC2 compliance" (:3-4); `ARG LAGO_EXPRESSION_REF=v0.2.0` "bump both together" (:20-23); clone + checkout + `cargo build --release` (:24-27); `go build` (:32-34); `COPY --chown=nonroot:nonroot` (:42-43); `USER 65532` (:45) | the paired workflow lives in private **lago-deploy** (`build-events-processor-staging-image.yml`, :8-10): UNVERIFIED from here. "The sibling ./Dockerfile stays untouched and continues to serve production builds" (:9-10) |
| `connectors/Dockerfile` | `docker.io/redpandadata/connect:4.83.0` (:6) | comment: pull from docker.io, not the redpanda mirror, to avoid anonymous 429s (:1-5, `986f29b`); `COPY *.yml ./` (:8) | `build-connectors-image.yaml` (ECR only) |

- `events-processor/` and `connectors/` have NO `.dockerignore`, so `COPY . /app/` takes every file
  in the directory, including a local untracked `.env` on a developer machine (CI checkouts have none).
- The staging bases are multi-arch (amd64 + arm64 manifest list) and also published with immutable
  `<git-sha>`, `<git-sha>-x86_64`, `<git-sha>-aarch64` tags besides `latest` (GHCR `tags/list`,
  anonymous). The toolchain versions inside them are UNVERIFIED: GHCR blob downloads
  (`pkg-containers.githubusercontent.com`) are blocked from an agent sandbox. CANDIDATE: pin
  `BUILD_IMAGE`/`RUNTIME_IMAGE` to the immutable sha tags.
- `Dockerfile.staging` is change class C5 (+C7: it is the SOC2 hardening path); do not "align" it
  with the prod Dockerfile without the owner (its comment says prod stays untouched).

## 2. The pin set every events-processor image depends on (verify with change-control's pin-sync-check)

| Pin | Value | Locations (verified `grep -n`) |
|---|---|---|
| lago-expression (Rust `.so`) | `v0.2.0` | `events-processor/Dockerfile:5`, `Dockerfile.dev:5`, `Dockerfile.staging:23`, `.github/workflows/events-processor-tests.yml:45` |
| Rust image | `1.85` | `events-processor/Dockerfile:1`, `Dockerfile.dev:1` (CI uses the runner's Rust; staging uses the base image's) |
| Go | `1.25` / `1.25.0` | `Dockerfile:7`, `Dockerfile.dev:7` (`golang:1.25`), `events-processor-tests.yml:61` (`1.25.0`), `events-processor/go.mod:3` (`go 1.25.0`), `events-processor/mise.toml:2`. `golang:1.25` == `golang:1.25.14` by digest (as of 2026-10-01; Docker Hub `library/golang` tags API): release images build with 1.25.14 while CI tests 1.25.0. `go 1.25.0` in go.mod came from dependabot `932c06c` (#724, 2026-04-09 09:29 +0200); CI and both Dockerfiles followed in `50015b0` (#725, 10:19) |
| expression-go (Go wrapper) | `v0.1.4` | `events-processor/go.mod:10`: do NOT bump to "match" v0.2.0 (change-control N3) |

The Rust image tag is part of the lago-expression pin set: `5077151` bumped the ref in 3 files and broke
the prod release until `e8bbd60` moved `rust:1.82` -> `rust:1.85` the same day.

## 3. One source, three builds

| Registry / image | Workflow | When | Arch | Tags |
|---|---|---|---|---|
| Docker Hub `getlago/lago-events-processor` | `release-processors-image.yml` | GitHub Release `released` (or dispatch) | amd64 + arm64 | `vX.Y.Z`, `latest` |
| GHCR `ghcr.io/getlago/events-processor` | `release-images.yml` job `events-processor` | `v*` tag push | amd64 only | `vX.Y.Z`, `X.Y`, `sha-<umbrella 7>` |
| ECR `…/lago-events-processor` (private) | `build-processors-image.yaml` | push to `main` touching `events-processor/**` | amd64 + arm64 | `main`, `sha-<7>` |

- The three run at different times on floating bases (`golang:1.25`, `debian:13-slim`, `rust:1.85`), so
  same-version images are not byte-identical. None is gated on `events-processor-tests.yml`.
- A release bump does not touch `events-processor/**`, so it does not rebuild ECR; ECR `main` reflects
  the last events-processor change on main, which can be newer than the last release.
- ECR tag scheme changed when `4955f79` (2026-08-25) moved the build onto the reusable workflow
  (`sha-<7>` and `main`; consumers in lago-deploy: UNVERIFIED).
- Docker Hub `lago-events-processor` covers every release v1.32.0..v1.53.0 except `v1.41.2` (404).
- The ECR account id is hard-coded in `build-processors-image.yaml:15` and
  `build-connectors-image.yaml:19` (do not copy the digits; see `security-and-supply-chain`).

## 4. Connectors image

- ECR `…/lago-connectors`, amd64 + arm64, built on push to `main` touching `connectors/**` or by
  dispatch with a `ref` input (`build-connectors-image.yaml:2-13`). Before `2146a18`/`76159bd`
  (2026-08-24) every push "came from a person's local `docker push`" (commit body).
- `986f29b` moved the base to `docker.io/...` after two 429s on 2026-08-25/26. In ECR mode the
  reusable workflow logs in to ECR only (`docker-build-multi-arch.yaml:196-214`), so Docker Hub pulls
  are still anonymous: whether the change helps is UNVERIFIED.
- `getlago/connectors:latest` on Docker Hub (single tag, 2025-09-18) is not produced by any workflow
  in this repo.
- What the connector configs do at runtime: `run-and-operate` / `config-and-flags`.
