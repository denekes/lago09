# Workflow inventory (10 files in `.github/workflows/`)

Read this when you change a workflow, debug a failed image build, or need the exact trigger, tags
or secrets of one pipeline. Facts verified 2026-10-01 against HEAD 5308258 by reading each file
(`cat -n .github/workflows/<file>`) and by parsing every `on:` block with `yaml.safe_load`.
Secrets are listed by NAME only (change-control N11).

"Live" means a registry shows artifacts from it recently (artifact-verify.sh) or a run is implied by
history. Actions run logs are NOT visible from an agent sandbox (no GitHub API access to getlago/*),
so per-run status is UNVERIFIED everywhere.

## Summary table

| File | Trigger | Builds / does | Registry, image | Tags pushed | Arch | Secrets (names) | Status |
|---|---|---|---|---|---|---|---|
| `release-docker-image.yml` | `release: [released]` (:3-4); `workflow_dispatch` input `version` (:5-9) | all-in-one image from repo root, `docker/Dockerfile` (:56-57), `submodules: true` (:28-30) | Docker Hub `getlago/lago` (:11) | `<tag_name or version input>` + `latest` (:36-38, :96-98) | amd64 `ubuntu-latest` + arm64 `linux-arm64` (:14-20) | `DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD`, `SEGMENT_WRITE_KEY` | live (v1.53.0 pushed 2026-09-08) |
| `release-processors-image.yml` | same as above (:2-9) | `events-processor/Dockerfile`, context `./events-processor` (:52-53) | Docker Hub `getlago/lago-events-processor` (:11) | `<version>` + `latest` (:36-38, :90-92) | amd64 + arm64 (:14-20) | `DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD` | live |
| `release-images.yml` | `push: tags: ['v*']` (:3-6) | 3 jobs via the reusable workflow: lago-api at `github.ref` (:9-19), lago-front at `github.ref` (:21-31), events-processor from this repo (:33-42) | GHCR `ghcr.io/getlago/{api,front,events-processor}` | `vX.Y.Z`, `X.Y`, `sha-<7>` (reusable :230-236) | **amd64 only** (:16, :27, :39) | `GH_TOKEN` (as `repository-token`, :19, :31); `secrets: inherit` (:42) | live (v1.44.0..v1.53.0 on GHCR) |
| `release.yml` | `release: [released]` (:2-4) | `repository_dispatch` event `release` to lago-api (:10-16) and lago-front (:17-23) via `peter-evans/repository-dispatch@v2` | none | none | n/a | `GH_TOKEN` (:13, :20) | **DEAD**: no workflow in lago-api@591ae90 or lago-front@0c5e539 has a `repository_dispatch` trigger |
| `build-processors-image.yaml` | push to `main` touching `events-processor/**` (:2-7); `workflow_dispatch` (:8) | reusable workflow, `events-processor/Dockerfile` (:19-20) | ECR `201661579678.dkr.ecr.us-east-1.amazonaws.com/lago-events-processor` (:15) | `main`, `sha-<7>` | amd64 + arm64 (:18) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (:22-23) | UNVERIFIED (ECR is private) |
| `build-connectors-image.yaml` | push to `main` touching `connectors/**` (:2-7); `workflow_dispatch` input `ref` (:8-13) | reusable workflow, `connectors/Dockerfile` (:24-25) | ECR `…/lago-connectors` (:19) | `main` (or the dispatched branch), `sha-<7>` | amd64 + arm64 (:23) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (:27-28) | UNVERIFIED (ECR is private) |
| `docker-build-multi-arch.yaml` | `workflow_call` (:4-5) | reusable multi-arch build (below) | Docker Hub / GHCR / ECR by input `registry` (:30-34) | see "Tag recipe" | per input `platforms` (default `amd64,arm64`, :24-28) | inputs `registry-user`, `registry-token`, `repository-token`, `build-secrets` (:96-111); `GITHUB_TOKEN` (:222, :363) | live; **also called by lago-front @main** |
| `events-processor-tests.yml` | push to `main` (all paths) (:4-6); `pull_request` opened/synchronize/reopened on `events-processor/**` (:7-13) | `go test -v ./...` with Postgres 14 service, lago-expression v0.2.0 built in CI | none | none | amd64 | none | live (only PR gate in the repo) |
| `docker-ci.yml` | push to `main`; `workflow_dispatch` (:2-6) | sparse-checks out `docker-compose.yml` (:12-15), `docker compose up -d --wait` (:23-25), curls `:3000/health`, `:80`, `/api/v1/customers` with bearer `test` (:26-32) | none (pulls published `getlago/api:vX`, `getlago/front:vX`) | none | amd64 | none | live (UNVERIFIED runs) |
| `gh-page.yml` | push to `main` touching **only** `deploy/deploy.sh` (:3-8); `workflow_dispatch` (:9) | uploads the whole `deploy/` dir (:15-23) and deploys GitHub Pages (:25-39) | GitHub Pages | n/a | n/a | `GITHUB_TOKEN` (:39) | live; serving host UNVERIFIED (`deploy.sh` downloads from `https://deploy.getlago.com/…`, `deploy/deploy.sh:169,179-180,190-191`; no `CNAME` in `deploy/`; host not reachable from here) |

Only `events-processor-tests.yml` has a `pull_request` trigger. Nothing builds an image on a PR.
Only `docker-build-multi-arch.yaml` (:126-129) and the `gh-page.yml` deploy job (:27-29) declare `permissions`.

## Reusable workflow `docker-build-multi-arch.yaml` (read before editing: lago-front releases through it)

- Inputs (:6-94): `image-name` (required), `context` (`.`), `dockerfile` (`./Dockerfile`), `platforms`
  (`amd64,arm64`), `registry` (`dockerhub`|`ghcr`|`ecr`), `build-args`, `tags`, `target`,
  `exact-tags-only` (false), `cache-type` (`registry`; `disabled` turns cache off), `aws-region`,
  `ref`, `repository`, `push` (true), `role-to-assume` (OIDC for ECR).
- Outputs (:113-124): `image-tag`, `digest`, `tag`.
- Job `prepare` (:132-168): maps `amd64 -> ubuntu-latest`, `arm64 -> linux-arm64` (:148-154); any other
  value exits 1 (:155-158). `linux-arm64` is a non-standard runner label (org larger runner or
  self-hosted: UNVERIFIED). Forks without that runner cannot run arm64 legs (UNVERIFIED).
- Job `build` (:170-315), one leg per arch, native (no QEMU): checkout `repository`/`ref` with
  `repository-token` (:186-191); login per registry (:196-222); `docker/metadata-action@v5` with
  `context: 'git'` (:224-236), so `sha-<7>` is the commit of the CHECKED-OUT repo (GHCR
  `ghcr.io/getlago/api` carries `sha-591ae90` = lago-api v1.53.0, verified); build and push by digest
  (:288-301); registry cache `<image>:buildcache-<arch>`, `mode=max` (:299-300); digest artifact (:303-315).
- Job `merge` (:317-426) runs only `if: inputs.push` (:320): `docker buildx imagetools create` makes
  the manifest list (:383-384), inspects it (:386-391), writes a step summary (:393-426).
- Tag recipe (:230-236): `type=semver,pattern=v{{version}}`, `type=semver,pattern={{major}}.{{minor}}`,
  `type=ref,event=pr` (`pr-N`), `type=ref,event=branch` (`main`), `type=sha` (`sha-<7>`), plus `tags`.
  With `build-args` or `build-secrets`, the combined tag becomes `<version>.build-<8 hex>` where the
  hex is a sha256 over the sorted args AND secret values (:253-277).
- `exact-tags-only: true` pushes only `vX.Y.Z` and fails when the ref is not semver (:241-248, :376-377).
  Its description says "e.g., 1.2.3" (:55) but the pattern yields `v1.2.3` (:231).
- Small defects: header comment names a non-existent `docker-build-multiarch.yml` (:1);
  `echo '${{ steps.meta.outputs.json }}'` breaks on a `'` in label JSON (:243); job outputs come from a
  matrix (:178-183), safe only while every leg computes identical metadata.
- Callers (verified): this repo `build-processors-image.yaml:13`, `build-connectors-image.yaml:17`,
  `release-images.yml:10,22,34`; **lago-front@0c5e539 `.github/workflows/release.yml:13`
  `uses: getlago/lago/.github/workflows/docker-build-multi-arch.yaml@main`** with `image-name: getlago/front`,
  `ref: <release tag>`, `cache-type: disabled`, `exact-tags-only: true`, Docker Hub secrets
  `DOCKERHUB_USERNAME`/`DOCKERHUB_PASSWORD` (:11-22). Commit bodies name more external callers:
  lago-self-billing (`5070e24`) and a lago-deploy pattern (`76159bd`); not verifiable from here.
- Consequence: a merge to this file on `main` changes how `getlago/front` is released on lago-front's
  next release, with no version pin. Treat any edit as change class C5 with cross-repo blast radius.
- Permissions: top-level `contents: read`, `id-token: write`, `packages: write` (:126-129). Callers
  declare none. Whether caller/org defaults allow this is UNVERIFIED (repo settings are invisible).
- OIDC (`role-to-assume`, added `5ee8e98`) is plumbed but unused: both ECR callers pass static keys.

History of the reusable workflow (`git -C "$H" log --format='%h %ad %s' --date=short -- .github/workflows/docker-build-multi-arch.yaml`,
author dates): created `b61044f` (2025-11-13); `exact-tags-only` `8cff5c1` (2026-03-18); `cache-type: disabled`
`5fa4ed8` (authored 2026-02-19, on `main` 2026-03-11; same commit added `release-images.yml`); `push` input `5070e24` (2026-08-25);
OIDC `5ee8e98` (2026-08-25). `b61044f`'s body says main-branch images are tagged `{short-sha}`; that
is stale: metadata-action's `type=sha` adds the `sha-` prefix.

## Per-workflow notes

### `release-docker-image.yml` ("Release Single Docker Image")
- Writes `LAGO_VERSION` at the repo root (:48-51), but `docker/Dockerfile` copies only `./api`
  (`docker/Dockerfile:58`). lago-api reads `Rails.root.join("LAGO_VERSION")`
  (`$API/lib/lago_utils/lago_utils/version.rb:5`) and falls back to `default: Rails.env`
  (`$API/config/initializers/version.rb:3`, `version.rb:27-33`). lago-api has no committed
  `LAGO_VERSION`. Inferred: the all-in-one reports version `production`.
- Passes `SEGMENT_WRITE_KEY` as a build-arg (:61-62); `docker/Dockerfile` declares no such `ARG`
  (only `NODE_VERSION`, `RUBY_VERSION`, :1-2), so it is dropped; lago-api then uses `"changeme"`
  (`$API/config/initializers/analytics_ruby.rb:20`).
- `docker/build-push-action@v6`, buildx `version: latest` (:41-42). Not migrated to the reusable workflow.
- `workflow_dispatch` checks out WITHOUT `ref` (:28-30): the image is built from the ref you dispatch
  on (usually `main`), whatever `version` says. `version` only names the tag (and `LAGO_VERSION`).
- Tags `latest` unconditionally, on every run, including a dispatch for an old version.

### `release-processors-image.yml`
- Copy-paste twin of the above for `getlago/lago-events-processor`. Checks out `submodules: true`
  (:28-30) although its context is `./events-processor` (:52); harmless but slower.

### `release-images.yml` (GHCR, added `5fa4ed8`: authored 2026-02-19, committed to `main` 2026-03-11)
- `api`/`front` jobs check out `getlago/lago-api` / `getlago/lago-front` at `${{ github.ref }}`
  (= `refs/tags/vX.Y.Z` of THIS repo) (:15-17, :28-29). So the same tag name must exist upstream,
  or that job fails. GHCR `api`/`front` images therefore come from the UPSTREAM tag, not from this
  repo's gitlinks (v1.52.1: GHCR `api` has `sha-7895cd2` = lago-api v1.52.1, while the umbrella
  gitlink stayed at v1.52.0).
- No `exact-tags-only`, so `vX.Y.Z`, `X.Y` and `sha-<7>` are all pushed. Earliest GHCR tag is
  v1.44.0. v1.43.0 (tag commit `f158a35`, 2026-02-27) is absent because that tree has no
  `release-images.yml`: `5fa4ed8` reached `main` only on 2026-03-11 (committer date; its author date
  2026-02-19 is misleading). A tag push runs the workflow files of the TAGGED commit. Check:
  `git -C "$H" merge-base --is-ancestor 5fa4ed8 f158a35` -> exit 1; same for `4b7571b` (v1.44.0) -> exit 0.

### `release.yml` (dead)
- Parsed `on:` of every workflow at the pinned SHAs: lago-api = {front-compatibility: pull_request;
  internal-build: workflow_dispatch, push; linters: pull_request; migrations-test: push, pull_request;
  release: release, workflow_dispatch; spec: push, pull_request}; lago-front = {codegen, cypress,
  lago-internal, linter, release: release, workflow_dispatch; tests}. No `repository_dispatch`.
  Re-check: `grep -rn repository_dispatch "$API/.github" "$FRONT/.github"` -> no output, exit 1.
- lago-api's own release builds `getlago/api` (no `latest`) and dispatches `lago-private-release` to
  `getlago/lago-embedded` (`$API/.github/workflows/release.yml:136-156`); lago-front's builds
  `getlago/front` through this repo's reusable workflow. Both fire on their OWN `released` events.
- Deleting `release.yml` is an owner call (see SKILL.md, OPEN DECISION REL-2).

### `events-processor-tests.yml`
- Postgres `postgres:14-alpine` service (:23-31); lago-expression `v0.2.0` checked out (:40-45) and built
  with the runner's unpinned Rust over the whole workspace (:47-49); `.so` copied to `/usr/local/lib` +
  `ldconfig` (:51-56; `mkdir -p /tmp/libs` at :54 is dead); Go `1.25.0` (:58-61); `go test -v ./...` (:63-64).
- `actions/checkout@v3` (:38, :41) and `actions/setup-go@v4` (:59) are flagged by actionlint as
  "too old to run on GitHub Actions" (3 of the 23 baseline findings).
- Not a gate for image builds: `build-processors-image.yaml` and the release workflows do not depend on it.
- Test policy and CI shape belong to `validation-and-qa`.

### `docker-ci.yml`
- Tests PUBLISHED images named in `docker-compose.yml:11,13`, not source. After a bump PR merges it
  fails if `getlago/api:vX` / `getlago/front:vX` are not on Docker Hub yet. Never runs on PRs.

### `gh-page.yml`
- Path filter is `deploy/deploy.sh` only (:7-8), but the artifact is the whole `deploy/` dir (:22-23).
  Compose-only edits under `deploy/` (e.g. `36327d2`, 2026-02-12) are not redeployed unless someone
  dispatches. `deploy.sh` changed `d54c463` (2025-07-21 UTC) then `2453945` (2026-09-03).
- `deploy/docker-compose.*.yml` pin `getlago/api:v1.27.1` / `getlago/front:v1.27.1`
  (`deploy/docker-compose.local.yml:14,16`, `light.yml:14,16`, `production.yml:15,17`); release PRs
  never touch them. Self-host consequences belong to `run-and-operate`.

## Action versions (as of 2026-10-01; `grep -h 'uses:' .github/workflows/* | sed 's/.*uses: *//' | sort | uniq -c`)
`docker/login-action@v3` x8, `docker/setup-buildx-action@v3` x6, `docker/metadata-action@v5` x5,
`actions/checkout@v4` x5, local reusable x5, `actions/upload-artifact@v4` x3,
`actions/download-artifact@v4` x3, `peter-evans/repository-dispatch@v2` x2,
`docker/build-push-action@v6` x2, `aws-actions/configure-aws-credentials@v4` x2,
`aws-actions/amazon-ecr-login@v2` x2, `actions/checkout@v3` x2, `docker/build-push-action@v5` x1,
`actions/upload-pages-artifact@v3`, `actions/setup-go@v4`, `actions/deploy-pages@v4`.
Every action is pinned by a mutable major tag; none by SHA (supply-chain policy: `security-and-supply-chain`).
