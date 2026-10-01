# Pinning and provenance: full inventory

Read this when you add or bump an image, action, tool or vendored binary, or when you review a
Dockerfile or workflow. Regenerate the raw inventory with `scripts/unpinned-scan.sh` (summary
counts in SKILL.md).
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. Checked 2026-10-01.

Change class: every row is C5 (pins/images/CI) or C6 (compose/dev env) per change-control, plus
the C7 security overlay. Recommendations are CANDIDATE: none was built or deployed here.

## 1. What "pinned" means here

| Class (unpinned-scan) | Example | Moves without a commit? |
|---|---|---|
| DIGEST `@sha256:` | none in the repo (0) | no |
| EXACT tag `X.Y.Z` | `redpanda:v25.2.10`, `getlago/api:v1.53.0` | the tag can be re-pushed by the publisher; usually stable |
| MINOR `X.Y` | `golang:1.25`, `rust:1.85`, `clickhouse-server:26.2-alpine`, `traefik:v3.3` | yes: every patch release |
| MAJOR `X` | `redis:7-alpine`, `postgres:15-alpine`, `debian:13-slim`, `node:24-alpine`, `traefik:v3`, `gotenberg:8` | yes: minors and patches |
| LATEST / NO-TAG | `portainer-ce:latest`, `mailpit:latest` | yes: anything, including breaking majors |
| `-slim` / `-alpine` suffix on an EXACT tag | `ruby:4.0.6-slim` | the Debian base under it changes. `b6b98c8` (#592, "fix: Build of single docker image", no body) drops `software-properties-common` and moves `postgresql-15` -> `postgresql-17`, consistent with a bookworm -> trixie base change (inferred from the diff) |

## 2. Inventory with risk and fix

| Item | Where | Risk | Recommended fix (CANDIDATE) | Class |
|---|---|---|---|---|
| `corepack prepare pnpm@latest` | `docker/Dockerfile:12` (since `55644b8`, 2025-04-08) | Unpinned tool fetched at build time. The v1.35.0 release build failed in this `corepack prepare pnpm@latest` / `pnpm prune` RUN step with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`; the fix's message attributes it to a pnpm update (`18b26d0`, #617, which drops `pnpm prune --prod`); which pnpm ran then is UNVERIFIED. The front pins `"packageManager": "pnpm@10.34.5"` (lago-front `0c5e539` `package.json:11`); corepack runs that version inside the project (probe recorded in the `release-and-images` skill), so `pnpm@latest` is downloaded but inert today. Conditional risk: it becomes live if front drops `packageManager` | `corepack enable` alone (honours `packageManager`), or `corepack prepare pnpm@10.34.5` | C5+C7 |
| `curl https://sh.rustup.rs -sSf \| bash -s -- -y` | `docker/Dockerfile:25` | Unverified installer, and an unpinned Rust toolchain | install a pinned toolchain (`--default-toolchain <ver>`) or copy from a pinned `rust:` image | C5+C7 |
| lago-expression fetched by tag, no commit check | `events-processor/Dockerfile:3-5`, `Dockerfile.dev:3-5`, `Dockerfile.staging:23-27` (ARG default `v0.2.0`), CI `events-processor-tests.yml:40-45` (`ref: v0.2.0`) | A re-pointed tag silently changes the FFI library linked into the binary. `v0.2.0` is a lightweight tag on `a22ab022ae6f2ebd287244e670626cac98f449f1` (as of 2026-10-01; `git ls-remote --tags https://github.com/getlago/lago-expression \| grep v0.2.0`) | After `git checkout`, assert `test "$(git rev-parse HEAD)" = a22ab022ae6f...`; build with `cargo build --release --locked`. All 4 places move together (change-control N3) | C5+C7 |
| Floating Go/Rust/Debian bases | `events-processor/Dockerfile:1,7,17` (`rust:1.85`, `golang:1.25`, `debian:13-slim`) | Production image content changes between builds of the same commit; ECR builds on every main push (`build-processors-image.yaml:2-8`) | Pin by digest (`golang:1.25.0@sha256:...`) with a scheduled bump, or accept and document | C5+C7 |
| Production EP image runs as root | `events-processor/Dockerfile` has no `USER` (`grep -n '^USER'` hits only `Dockerfile.staging:45`, `USER 65532`) | Container compromise = root in the container | Add a non-root `USER` like the staging image | C5+C7 |
| Staging bases `:latest` | `events-processor/Dockerfile.staging:12-13` (`ghcr.io/getlago/events-processor-build:latest`, `-base:latest`) | The "hardened" SOC2 image (`:3`) is built from whatever `latest` points to | Pin by digest; the commit message of `5308258` says the bases come from getlago/lago-packages | C5+C7 |
| `buildx version: latest` | `release-docker-image.yml:42`, `release-processors-image.yml:42` | Builder changes under release builds | pin `version: vX.Y.Z` | C5 |
| Actions by mutable tag | 44 `uses:` refs, 0 SHA-pinned (unpinned-scan); `checkout@v3` x2 and `setup-go@v4` in `events-processor-tests.yml:38,41,59`; `peter-evans/repository-dispatch@v2` (`release.yml:11,18`) | A compromised or re-tagged third-party action runs with the job's secrets (Docker Hub, AWS keys) | Pin third-party actions to a full commit SHA with a `# vX.Y.Z` comment; first-party `actions/*` at least to exact tags; add a dependabot `github-actions` config (owner decision, none committed) | C5+C7 |
| Vendored Kafka Connect jars, no checksums | `extra/kafka-connect/` (8 jars, 17M, added `d7355a6`, #638): Debezium 3.3.1.Final x5, `postgresql-42.7.7`, `protobuf-java-3.25.5`, `clickhouse-kafka-connect-v1.3.4-confluent` | Binary code mounted into the dev Connect worker (`docker-compose.dev.yml:439`) with no recorded provenance | On 2026-10-01 all 8 MATCH upstream (`scripts/vendored-jar-verify.sh`). Commit a `SHA256SUMS` (`vendored-jar-verify.sh --manifest`) or download at build time with checksum verification | C6+C7 |
| docker.sock mounts | Traefik `docker-compose.dev.yml:31`, `deploy/docker-compose.light.yml:92`, `production.yml:92`; Portainer `production.yml:461`; all-in-one PDF sidecar `docker/runner.sh:52-57` + `docker/README.md:28` | Root-equivalent access to the host; `:ro` does not restrict the API | Traefik: use a docker-socket proxy limited to read-only endpoints; Portainer: drop or isolate; all-in-one: run gotenberg as a separate container instead of docker-in-docker | C6+C7 |
| `docker-ce` installed in the all-in-one image | `docker/Dockerfile:45-49` | Large attack surface in a "testing and staging only" image (`docker/README.md:5`) | drop once the PDF sidecar no longer needs the CLI | C5+C7 |
| Broken PGDG apt source | `docker/Dockerfile:43-44` (key written to `postgresql-archive-keyring.gpg`, source says `signed-by=.../postgresql.gpg`, arch typo `ppc64e1`, output `tee /etc/ap`) | The PGDG repository is never configured; Postgres comes from Debian (inferred, no build here). Not exploitable, but the "signed-by" intent is not met | remove the dead lines or fix them | C5 |
| `getlago/lago:latest` quickstart | `deploy/deploy.sh:310` (`docker run ... getlago/lago:latest`); `docker/README.md:21-29` | Quickstart pulls whatever `latest` is; some release tags were never published to Docker Hub (as of 2026-10-01; list: `release-and-images`) | pin the version deploy.sh ships with | C6 |
| deploy.sh downloads compose files without checksums | `deploy/deploy.sh:169,179-180,190-191` (`curl -s -o docker-compose.yml https://deploy.getlago.com/...`) | Whatever is on the Pages site (`gh-page.yml`) is deployed; `curl -s` without `-f` saves error pages too | `curl -fsS` + publish and check a checksum file | C6+C7 |
| certbot TLS params from `master` | `extra/init-letsencrypt.sh:24-26` | unpinned remote config | pin to a certbot tag | C6 |
| Floating dev images | `docker-compose.dev.yml:355` mailpit, `:436` connectors, `:495` pghero (`:latest`); `:21` `traefik:v3`; `:341` `gotenberg:8`; `:62,534,565` `redis:7-alpine` | dev drift; `docker.redpanda.com` mirror still used for 4 dev images (`:369,392,412,436`) while CI moved to `docker.io` after 429s (`986f29b`) | pin exact tags | C6 |
| Go modules | `events-processor/go.sum` (376 lines) | positive control: module downloads are hash-checked | keep `go mod download` + `go.sum`; never `GOFLAGS=-mod=mod` or `GONOSUMDB` | - |
| `go install ...@v1.25` / `@v1.62` (partial versions) | `events-processor/Dockerfile.dev:11-12` | resolves to the latest patch; dev image only | pin full versions | C6 |

## 3. Vulnerability scanning

- No dependency or image scanning runs in CI (only `events-processor-tests.yml` runs on PRs, and
  it runs `go test` only).
- `govulncheck` was tried on 2026-10-01 and could not run in this sandbox: the proxy answers
  `Forbidden` for `https://vuln.go.dev/index/modules.json.gz`. Where the network allows it, run (pinned version,
  Go 1.25 toolchain, CGO env from build-and-env):

```bash
source .claude/skills/build-and-env/scripts/ep-env.sh
(cd events-processor && GOTOOLCHAIN=go1.25.0 go run golang.org/x/vuln/cmd/govulncheck@v1.1.4 ./...)
```

  Without `GOTOOLCHAIN=go1.25.0` the local go1.24 builds govulncheck and every package fails with
  `package requires newer Go version go1.25` (both re-run 2026-10-01). Result: UNVERIFIED.
- CANDIDATE gate (owner decision): govulncheck + an image scanner on PRs that touch
  `events-processor/**` or any Dockerfile.

## 4. Pin-a-third-party-action recipe (C5 + C7)

```bash
git ls-remote https://github.com/peter-evans/repository-dispatch 'refs/tags/v2*'   # SHA per tag; for an annotated tag use its '^{}' line
# then in the workflow:  uses: peter-evans/repository-dispatch@<40-hex-sha>  # v2.x.y
.claude/skills/security-and-supply-chain/scripts/unpinned-scan.sh --summary          # actions_sha should go up by one
```

Moving `docker-build-multi-arch.yaml` also changes lago-front's release (it calls the file `@main`);
see history-and-workflows.md section 4.
