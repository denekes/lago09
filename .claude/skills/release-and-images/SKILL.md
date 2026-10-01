---
name: release-and-images
description: Release train and published images of the Lago umbrella repo, covering a release vX.Y.Z (api/front tags first, bump PR moving the api/front gitlinks and docker-compose.yml image tags, tag, GitHub Release "released"), what the 10 workflows publish (Docker Hub getlago/lago and lago-events-processor with latest, GHCR amd64-only, ECR, Pages), the reusable docker-build-multi-arch.yaml that lago-front calls @main, the all-in-one docker/Dockerfile and its Ruby/Node/Bundler/pnpm sync, events-processor Dockerfile/.dev/.staging, registry checks. Use on "bump version", "cut a release", "getlago/lago image missing", "latest tag", "Your Ruby version is ... but your Gemfile specified", "pnpm@latest", "linux-arm64", "release-docker-image.yml", "release-images.yml", "repository_dispatch", "Dockerfile.staging", "maintenance release". Not for commit/PR rules (change-control), local CGO builds (build-and-env), running images (run-and-operate), test policy (validation-and-qa), secrets audits (security-and-supply-chain).
---
# Release train and published images

How a Lago release is cut, what every workflow publishes where, how to keep each published image
buildable, and how to prove a release landed. Nothing in this repo documents the release process;
everything here is reconstructed from workflows, history and registries. Release work is change
class C5 (change-control).
Facts verified 2026-10-01 against HEAD 5308258 unless marked.

## When to use / when NOT to use

Use it when you:
- cut a minor, patch or maintenance release, or review a "bump version" PR;
- edit anything under `.github/workflows/`, `docker/`, `events-processor/Dockerfile*` or `connectors/Dockerfile`;
- investigate a missing or wrong image (`getlago/lago`, `lago-events-processor`, GHCR, `latest`);
- bump Ruby/Node/Bundler/pnpm in lago-api or lago-front and need to know what breaks here.

Do NOT use it for:
- commit message, PR and gitlink rules in day-to-day work, change-control N1-N13, gates per class: `change-control`;
- building/testing the Go binary without Docker, toolchain setup: `build-and-env`;
- running the all-in-one image, compose stacks, `deploy/` variants: `run-and-operate`;
- CI test policy and baselines (`events-processor-tests.yml` content): `validation-and-qa`;
- secrets, pinning-by-SHA and provenance audits: `security-and-supply-chain`;
- the story of each past failure in depth: `failure-archaeology`; release-day symptom lookup: `debugging-playbook`.

## Terms

- **Umbrella repo**: getlago/lago (this repo). lago-api and lago-front are submodules `api`, `front`.
- **Gitlink**: the commit SHA a submodule is pinned to (mode 160000). See it with `git ls-tree HEAD api front`.
- **Bump PR**: the release PR. It changes exactly 3 paths: `api`, `front`, `docker-compose.yml:11,13`.
- **Release train**: lago-api tag -> lago-front tag -> their Docker Hub images -> umbrella bump PR -> umbrella tag -> GitHub Release.
- **`released` event**: GitHub `release` activity fired when a non-draft, non-pre-release is published (or a pre-release is promoted). All Docker Hub release workflows listen to `types: [released]` only (`31d7bb8`, `8700d69`).
- **All-in-one image**: `getlago/lago`, built from `docker/Dockerfile` with api + front + Postgres + Redis + nginx inside. Also "single image".
- **Reusable workflow**: `.github/workflows/docker-build-multi-arch.yaml` (`workflow_call`), used by 5 jobs here and by lago-front.
- **Dispatch**: a manual `workflow_dispatch` run. For release workflows it builds the ref you dispatch ON, not the version you type.
- **Maintenance release**: a patch on an older line, tagged on a side-branch commit that never reaches `main` (v1.40.1).
- **Off-main tag**: a tag whose commit is not an ancestor of `main` (only `v0.38.0-beta`, `v1.40.1`).
- **`$API` / `$FRONT`**: read-only checkouts of lago-api / lago-front at the pinned gitlinks, from `pinned-checkout.sh`.

## Release train at a glance

| Step | Who / where | Fires | Publishes |
|---|---|---|---|
| lago-api release vX | lago-api repo | its `release.yml` | Docker Hub `getlago/api:vX` (amd64+arm64, no `latest`); dispatch to lago-embedded |
| lago-front release vX | lago-front repo | its `release.yml` -> **this repo's** `docker-build-multi-arch.yaml@main` | Docker Hub `getlago/front:vX` (exact tag only) |
| bump PR merged here | push to `main` | `docker-ci.yml` (pulls `getlago/api:vX`, `getlago/front:vX`) | nothing |
| tag `vX` pushed here | `push: tags: v*` | `release-images.yml` | GHCR `api`, `front` (built from the UPSTREAM tags), `events-processor` (this repo); amd64 only |
| GitHub Release vX published | `release: released` | `release-docker-image.yml`, `release-processors-image.yml`, `release.yml` | Docker Hub `getlago/lago:vX` + `latest`, `getlago/lago-events-processor:vX` + `latest`; `release.yml` dispatches to nobody |

Evidence and timeline for v1.53.0 (api image 14:24Z, front 14:27Z, bump 14:31Z, EP image 14:36Z,
all-in-one 15:26Z after two fixes): `reference/release-history.md` §4.

## Runbook: cut release vX.Y.Z

Steps marked **[perm]** need push rights on getlago/lago, `gh` auth or registry access. They are
not runnable in an agent sandbox; they were verified by reading the workflows and history, and the
staging commands were rehearsed in a throwaway clone. Everything else runs anywhere with network.
Who runs it: the duty rotates (63 bump commits on `main` since 2025-01-01 by 15 author names, about 14 people; most often
Vincent Pochet 12, Ancor Cruz 8, Toon Willems 6); there is no written checklist outside this skill
(`reference/release-history.md` §3).

0. Set up (repo root):
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   V=v1.54.0                                   # the version you release
   S=.claude/skills/release-and-images/scripts
   tagsha() { git ls-remote --tags "https://github.com/getlago/$1" "refs/tags/$V" "refs/tags/$V^{}" \
              | awk '/\^\{\}$/{p=$1} !/\^\{\}$/{t=$1} END{print (p!="")?p:t}'; }
   ```
   The scripts audit the repo of the CURRENT directory. If `main` does not carry `.claude/skills/`
   yet, the release branch of step 2 will not have them: set `S` to an absolute path in another
   checkout that has them (they find their foundation scripts next to themselves; rehearsed 2026-10-01).
1. Preconditions: upstream tags exist, umbrella tag does not, upstream images are published.
   ```bash
   API_SHA=$(tagsha lago-api); FRONT_SHA=$(tagsha lago-front)
   echo "api=${API_SHA:-MISSING} front=${FRONT_SHA:-MISSING} lago=$(tagsha lago)"
   for r in api front; do printf '%s ' $r; curl -s -o /dev/null -w '%{http_code}\n' "https://hub.docker.com/v2/repositories/getlago/$r/tags/$V"; done
   ```
   Expect two 40-hex SHAs, `lago=` empty, and `api 200`, `front 200` (with `V=v1.53.0` today you get
   `api=591ae90… front=0c5e539… lago=ba292b6…`). If front has no tag (v1.41.1-3 precedent), the GHCR
   `front` job should fail (inferred: `release-images.yml:28-29` checks out `refs/tags/$V` of lago-front): decide first.
2. **[perm for push]** Stage the bump on a fresh branch (works with empty `api/` and `front/`):
   ```bash
   git fetch origin main && git switch -c "release/$V" origin/main   # name not enforced: OPEN DECISION OD-7 (owner)
   git update-index --cacheinfo "160000,$API_SHA,api"
   git update-index --cacheinfo "160000,$FRONT_SHA,front"
   sed -i -E "s#^(  image: getlago/api:)v[0-9]+\.[0-9]+\.[0-9]+#\1$V#; s#^(  image: getlago/front:)v[0-9]+\.[0-9]+\.[0-9]+#\1$V#" docker-compose.yml
   git add docker-compose.yml && git diff --cached --stat
   ```
   Expect `api | 2 +-`, `docker-compose.yml | 4 ++--`, `front | 2 +-`, `3 files changed, 4 insertions(+), 4 deletions(-)`
   (the shape of every release since v1.44.0 except v1.52.1). macOS: `sed -i ''`.
   change-control's pre-commit guard flags the staged gitlinks: expected here and ONLY here (change-control N1).
3. Pre-release checks on the STAGED state:
   ```bash
   $S/single-image-pins.sh          # all-in-one vs pinned api/front: expect "# fails=0"
   $S/actionlint-local.sh           # only if workflows changed: expect "# findings=23 baseline=23"
   ```
   Any FAIL: fix `docker/Dockerfile` (Ruby/Node) in the SAME PR, re-run. Also run change-control's
   pin-sync check if events-processor pins moved. Then commit and audit the candidate:
   ```bash
   git commit -m "chore(release): bump version to $V"      # most common prefix (20 of 63 bump commits since 2025)
   $S/release-pin-audit.sh --candidate HEAD "$V"           # expect "... compose=$V/$V  OK", exit 0
   ```
4. **[perm]** Push the branch, open the PR, paste the three outputs in the body, get review, merge.
   Never force-push a PR branch or `main` (change-control N2). After merge, `docker-ci.yml` on `main`
   must go green (it pulls the new `getlago/api`/`front` images).
5. **[perm]** Tag the merged commit and push the tag (fires GHCR builds):
   ```bash
   git fetch origin main && C=$(git rev-parse origin/main)
   $S/release-pin-audit.sh --candidate "$C" "$V"           # must be OK before tagging
   git tag "$V" "$C" && git push origin "$V"                # lightweight, like all 195 existing tags
   ```
6. **[perm]** Publish the GitHub Release (fires the Docker Hub builds). Not `--draft`, not `--prerelease`:
   ```bash
   gh release create "$V" --repo getlago/lago --verify-tag --title "$V" --notes-file release-notes.md
   ```
   Release notes: list the lago-api/lago-front versions, any self-host action (Postgres major change,
   new required env var), and known gaps. Historic notes are not visible from here (UNVERIFIED format).
7. Verify (anywhere, after the runs finish):
   ```bash
   $S/artifact-verify.sh "$V"       # expect 9 OK lines and "# problems=0"
   ```
8. If the all-in-one build failed (8 past releases show the pattern, inferred from push times:
   `reference/release-history.md` §5):
   - transient (runner queue, Docker Hub 429): re-run the failed jobs on the same run (tag ref) **[perm]**;
   - needs a Dockerfile/runner fix: land it on `main` by PR, then EITHER cut a patch release
     (v1.45.1 precedent; image == tag) OR dispatch from `main` (the historical practice, image != tag):
     ```bash
     $S/release-pin-audit.sh --candidate origin/main "$V"   # main must still carry $V's gitlinks + compose
     gh workflow run release-docker-image.yml --repo getlago/lago --ref main -f version="$V"   # [perm]
     ```
     Which one is policy is OPEN DECISION REL-3 (owner). Both paths re-push `latest`.

### Maintenance release (patch on an older line, e.g. v1.40.1)

Precedent `8c83bd2` (2026-02-19): branch from the old release commit (`147b47e`, v1.40.0), bump only
what changed (api -> lago-api v1.40.1; lago-front re-tagged the same commit as v1.40.1), tag the branch
commit, never merge it to `main`. Commands = steps 1-7 with `git switch -c "release/$V" <old-tag-commit>`
and `--candidate HEAD`. Then expect `latest` to move to the OLD line: both Docker Hub release workflows
tag `latest` unconditionally (`release-docker-image.yml:38,98`, `release-processors-image.yml:38,92`).
`gh release create --latest=false` only changes GitHub's badge, not image tags. Restoring `latest`
(CANDIDATE, needs Docker Hub credentials; preview with `--dry-run`):
`docker buildx imagetools create -t getlago/lago:latest getlago/lago:<newest>` (same for `lago-events-processor`).
Policy: OPEN DECISION REL-4 (owner).

### `latest` facts (2026-10-01)

`getlago/lago:latest` and `getlago/lago-events-processor:latest` == v1.53.0 digests. `getlago/api`
has no `latest`. `getlago/front:latest` exists but was last pushed 2022-06-02: never tell users to pull it.

## Workflow inventory (10 files)

| Workflow | Trigger | Publishes | Status |
|---|---|---|---|
| `release-docker-image.yml` | `released`; dispatch(`version`) | Docker Hub `getlago/lago` vX + `latest`, amd64+arm64 | live |
| `release-processors-image.yml` | `released`; dispatch(`version`) | Docker Hub `getlago/lago-events-processor` vX + `latest`, amd64+arm64 | live |
| `release-images.yml` | push tag `v*` | GHCR `api`, `front`, `events-processor`: `vX.Y.Z`, `X.Y`, `sha-<7>`, amd64 only | live |
| `release.yml` | `released` | `repository_dispatch` to lago-api/lago-front | **dead** (no receiver at the pinned SHAs) |
| `build-processors-image.yaml` | push `main` on `events-processor/**`; dispatch | ECR `lago-events-processor` `main`, `sha-<7>`, amd64+arm64 | UNVERIFIED (private) |
| `build-connectors-image.yaml` | push `main` on `connectors/**`; dispatch(`ref`) | ECR `lago-connectors` | UNVERIFIED (private) |
| `docker-build-multi-arch.yaml` | `workflow_call` | whatever the caller asks | live; lago-front calls it `@main` |
| `events-processor-tests.yml` | push `main`; PR on `events-processor/**` | nothing (tests) | live, the only PR workflow |
| `docker-ci.yml` | push `main`; dispatch | nothing (smoke test of published images) | live |
| `gh-page.yml` | push `main` on `deploy/deploy.sh` only; dispatch | GitHub Pages from `deploy/` | live; host UNVERIFIED |

Inputs, secrets (names only), line numbers, tag recipe, permissions and defects: `reference/workflows.md`
(read when editing or debugging any workflow). Secret names in use: `DOCKERHUB_USERNAME`,
`DOCKERHUB_PASSWORD`, `SEGMENT_WRITE_KEY`, `GH_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`.

**Cross-repo blast radius.** lago-front@0c5e539 `.github/workflows/release.yml:13` uses
`getlago/lago/.github/workflows/docker-build-multi-arch.yaml@main`. Any merge to that file changes the
next `getlago/front` release with no version pin. Review such PRs as cross-repo (OPEN DECISION REL-5).

## Artifact matrix

| Image | Registry | Built by | Trigger | Source | Arch | Tags |
|---|---|---|---|---|---|---|
| `getlago/lago` | Docker Hub | `release-docker-image.yml` | `released` / dispatch | `docker/Dockerfile`, repo root + submodules | amd64, arm64 | `vX.Y.Z`, `latest` |
| `getlago/lago-events-processor` | Docker Hub | `release-processors-image.yml` | `released` / dispatch | `events-processor/Dockerfile` | amd64, arm64 | `vX.Y.Z`, `latest` |
| `getlago/api` | Docker Hub | lago-api `release.yml` | lago-api `released` | lago-api `Dockerfile` | amd64, arm64 | `vX.Y.Z` |
| `getlago/front` | Docker Hub | lago-front `release.yml` -> reusable `@main` | lago-front `released` | lago-front `Dockerfile` | amd64, arm64 | `vX.Y.Z` (stale 2022 `latest`) |
| `ghcr.io/getlago/api`, `front` | GHCR | `release-images.yml` | tag push here | upstream repo at `refs/tags/vX` | amd64 | `vX.Y.Z`, `X.Y`, `sha-<upstream 7>` |
| `ghcr.io/getlago/events-processor` | GHCR | `release-images.yml` | tag push here | `events-processor/Dockerfile` | amd64 | `vX.Y.Z`, `X.Y`, `sha-<umbrella 7>` |
| `…/lago-events-processor` | ECR (private) | `build-processors-image.yaml` | push `main` | `events-processor/Dockerfile` | amd64, arm64 | `main`, `sha-<7>` |
| `…/lago-connectors` | ECR (private) | `build-connectors-image.yaml` | push `main` / dispatch | `connectors/Dockerfile` | amd64, arm64 | `main`/branch, `sha-<7>` |
| hardened EP (staging) | private (UNVERIFIED) | lago-deploy workflow (UNVERIFIED) | UNVERIFIED | `events-processor/Dockerfile.staging` | UNVERIFIED | UNVERIFIED |
| `deploy/` site | GitHub Pages | `gh-page.yml` | `deploy/deploy.sh` change / dispatch | `deploy/` dir | n/a | n/a |

Coverage today (`artifact-verify.sh --sweep --from v1.32.0 --no-ghcr`): `getlago/lago` is missing
**v1.33.0, v1.33.1, v1.33.2, v1.48.0, v1.49.0, v1.50.0**; `lago-events-processor` is missing v1.41.2;
`getlago/front` v1.41.1-3 never existed. GHCR covers v1.44.0..v1.53.0 completely.
`deploy/docker-compose.*.yml` still pin `getlago/api:v1.27.1`; bump PRs never touch them (OPEN DECISION REL-6 (owner)).

## All-in-one image (`docker/`): what must stay in sync

Read `reference/all-in-one-image.md` before editing `docker/*` or when the release build fails.

| `docker/Dockerfile` | Must match (pinned api/front) | Today | Breaks how |
|---|---|---|---|
| `ARG RUBY_VERSION=4.0.6` (:2) | `$API/.ruby-version`, `$API/Gemfile:6` | 4.0.6 = 4.0.6 | `bundle install` exits 18: "Your Ruby version is X, but your Gemfile specified Y" (probed) |
| `ARG NODE_VERSION=24` (:1) | `$FRONT/package.json:192` engines.node | 24 vs 24.20.0 | pnpm ignores root engines (probed); still, v1.53.0 needed the day-of fix `b267320` (exact failure UNVERIFIED) |
| `ENV BUNDLER_VERSION=4.0.4` (:18) | `$API/Gemfile.lock` BUNDLED WITH | 4.0.4 vs 4.0.16 | same major OK; the ENV disables Bundler's auto-switch |
| `corepack prepare pnpm@latest` (:12) | `$FRONT/package.json:11` packageManager | pnpm@10.34.5 | inert while packageManager exists (probed: corepack runs 10.34.5 in the project, `pnpm@latest`=12.8.1 is only downloaded) |
| `ruby:<v>-slim` base (:16, :37) | `postgresql-17` at :49 | trixie | PGDG line (:43-44) is broken; PG must come from Debian main |

Pre-release checklist = `single-image-pins.sh` (ruby, node, bundler, pnpm, lockfile, without, debian,
seed, workflow) plus a manual diff of `docker/runner.sh:88-91` against `$API/scripts/migrate.sh`.
It encodes the 7 release-day breakage chains: v1.21.0 workflow (`023bfe1`, `c91af2b`), Ruby 3.4
(`e07e182`, `d0099a9`, `9eb8c3b`, `92b1af2`), Debian roll (`14fa1e0` -> `b6b98c8`, v1.33.0-2 lost),
pnpm prune (`18b26d0`, v1.35.0), seed order (`fd77a74`), Bundler 4 (`558814a`, v1.45.0), Ruby/Node lag
(`b267320`, `f719ef1`, v1.53.0). Replaying it on old tags flags them:
`single-image-pins.sh --ref v1.53.0` -> FAIL ruby (4.0.2 vs 4.0.6) + FAIL node (20 vs 24.20.0).
Read the two differently: the ruby FAIL is a proven breaker (Bundler exit 18, probed); the node FAIL
is a policy guard. It also fires on all 24 tags `v1.37.0` .. `v1.52.1`, and 21 of those images WERE
published with Node 20 (the 3 others are the unexplained v1.48.0-v1.50.0 gap; replayed 2026-10-01).
Residual risks: no PR-time build (a `push: false` PR build is a TARGET, not current state),
`pnpm@latest`, no `--frozen-lockfile`, floating Debian base, `LAGO_VERSION` and `SEGMENT_WRITE_KEY`
never reaching the image (`release-docker-image.yml:48-51,61-62` vs `docker/Dockerfile:1-2,58`).

## events-processor and connectors images

Read `reference/events-processor-images.md` before editing `events-processor/Dockerfile*` or `connectors/Dockerfile`.
- Prod `Dockerfile`: `rust:1.85` + lago-expression `v0.2.0` -> `golang:1.25` -> `debian:13-slim`, root user,
  no `.dockerignore`. Built three times: Docker Hub (release), GHCR (tag), ECR (every `main` push on `events-processor/**`).
- `Dockerfile.dev`: dev stack only (`docker-compose.dev.yml:318-325`), pinned `dlv@v1.25`, `air@v1.62`.
- `Dockerfile.staging` (HEAD `5308258`): SOC2-hardened, Wolfi bases `ghcr.io/getlago/events-processor-{build,base}:latest`
  (multi-arch, also immutable `<sha>` tags), `USER 65532`; its workflow is in private lago-deploy (UNVERIFIED).
- Pin set (lago-expression x4, Rust x2, Go x5): move together (change-control N3; its pin-sync check).
  `5077151` -> `e8bbd60` shows the Rust image is part of that set.

## If you see X, do Y

| You see | Do |
|---|---|
| `Subproject commit` in a PR that is not a bump | stop; change-control N1 (`12b8101` -> `647de3e`) |
| `release-pin-audit.sh --candidate` says `PIN-MISMATCH` | fix the gitlinks before tagging (v1.52.1 shipped v1.52.0 api/front in `getlago/lago`) |
| `NO-UPSTREAM-TAG(front)` | api-only patch: the GHCR `front` job should fail (inferred); agree on it before tagging |
| `artifact-verify.sh` `MISS docker.io/getlago/lago:vX` | runbook step 8 |
| `WARN … latest went backwards` | maintenance-release effect; OPEN DECISION REL-4 (owner) |
| `Your Ruby version is … but your Gemfile specified …` in the release build | bump `docker/Dockerfile:2` to `$API/.ruby-version` |
| `Unsupported platform: <x>` in job `prepare` | `platforms` accepts only `amd64`,`arm64` (`docker-build-multi-arch.yaml:148-158`) |
| arm64 leg never starts (fork or new org) | `linux-arm64` runner label unavailable (UNVERIFIED which runner) |
| `429 Too Many Requests` pulling a base | anonymous Docker Hub pulls (`986f29b`); re-run, then consider an authenticated pull |
| `exact-tags-only is set but no semver tag (X.Y.Z) found` | the caller's ref is not `vX.Y.Z` (`docker-build-multi-arch.yaml:246`) |
| actionlint count above 23 | new workflow defects: fix before merging (CANDIDATE gate, modelled on OPEN DECISION OD-6 (owner) for Go lint) |

## Supply-chain notes that affect releases

Details and audits: `security-and-supply-chain`. Release-relevant facts only:
- Every action is pinned by a mutable major tag (`actions/checkout@v4`, `docker/build-push-action@v6`, …), none by SHA; buildx `version: latest`.
- `pnpm@latest`, `node:24-alpine`, `ruby:<v>-slim`, `golang:1.25`, `events-processor-{build,base}:latest` float.
- ECR pushes use long-lived `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`; OIDC `role-to-assume` exists but is unused. The ECR account id is in public workflow files.
- The reusable workflow hashes build-secret VALUES into a public tag suffix `.build-<8 hex>` (`docker-build-multi-arch.yaml:264-277`).
- Never put secret values in workflows, notes or skills (change-control N11).

## Open decisions (owner)

Release-specific owner calls. They are not in OD-1..OD-9 yet; route them through change-control.
- **OPEN DECISION REL-1**: is `getlago/lago` still supported? Backfill v1.33.0-2 / v1.48.0-v1.50.0? Alert on release-build failure?
- **OPEN DECISION REL-2**: delete `release.yml` (dead dispatch, still needs `GH_TOKEN`)?
- **OPEN DECISION REL-3**: release-day fix policy: dispatch from `main` (image != tag) or always cut a patch release?
- **OPEN DECISION REL-4**: maintenance releases and `latest`: skip it, or restore it afterwards?
- **OPEN DECISION REL-5**: pin lago-front's call to the reusable workflow (`@main`) to a tag or SHA?
- **OPEN DECISION REL-6**: were v1.52.1 (stale pins) and v1.41.2/3 intended; who owns `deploy/*.yml` image tags (v1.27.1)?
- Related: OPEN DECISION OD-7 (owner): bump PR subject length, `misc` type, branch naming.

## Scripts

All read-only on the repo; caches under `${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}`. `--help` on each.

| Script | Purpose | Example | Expected (2026-10-01) |
|---|---|---|---|
| `scripts/release-pin-audit.sh` | per umbrella tag (or a candidate commit): gitlinks vs same-named lago-api/lago-front tags, compose image tags | `release-pin-audit.sh` | 52 rows v1.24.0..v1.53.0, `# audited=52 ok=48 not-ok=4` (v1.41.1, v1.41.2, v1.41.3, v1.52.1), exit 1 |
| | | `release-pin-audit.sh --candidate HEAD v1.53.0` | `OK`, plus a WARNING that the tag exists, exit 0 |
| `scripts/artifact-verify.sh` | Docker Hub (4 repos) + GHCR (3) presence, archs, `latest` | `artifact-verify.sh v1.53.0` | 9 OK, `# problems=0`, exit 0 |
| | | `artifact-verify.sh --sweep` | 14 rows from v1.44.0, `# releases=14 with-missing-artifacts=3`, exit 1 |
| `scripts/single-image-pins.sh` | `docker/Dockerfile` vs pinned api/front + regression guards | `single-image-pins.sh` | 5 OK, 4 WARN (node, bundler, pnpm, lockfile), `# fails=0`, exit 0 |
| | | `single-image-pins.sh --ref v1.53.0` | FAIL ruby, FAIL node, `# fails=2`, exit 1 |
| `scripts/actionlint-local.sh` | actionlint 1.7.7 + shellcheck 0.11.0 (sha256-pinned, cached) over all workflows | `actionlint-local.sh` | 20 shellcheck (SC2086 13, SC2046 5, SC2155 1, SC2006 1) + 3 action, `# findings=23 baseline=23`, exit 0 |

Exit codes: 0 clean; 1 findings; 2 usage (unknown flag, missing option value, unknown tag/ref);
3 network / registry API error / download / unreadable source.
More expected outputs (`--ref` replays, sweeps from older versions): `reference/verification.md` §4.

## Reference files

- `reference/workflows.md`: read when editing or debugging any workflow (inputs, secrets by name, line numbers, tag recipe, defects).
- `reference/release-history.md`: read before calling a past release normal (audit rows, gaps, 8 rebuilds from `main`, v1.40.1, `latest`, who released).
- `reference/all-in-one-image.md`: read before touching `docker/*` or when the release build fails (assembly, sync table, 7 chains, risks).
- `reference/events-processor-images.md`: read before touching `events-processor/Dockerfile*` or `connectors/Dockerfile`.
- `reference/verification.md`: read when proving a release landed by hand (registry API recipes, expected outputs, blind spots).

## Provenance and maintenance

- Sources: `.github/workflows/*` (10), `docker/Dockerfile`, `docker/runner.sh`, `docker/Procfile`,
  `.dockerignore`, `docker-compose.yml:11,13`, `events-processor/Dockerfile*`, `connectors/Dockerfile`;
  `$API/.github/workflows/release.yml`, `$API/.ruby-version`, `$API/Gemfile`, `$API/Gemfile.lock`,
  `$API/Dockerfile`, `$API/scripts/migrate.sh`; `$FRONT/.github/workflows/release.yml`,
  `$FRONT/package.json`, `$FRONT/Dockerfile`; history clone commits cited above; Docker Hub and GHCR
  APIs; probes run on this host (Bundler Ruby-mismatch, corepack/pnpm, pnpm engines).
- Volatile facts, one re-verification command each (from repo root; `S=.claude/skills/release-and-images/scripts`):
  - 10 workflows: `ls .github/workflows | wc -l` -> `10`
  - pins: `git ls-tree HEAD api front` -> `591ae90…` / `0c5e539…`
  - lago-front calls the reusable workflow @main: `grep -n 'docker-build-multi-arch.yaml@main' "$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)/.github/workflows/release.yml"` -> `13:`
  - no dispatch receiver: `grep -rln repository_dispatch "$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)/.github" "$(.claude/skills/research-methodology/scripts/pinned-checkout.sh front)/.github"` -> no output
  - Docker Hub gap: `curl -s -o /dev/null -w '%{http_code}\n' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.49.0` -> `404`
  - pin audit: `$S/release-pin-audit.sh | tail -1` -> `# audited=52 ok=48 not-ok=4`
  - coverage: `$S/artifact-verify.sh --sweep | tail -1` -> `# releases=14 with-missing-artifacts=3`
  - all-in-one sync: `$S/single-image-pins.sh | tail -1` -> `# fails=0`
  - actionlint: `$S/actionlint-local.sh | tail -1` -> `# findings=23 baseline=23`
  - `pnpm@latest` still there: `grep -n 'pnpm@latest' docker/Dockerfile` -> `12:`
  - npm pnpm latest: `curl -s https://registry.npmjs.org/pnpm | jq -r '."dist-tags".latest'` -> `12.8.1`
  - Debian behind Ruby base: `for t in 4.0.6-slim 4.0.6-slim-trixie; do curl -s https://hub.docker.com/v2/repositories/library/ruby/tags/$t | jq -r .digest; done` -> the same digest twice
- Update triggers: any change under `.github/workflows/`, `docker/`, `events-processor/Dockerfile*`,
  `connectors/Dockerfile`; every new release (append to the audit expectations); lago-api Ruby/Bundler
  bumps; lago-front Node/pnpm/packageManager changes or edits to its `release.yml`; a Debian release
  behind `ruby:*-slim`; a new actionlint/shellcheck version; any owner answer to REL-1..REL-6.
