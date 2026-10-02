# Probing registries, module proxies and remote repos

Read this when a claim is about something published outside the repo: an image tag, its date or
architectures, a Go module version, a toolchain release, or whether a repo or ref exists. All commands
are read-only, need network, and were run on 2026-10-01 through the session proxy. Registries are
**mutable**: tags get re-pushed and `latest` moves. Record the digest or `last_updated` with the date.

Release-specific audits (which images a release must have, pin agreement) belong to the
`release-and-images` skill. This file teaches the probing method.

## Docker Hub (tag API, anonymous)

```bash
for t in v1.47.0 v1.48.0 v1.49.0 v1.50.0 v1.51.0 v1.53.0; do
  printf '%s ' "$t"; curl -s -o /dev/null -w '%{http_code}\n' "https://hub.docker.com/v2/repositories/getlago/lago/tags/$t"
done
```
Output: `v1.47.0 200`, `v1.48.0 404`, `v1.49.0 404`, `v1.50.0 404`, `v1.51.0 200`, `v1.53.0 200`.
The 404 body is `{"message":"httperror 404: tag 'v1.48.0' not found",…}`. The same three tags return
200 for `getlago/lago-events-processor`. This loop shows the method; the full list of `getlago/lago`
tags never published (as of 2026-10-01) is owned by the `release-and-images` skill.

```bash
curl -s https://hub.docker.com/v2/repositories/getlago/lago/tags/v1.53.0 \
 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["last_updated"], sorted({i["architecture"] for i in d["images"]}))'
```
Output: `2026-09-08T15:26:52.044644Z ['amd64', 'arm64']`. Compare `last_updated` with commit times in
`H` to order events (an image pushed after a fix commit was rebuilt).

Listing: `curl -s 'https://hub.docker.com/v2/repositories/getlago/lago/tags?page_size=100&name=v1.4'`
(`name` is a substring filter). Today it shows `v1.48.1` but no `v1.48.0`. Official images use
`library/<name>`: `curl -s https://hub.docker.com/v2/repositories/library/rust/tags/1.85` gives
`last_updated` 2025-03-19, and `library/golang/tags/1.25` gives 2026-08-19.

## GHCR (anonymous pull token, then the registry API)

```bash
img=getlago/api
TOK=$(curl -s "https://ghcr.io/token?scope=repository:$img:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" "https://ghcr.io/v2/$img/tags/list" \
 | python3 -c 'import json,sys; t=json.load(sys.stdin)["tags"]; print(len(t), [x for x in t if x.startswith("v1.5")], "sha-591ae90" in t)'
```
Output: `38 ['v1.50.0', 'v1.51.0', 'v1.52.0', 'v1.52.1', 'v1.53.0'] True`. The `sha-591ae90` tag shows
that the `sha-` tag carries the **lago-api** commit, not the umbrella commit. The earliest `v1.*` tag
on `getlago/{api,front,events-processor}` is `v1.44.0`.

Platforms of a tag (manifest index):
```bash
curl -s -H "Authorization: Bearer $TOK" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/$img/manifests/v1.53.0" \
 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mediaType"), [(m.get("platform") or {}).get("architecture") for m in d.get("manifests",[])])'
```
Output: `application/vnd.oci.image.index.v1+json ['amd64', 'unknown']`, which means amd64 only.
`unknown` is the build attestation, not a platform.

Pagination: with `?n=10`, the response carries `Link: </v2/getlago/api/tags/list?last=…&n=10>; rel="next"`.
Follow it until no `Link` header remains.

## Go module proxy and toolchains

```bash
curl -s https://proxy.golang.org/github.com/getlago/lago-expression/expression-go/@v/list      # v0.1.4, v0.1.0
curl -s https://proxy.golang.org/github.com/getlago/lago-expression/expression-go/@v/v0.1.4.info
curl -s -o /dev/null -w '%{http_code}\n' https://proxy.golang.org/github.com/getlago/lago-expression/expression-go/@v/v0.2.0.info   # 404
curl -s https://proxy.golang.org/github.com/twmb/franz-go/@latest                               # v1.22.1 (2026-09-27)
go list -m -versions github.com/twmb/franz-go                                                   # works outside a module
curl -s https://proxy.golang.org/golang.org/toolchain/@v/list | grep -E 'go1\.27\.[0-9]+\.linux-amd64$'
```
Facts these establish (as of 2026-10-01):
<!-- evidence-check: off (outputs of the commands above) -->
- No `expression-go` v0.2.0 module version exists, which is why `go.mod` stays at `v0.1.4` (change-control N3).
- The `.info` `Origin.Ref` is `refs/tags/expression-go/v0.1.4`, a sub-module tag.
- franz-go upstream is at v1.22.1; this repo pins v1.20.5 (`events-processor/go.mod:18`).
- `go1.27.0` and `go1.27.1` toolchains exist, so Go 1.25 is past upstream support.
<!-- evidence-check: on -->

## Git remotes (repos, refs, tags)

```bash
GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/getlago/lago-deploy HEAD
for r in lago-deploy lago-sidekiqs lago-license lago-self-billing lago-embedded lago-api lago-front \
         lago-expression lago-cli lago-agent-toolkit lago-packages lago-helm-charts; do
  printf '%-20s ' "$r"; GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/getlago/$r" HEAD 2>&1 | head -1 | cut -c1-60
done
```
<!-- evidence-check: off (outputs of the commands above) -->
- `fatal: could not read Username …` means the repo is private **or** does not exist. Anonymous GitHub
  cannot tell the two apart.
- Prove that a repo exists from references to it: `events-processor/Dockerfile.staging:8` names lago-deploy's
  workflow, and the `5308258` body cites `lago-deploy#3331`.
- Reachable on 2026-10-01: lago-api, lago-front, lago-expression, lago-cli, lago-agent-toolkit, lago-packages, lago-helm-charts.
- Auth-walled: lago-deploy, lago-sidekiqs, lago-license, lago-self-billing, lago-embedded. The last has no reference in this repo or its history (`git -C "$H" log -S'lago-embedded'` is empty), so do not assert that it exists.
<!-- evidence-check: on -->

Tags: use `.claude/skills/research-methodology/scripts/tag-map.sh`. Upstream drift:
`git ls-remote https://github.com/getlago/lago refs/heads/main` gives `a0de065…` vs the fork's `5308258`.

## GitHub API and PR metadata

- In this session `curl https://api.github.com/repos/getlago/lago/pulls/797` returns **403** ("GitHub
  access to this repository is not enabled for this session").
- The `gh` CLI token is invalid (`gh auth status`).
- Branch protection (`/branches/main/protection`) also returns 403, and it needs admin rights anyway.
- Fallback: for squash merges the commit body is the PR description (`git -C "$H" show -s <sha>`).
  For merge commits, `Merge pull request #NNN from getlago/<branch>` gives the branch name.
- A session with a GitHub connector or a valid token can read PRs (check with `gh auth status`); say which one you used.

## Third-party source (example: the `lago` CLI collision)

To check a claim about another public repo, clone it shallow into scratch and record HEAD sha + date:
```bash
C=$(mktemp -d)/lago-cli && git clone -q --depth 1 https://github.com/getlago/lago-cli "$C"
git -C "$C" log -1 --format='%h %cs'; grep -rn 'Use: *"exec\|Use: *"up' "$C/internal/cli" || true
```
Output on 2026-10-01: `49a7a03 2026-09-17`, and the only match is `internal/cli/builtin.go:72: Use: "upgrade"`
(no `exec` subcommand).
The `lago` alias vs binary trap itself belongs to the `build-and-env` skill.
