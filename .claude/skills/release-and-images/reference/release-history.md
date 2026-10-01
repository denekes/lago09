# Release history: pins, gaps, rebuilds, people

Read this before you call a past release "normal", when an audit row is not OK, or when you need a
precedent (maintenance release, release-day fix). Facts verified 2026-10-01 with the history clone
(`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`), `git ls-remote --tags` of the
three repos, and the Docker Hub / GHCR APIs. The history clone has no tags: tag -> commit always comes
from `git ls-remote` (all 195 getlago/lago tags are lightweight: 0 `^{}` lines).

## 1. Pin audit, v1.24.0 .. v1.53.0 (`scripts/release-pin-audit.sh`)

`release-pin-audit.sh` (default range) -> `# audited=52 ok=48 not-ok=4`, exit 1. The 4 rows:

| Tag | Tag commit | api gitlink | front gitlink | compose | Verdict | Meaning |
|---|---|---|---|---|---|---|
| v1.41.1 | `6ef21b2` | v1.41.1 | v1.41.0 | v1.41.1/v1.41.0 | NO-UPSTREAM-TAG(front) COMPOSE-MISMATCH | lago-front never tagged v1.41.1..3; front stayed at v1.41.0 on purpose (inferred) |
| v1.41.2 | `fd77a74` | **v1.41.1** | v1.41.0 | v1.41.1/v1.41.0 | PIN-MISMATCH(api) NO-UPSTREAM-TAG(front) COMPOSE-MISMATCH | the tag sits on a single-image fix commit (`fd77a74`, "Fix one docker image with seed"), not on a bump |
| v1.41.3 | `9e8edc0` | **v1.41.2** | v1.41.0 | v1.41.2/v1.41.0 | PIN-MISMATCH(api) NO-UPSTREAM-TAG(front) COMPOSE-MISMATCH | subject says "bump version to v1.41.3" but the diff sets api v1.41.2 |
| v1.52.1 | `01cfbc6` | **v1.52.0** (`731388f`) | **v1.52.0** (`dbde527`) | v1.52.1/v1.52.1 | PIN-MISMATCH(api) PIN-MISMATCH(front) | the bump changed only `docker-compose.yml`; `getlago/lago:v1.52.1` therefore bakes v1.52.0 api/front (inferred from the workflow), while `getlago/api:v1.52.1` and GHCR `api:v1.52.1` (`sha-7895cd2`) are real v1.52.1. Side effect (inferred): lago-api v1.52.1 already pins Ruby 4.0.6 (`.ruby-version` at `7895cd2`) while the tag's `docker/Dockerfile` had 4.0.2, so a correct bump would have hit the Ruby breakage of v1.53.0 one release earlier |

Older tags are noisy (`--all`): e.g. v1.23.0 -> api v1.22.1 because the tag was cut before its bump.
Only two tags are off `main`: `v0.38.0-beta` and `v1.40.1` (`8c83bd2`).

## 2. Release PR shape (measured)

Every release commit (or merge diff vs first parent) from v1.44.0 to v1.53.0 changes exactly
`api | 2 +-`, `docker-compose.yml | 4 ++--`, `front | 2 +-` (3 files, 4+/4-), except `01cfbc6`
(v1.52.1: compose only). Command:
`for c in 4b7571b 074fc9a df9e9b4 d6aa3e6 3ccdb23 832e7b1 761d85e a4708fa 3abd734 05b2d16 85fa787 37a401e 01cfbc6 ba292b6; do git -C "$H" diff --stat "$c^1" "$c" | tail -1; done`.
The compose lines are `docker-compose.yml:11` (`image: getlago/api:vX`, anchor `x-backend-image`)
and `:13` (`image: getlago/front:vX`, anchor `x-frontend-image`).

Merge style is mixed: v1.44.0, v1.45.0, v1.47.0, v1.48.0, v1.52.1, v1.53.0 tag a squash commit;
v1.45.1, v1.45.2, v1.46.0, v1.48.1..v1.52.0 tag the PR merge commit.

Branch names are not standardized (`misc-v1-50-0` #759, `misc-v-52-0` #782,
`chore/bump-version-v1.51.0` #770, `release-v1.48.1` #753, `misc/release-v1-46-0` #739,
`bump-version` #698/#705/#675/#560, `release/1.34.2` #602). Subjects of the 63 bump commits on main
since 2025-01-01 (definition in §3): `chore(release): bump version to vX.Y.Z` 20, `misc(version): Bump version to X` 7,
`misc: Bump version to X` 5, `release: Bump to vX version` 4, others 27 (typos included:
`chore(releasae)` `ba596c0`, `v.1.41.0` `12d0579`). Convention questions: OPEN DECISION OD-7 (owner), via change-control.

## 3. Who has run releases (bump commits on main since 2025-01-01, 63 total)

Here a "bump commit" is a non-merge commit that changes the compose api image tag (`-G` below).
Two of the 63 move no gitlink: `01cfbc6` (v1.52.1, compose-only bump) and `456bec7` (a compose
refactor, not a bump). change-control counts 60 release bumps among 77 gitlink-moving commits
(`git -C "$H" log --no-merges --since=2025-01-01 --format=%h 5308258 -- api front | wc -l` -> 77).

`git -C "$H" log --no-merges --since=2025-01-01 --format='%an' -G'image: getlago/api:v' -- docker-compose.yml | sort | uniq -c | sort -rn`
-> Vincent Pochet 12, Ancor Cruz 8, Toon Willems 6, Jérémy Denquin 5, Anna Velentsevich 5,
Yohan R./Yohan Robert 6, Romain Sempé 4, Julien Bourdeau 4, Domenico Falco 4, Andrew Kozin 3,
Thomas Battiston 2, Lovro Colic 2, 1 each for two others. The duty rotates; there is no single
release owner visible in the repo, and no written runbook anywhere in it
(`grep -rni 'bump version\|release' --include=*.md . | grep -v .claude` finds only a README badge,
a README testimonial and two CONTRIBUTING.md links to the releases page; as of 2026-10-01).
Release-day image fixes were made mostly by Vincent Pochet, Jérémy Denquin and Yohan R.

Cadence 2026 (bump dates): v1.39.0 01-12, v1.40.0 01-23, v1.41.0 01-29, v1.41.1 02-02, v1.41.3 02-04,
v1.42.0 02-17, v1.40.1 02-19 (maintenance, off-main), v1.43.0 02-27, v1.44.0 03-19, v1.45.0/1 04-07,
v1.45.2 05-04, v1.46.0 05-13, v1.47.0 05-27, v1.48.0 06-10, v1.48.1 06-11, v1.49.0 06-29, v1.50.0 07-07,
v1.51.0 07-27, v1.52.0 08-26, v1.52.1 08-27, v1.53.0 09-08. Minor releases every 2-3 weeks.

## 4. Timeline evidence of a release train (v1.53.0, 2026-09-08)

| Time (UTC) | Event | Evidence |
|---|---|---|
| 13:33 | lago-api `591ae90` committed (tag v1.53.0) | `git -C "$API" log -1 --format=%cI` (pinned checkout) |
| 14:00 | lago-front `0c5e539` committed (tag v1.53.0) | same, `$FRONT` |
| 14:24 | `getlago/api:v1.53.0` pushed | Docker Hub `last_updated` |
| 14:27 | `getlago/front:v1.53.0` pushed | Docker Hub |
| 14:31 | umbrella bump `ba292b6` (#792), tag v1.53.0 | history clone; `git ls-remote` |
| 14:36 | `getlago/lago-events-processor:v1.53.0` + `latest` pushed | Docker Hub |
| 15:04 / 15:20 | `b267320` Node 20->24, `f719ef1` Ruby 4.0.2->4.0.6 on main (not in the tag) | history clone |
| 15:26 | `getlago/lago:v1.53.0` + `latest` pushed | Docker Hub (digest `sha256:ba58a030e828…` = `latest`) |

## 5. Pattern: release-day fix, then the all-in-one rebuilt from a non-tag ref

For 8 releases the `getlago/lago:vX` push happened minutes after a fix commit that the tag does NOT
contain (`git -C "$H" merge-base --is-ancestor <fix> <tag-commit>` fails for each):

| Release | Tag commit | Fix (not in tag) | Fix committed | `getlago/lago:vX` pushed |
|---|---|---|---|---|
| v1.21.0 | `cc70c2e` | `c91af2b` checkout `submodules: true` (after `023bfe1` `needs:` fix) | 2025-02-12 16:44Z | 16:54Z |
| v1.27.1 | `ea6af69` | `e07e182` Ruby 3.4.3, `d0099a9` libyaml-dev | 2025-05-13 10:38Z | 10:47Z |
| v1.28.1 | `eff552f` | `92b1af2` encryption keys in runner.sh | 2025-05-16 13:35Z | 13:42Z |
| v1.33.3 | `35d1030` | `b6b98c8` postgresql-15 -> 17 | 2025-09-15 13:41Z | 14:06Z |
| v1.35.0 | `218c9c9` | `18b26d0` drop `pnpm prune --prod`, add `.dockerignore` | 2025-10-30 16:11Z | 16:20Z |
| v1.37.0 | `9faa659` | `c6abc1e` runner labels (`5439dd5` for the EP image) | 2025-12-11 08:58Z | 09:03Z |
| v1.45.0 | `074fc9a` | `558814a` `bundle config set without` | 2026-04-07 09:25Z | 09:32Z |
| v1.53.0 | `ba292b6` | `b267320` + `f719ef1` Node/Ruby | 2026-09-08 15:20Z | 15:26Z |

Inference (UNVERIFIED: Actions logs are invisible here): the `released`-event build failed, the fix
landed on `main`, and someone ran `release-docker-image.yml` by `workflow_dispatch` from `main` with
`version=vX`. Consequence: these 8 images were built from `main` at dispatch time, not from the tag
tree. They match the tag only while `main`'s gitlinks equal the tag's (check with
`release-pin-audit.sh --candidate origin/main vX`). v1.45.1 was additionally cut as a proper patch.

## 6. Missing `getlago/lago` tags (Docker Hub, re-verified 2026-10-01)

`artifact-verify.sh --sweep --from v1.21.0 --no-ghcr` (the first `getlago/lago` tag is v1.21.0; `docker/Dockerfile`
was added by `52ab3b3` on the same day, after the v1.21.0 tag commit `cc70c2e`):

| Missing | Explanation | Status |
|---|---|---|
| v1.33.0, v1.33.1, v1.33.2 | `14fa1e0` (2025-08-19) bumped Ruby 3.4.4 -> 3.4.5. `ruby:3.4.4-slim` == `-bookworm` but `ruby:3.4.5-slim` == `-trixie` (Docker Hub digests), and trixie has no `postgresql-15`; the PGDG apt line is broken. Fixed by `b6b98c8`; v1.33.3 was the next published tag. | explanation inferred from digests + timestamps |
| v1.48.0, v1.49.0, v1.50.0 | NOT explained by pins: Ruby 4.0.2 / Bundler 4.0.4 / front Node 24.16-24.18 / pnpm 10.34.x were the same for v1.48.1 and v1.51.0, which were published. `docker/Dockerfile` did not change between `558814a` (2026-04-07) and `b267320` (2026-09-08). `lago-events-processor`, `api` and `front` exist for all three, so the `released` event did fire. | root cause UNVERIFIED (needs Actions logs); nobody backfilled |

Other gaps from the same sweep: `getlago/lago-events-processor:v1.41.2` missing (404);
`getlago/front:v1.41.1..v1.41.3` missing (lago-front never tagged them). GHCR starts at v1.44.0
(the v1.43.0 tag tree has no `release-images.yml`: `workflows.md`, `release-images.yml` section).

## 7. Maintenance release precedent: v1.40.1

- `8c83bd2` (2026-02-19, Andrew Kozin) "chore(release): bump version to v1.40.1": parent `147b47e`
  (the v1.40.0 merge, #681); changes `api` (-> lago-api v1.40.1 `7da1940`) and `docker-compose.yml`.
  front stays `0491322`, which lago-front tagged as both v1.40.0 and v1.40.1.
- The tag commit is not on `main` (off-main). v1.42.0 (2026-02-17) was already out.
- Docker Hub: `getlago/lago:v1.40.1` pushed 2026-02-19T11:22Z, `lago-events-processor:v1.40.1` 11:19Z.
  Both release workflows push `latest` unconditionally, so `latest` very likely pointed at v1.40.1
  until v1.43.0 (2026-02-27). Historical digests cannot be checked: inferred, not verified.

## 8. `latest` today (verified 2026-10-01)

| Image | `latest` | Note |
|---|---|---|
| `getlago/lago` | digest == v1.53.0 | moved by every release / dispatch |
| `getlago/lago-events-processor` | digest == v1.53.0 | same |
| `getlago/api` | does not exist (404) | lago-api pushes the exact tag only |
| `getlago/front` | exists, last pushed **2022-06-02** (single amd64) | stale relic; lago-front now uses `exact-tags-only` |
| GHCR `api`/`front`/`events-processor` | does not exist | tags `vX.Y.Z`, `X.Y`, `sha-<7>` |

## 9. Other getlago images on Docker Hub NOT built by this repo's workflows (as of 2026-10-01)

`getlago/connectors` (one tag `latest`, 2025-09-18), `getlago/events-processor` (one tag `alpha`,
2025-11-25), `getlago/lago-gotenberg` (`latest`, `8.15`, `8`, `7.10`, `7.8.2`, `7`; consumed as
`7.8.2` by `docker-compose.yml:338` and as `8` by `docker/runner.sh:57`), `getlago/postgres-partman` (`15.0-alpine`,
`latest`; consumed by `docker-compose.yml:7`). Their build source is UNVERIFIED (not in this repo's
history: `git -C "$H" log --all -S'getlago/connectors'` is empty). Do not confuse
`getlago/events-processor:alpha` with the released `getlago/lago-events-processor`.
