# Post-release verification: registry API recipes

Read this when you must prove a release is published (or explain why it is not) without Docker,
GitHub API access or registry credentials. `scripts/artifact-verify.sh` wraps all of this; the raw
commands below are for one-off questions. All verified 2026-10-01 from an agent sandbox (anonymous
HTTPS through the session proxy). How to probe registries in general: `research-methodology`.

## 1. Docker Hub (anonymous, no token)

```bash
# one tag: 200 + JSON, or 404 {"message":"httperror 404: tag '…' not found"}
curl -s -o /dev/null -w '%{http_code}\n' https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.48.0
# -> 404   (as of 2026-10-01; v1.47.0 and v1.51.0 -> 200)

# digest, push time, platforms ("unknown" = buildx attestation manifest, not a platform)
curl -s https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.53.0 \
  | jq -r '.digest, .last_updated, ([.images[].architecture] | unique | join(","))'
# -> sha256:ba58a030e828b082267318a5b943d364071001ad9debafc426c78e8c51f935f9
#    2026-09-08T15:26:52.044644Z
#    amd64,arm64

# where does latest point? compare digests
for t in latest v1.53.0; do curl -s https://hub.docker.com/v2/repositories/getlago/lago/tags/$t | jq -r .digest; done
# -> the same digest twice

# all tags (paginated, 100 per page; follow .next)
curl -s 'https://hub.docker.com/v2/repositories/getlago/api/tags?page_size=100' | jq -r '.count, .next'
# -> 211 and a next-page URL (as of 2026-10-01)
```
Tag counts on 2026-10-01: `getlago/lago` 51 (50 versions + `latest`), `getlago/lago-events-processor`
40 (39 + `latest`), `getlago/api` 211, `getlago/front` 201.

## 2. GHCR (anonymous token per repository)

```bash
tok=$(curl -s "https://ghcr.io/token?scope=repository:getlago/api:pull" | jq -r .token)
curl -s -H "Authorization: Bearer $tok" "https://ghcr.io/v2/getlago/api/tags/list?n=2000" | jq -r '.tags | length'
# -> 38   (14 x vX.Y.Z from v1.44.0, 10 x X.Y, 14 x sha-<7>; same shape for front and events-processor)
curl -s -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  https://ghcr.io/v2/getlago/api/manifests/v1.53.0 | jq -c '[.manifests[].platform.architecture]'
# -> ["amd64","unknown"]   (amd64 + attestation; release-images.yml builds amd64 only)
```
Blob downloads (image configs, layers) go to `pkg-containers.githubusercontent.com`, which the agent
proxy rejects: you can list tags and manifests, not read image contents.

## 2b. `docker buildx imagetools` (no daemon needed, but rate-limited)

`docker buildx imagetools inspect getlago/lago:v1.53.0` needs no Docker daemon, but it talks to
`registry-1.docker.io` anonymously, which is rate-limited: one run on 2026-10-01 from an agent
sandbox got `429 Too Many Requests`, a re-run later the same day succeeded (digest
`sha256:ba58a030e828…`, OCI index). Treat a 429 as transient. Prefer the `hub.docker.com` API above for scripts; use
`imagetools inspect` (ideally after `docker login`) when you need the full manifest list.

## 3. Which commit is inside a GHCR image

`release-images.yml` -> reusable workflow with `metadata-action` `context: 'git'`: the `sha-<7>` tag
is the commit of the repository that was checked out. Verified: `ghcr.io/getlago/api` has
`sha-591ae90` (lago-api v1.53.0) and `sha-7895cd2` (lago-api v1.52.1); `ghcr.io/getlago/front` has
`sha-0c5e539`/`sha-9614363`; `ghcr.io/getlago/events-processor` has `sha-ba292b6`/`sha-01cfbc6`
(umbrella tag commits). Docker Hub images carry no commit tag; for `getlago/lago` the commit is "the
tag, unless the image was rebuilt by dispatch" (see `release-history.md` §5).

## 4. Expected outputs of the shipped script (2026-10-01)

| Command | Expected |
|---|---|
| `artifact-verify.sh v1.53.0` | 9 OK lines (4 Docker Hub, 2 `latest == v1.53.0`, 3 GHCR amd64), `# problems=0`, exit 0 |
| `artifact-verify.sh v1.48.0` | `MISS  docker.io/getlago/lago:v1.48.0  (Docker Hub 404)`, `# problems=1`, exit 1 |
| `artifact-verify.sh v1.40.1` | 4 OK, 2 INFO (`latest` != v1.40.1), `SKIP` GHCR, exit 0 |
| `artifact-verify.sh --sweep` (from v1.44.0) | 14 rows; `-` only in the `hub:lago` column for v1.48.0, v1.49.0, v1.50.0; `# releases=14 with-missing-artifacts=3`, exit 1 |
| `artifact-verify.sh --sweep --from v1.32.0 --no-ghcr` | missing: `hub:lago` v1.33.0-2 and v1.48.0-v1.50.0; `hub:lago-events-processor` v1.41.2; `hub:front` v1.41.1-3; `# releases=40 with-missing-artifacts=9`, exit 1 |
| `artifact-verify.sh --sweep --from v1.0.0 --no-ghcr` | same 9 rows (`.` = not expected: `getlago/lago` before v1.21.0, `lago-events-processor` before v1.32.0); `# releases=99 with-missing-artifacts=9`, exit 1 |
| `artifact-verify.sh v1.53.0` with the registry unreachable | `artifact-verify: Docker Hub API unreachable`, exit 3 (a registry error JSON such as a 429 page also exits 3) |
| `single-image-pins.sh --ref v1.33.0` | FAIL debian (trixie base, Dockerfile installs `postgresql-15`), `# fails=1`, exit 1 |
| `single-image-pins.sh --ref v1.41.1` | FAIL node + FAIL seed, `# fails=2`, exit 1 |
| `single-image-pins.sh --ref v1.45.0` | FAIL node + FAIL without (Bundler 4.0.4 with `--without`), `# fails=2`, exit 1 |
| `single-image-pins.sh --ref v1.47.0` (published fine) | FAIL node only, `# fails=1`, exit 1: the node check is a policy guard |
| `release-pin-audit.sh --candidate HEAD v1.54.0` (before upstream tags exist) | `NO-UPSTREAM-TAG(api) NO-UPSTREAM-TAG(front) COMPOSE-MISMATCH`, exit 1 |

When a new release vN ships cleanly, expect `artifact-verify.sh vN` -> `# problems=0` and the sweep
count of rows to grow by one with the same 3 known gaps.

## 5. What you cannot see from an agent sandbox

| Question | Why invisible | Where the answer lives |
|---|---|---|
| Did a workflow run fail, who dispatched it, with which ref? | no GitHub API access to getlago/* (`api.github.com` answers 403 "not enabled for this session"; `gh` token invalid) | Actions tab of getlago/lago (owner) |
| GitHub Release objects (draft/pre-release flags, notes, author) | same; `releases.atom` also 403 | Releases page |
| ECR images (`lago-events-processor`, `lago-connectors`) | private AWS account | AWS console / lago-deploy |
| lago-deploy's staging workflow and manifests | private repo | owner |
| Toolchain inside `events-processor-build:latest` | GHCR blob host blocked | a machine with registry access: `docker run --rm ghcr.io/getlago/events-processor-build:latest go version` (UNVERIFIED) |
| Whether `deploy.getlago.com` is this repo's Pages site | host unreachable from the proxy; no `CNAME` in `deploy/` | owner / DNS |
| Historical `latest` digests | registries keep no tag history | none |
