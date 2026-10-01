# Commit and PR conventions: stated, practised, and what we operate under

Read this when a commit-msg check fails, when you write a PR title or body, or when someone
cites CONTRIBUTING.md or AGENTS.md against you. Measured on 2026-10-01 over the full-history
clone, from 2025-01-01 to `5308258`. Re-measure with the commands at the bottom.

## 1. What the three sources say (they disagree)

| Topic | `CONTRIBUTING.md` | `PULL_REQUEST_TEMPLATE.md` | `$API/AGENTS.md` (lago-api, pinned) |
|---|---|---|---|
| Format | Conventional Commits (`:173`) | "descriptive commit message with a short title" (`:10`) | Conventional Commits, `<type>[optional scope]: <description>` (`:32-35`) |
| Types | not listed | n/a | feat fix docs style refactor test chore perf ci build revert **misc** (`:47`) |
| Subject length | **<= 72** (`:170`) | n/a | **<= 50** (`:52`) |
| Mood | present tense, imperative (`:168-169`) | n/a | imperative (`:49,53`) |
| Body | "Reference issues and pull requests liberally after the first line" (`:171`) | n/a | `## Context` / `## Description` sections (`:37-43`): the why and what, not the how (`:54-57`) |
| Docs-only | `[ci skip]` in the title (`:172`) | n/a | n/a |
| Branch | n/a | MUST start with `fix/` or `feature/` (`:8`) | n/a |
| Commits per PR | n/a | exactly one, squash (`:12`) | n/a |
| Tests | n/a | `pnpm test` passes (`:14`) | rspec in the container (`:8`) |
| PR body | n/a | descriptive title, describe changes, `closes #XXXX`, labels (`:18-24`) | lago-api's own template: Roadmap Task / Context / Description (`$API/PULL_REQUEST_TEMPLATE.md`) |

Three of these do not apply to this umbrella repo:

- `pnpm test`: the repo has no `package.json`. `git ls-files | grep -c package.json` prints 0.
- The 50-character rule: it lives in lago-api's AGENTS.md, which is scoped to `app/**/*.rb`
  by its front-matter (`$API/AGENTS.md:1-5`).
- `[ci skip]`: no PR check runs for docs-only changes anyway.

## 2. What history actually does (since 2025-01-01)

| Measure | Value | How measured |
|---|---|---|
| Non-merge commits / merge commits | 293 / 48 | `git -C "$H" log --no-merges --since=2025-01-01` / `--merges` |
| Subjects > 72 chars | **29** (23 without the 17 dependabot commits) | `commit-msg-check.sh -C "$H" --since 2025-01-01 --report` |
| Subjects > 50 chars | **142** (125 without dependabot) | same |
| Same, after stripping the ` (#NNN)` squash suffix | > 72: 11; > 50: 110 | `sed -E 's/ \(#[0-9]+\)$//'` then count |
| Conventional-Commits form | 258 of 293 (88%); 211 of those carry a scope | same tool, `non-conventional: 35` |
| Types | chore 74, **misc 69**, fix 55, feat 43, release 8, docs 3, ci 2, test 1, hotfix 1, doc 1, bug 1 | `TYPES` line of the same tool |
| `misc` all-time | 279 subjects | `git -C "$H" log --format=%s \| grep -cE '^misc(\([^)]*\))?: '` |
| Squash merges `(#NNN)` | 216 of 293 non-merge subjects (74%) | `grep -cE '\(#[0-9]+\)$'` |
| First-parent commits with no PR number | 24 (all CI, image, dev-env or docs changes; e.g. `4955f79`, `5ee8e98`, `8cff5c1`, `5308258`) | `git -C "$H" log --first-parent --no-merges --since=2025-01-01 --format='%h %s' \| grep -vE '\(#[0-9]+\)$'`. Rebase-merge vs direct push is UNVERIFIED (no GitHub API here) |
| Branch prefixes in the 48 merge subjects | misc 13, chore 6, release 4, bump 4, feat 3, data 3, others 1-2; **0 `fix/`, 0 `feature/`** | `grep -oE 'from [^ ]+'` on merge subjects |
| Empty commit bodies | 187 of 293 (64%) | loop over `%b` |
| Bodies with `## Context` | 18 | same loop |
| `Co-authored-by` trailers | 28 (4 of them Claude) | same loop |
| `[ci skip]` | 1 subject in all history | `git -C "$H" log --format=%s \| grep -c '\[ci skip\]'` |

Ticket references (Linear):

- **Subject prefix.** `[ING-123] fix(...)`: `9ef876a`, `3ac94a2`, `0b56915`.
- **Body trailer.** `Refs: ING-15` (`9acd83e`), or Linear URLs such as
  `Refs: https://linear.app/getlago/issue/INF-395` and `.../INF-366` (`2146a18`, `76159bd`).
- **Prose mention.** "Part of the arm64 image-coverage audit in INF-366." (`5070e24`,
  `4955f79`; no `Refs:` trailer).
- By these samples, ING tickets are ingestion-correctness fixes in the events-processor and INF
  tickets are infra (arm64 image-coverage audit INF-366; a CI build for the connectors image
  INF-395).

Release subjects:

- The most common form is `chore(release): bump version to vX.Y.Z (#NNN)`, used by 19 of the 60
  release bumps since 2025-01-01.
- There are at least 6 other spellings: `release: Bump to vX`, `misc(version): Bump version
  to X`, `Bump version to vX`, and others.
- The v1.53.0 bump itself is `Bump version to v1.53.0 (#792)` (`ba292b6`).
- Some subjects are typos or misleading: `chore(releasae)` (`ba596c0`); `misc: Bump version
  to 7` (`449bf5b`), which is actually a Redis 6->7 change.
- Subjects are therefore not a reliable release marker. Use the diff (`api`, `front`, compose
  tags), see `release-and-images`.

Good commit bodies to imitate. They state symptom, root cause and fix:

| Commit | Shows |
|---|---|
| `9acd83e` | incident fix with root cause, `Refs: ING-15` |
| `02a4bc8` | Context / Description |
| `d9c32b6` | removal rationale |
| `12b8101`, `647de3e` | Context / Description |
| `d589940` | quotes the failing build output |

## 3. What we operate under (OPEN DECISION OD-7 (owner); these are the defaults until decided)

1. **Subject format.** `[ING-n] `? `type(scope)!?: description`, in the imperative, with no
   trailing period.
   - type is one of feat fix docs style refactor test chore perf ci build revert misc.
     `misc` is sanctioned de facto.
   - scope is the area: `events-processor`, `docker`, `ci`, `deps`, `release`, `docs`,
     `skills`, ...
2. **Length.** <= 72 characters hard, <= 50 preferred, measured on the subject **as it lands on
   main**.
   - GitHub appends ` (#NNNN)` when squashing, so keep PR titles <= 64 characters.
   - `commit-msg-check.sh` enforces M1 (FAIL > 72) and M2 (WARN > 50).
3. **Never on main.** WIP, `fixup!` and `squash!` subjects (M6).
4. **Body required for C3, C4, C5-pin, C7 and any incident fix.** This is a change-control rule,
   stricter than practice; `$API/AGENTS.md:30-44` asks for it on every commit.
   - Use `## Context` (symptom, why now, ticket) and `## Description` (what changed, what did
     not).
   - Add `Refs: ING-n` or a Linear URL.
   - Add `Co-authored-by:` when an agent wrote it.
5. **Branch names.** Not enforced. History uses neither `fix/` nor `feature/`. Use something
   descriptive.
6. **Merging.** Squash merge is the norm, so the PR title becomes the main-line subject: apply
   rules 1-3 to the PR title.
   - Fix review feedback with new commits, never a force-push (change-control N2).
7. **PR body.**
   - Class (C0-C7).
   - Context, Description.
   - The evidence block for the class (`change-classes.md`).
   - WARN explanations from `precommit-guard.sh`.
   - For C4: deploy order, rollback, and a link to the paired lago-api PR.
   - The full template is in `docs-and-writing`.
8. **Not applicable here.** `pnpm test` and `[ci skip]` from the umbrella templates. Do not
   cite them as gates.

Open points for the owner, all under OD-7:

- Adopt 72 or 50 as the hard limit?
- Make `release` an allowed type, or standardise on `chore(release)`?
- Should branch naming be enforced?
- Should `PULL_REQUEST_TEMPLATE.md` be rewritten for the umbrella repo? That is a C0 change.

## 4. Re-measure

```bash
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)
.claude/skills/change-control/scripts/commit-msg-check.sh -C "$H" --since 2025-01-01 --report
# expected (as of 2026-10-01, history HEAD 5308258):
# SUMMARY commit-msg-check: 293 subjects; >72: 29; >50: 142; non-conventional: 35; unknown type: 11; WIP/fixup: 0; FAIL subjects: 73; WARN-only subjects: 108; bot-authored included: 17
# TYPES chore=74 misc=69 fix=55 feat=43 <non-conventional>=35 release=8 docs=3 ci=2 ...
.claude/skills/change-control/scripts/commit-msg-check.sh -C "$H" --since 2025-01-01 --report --exclude-bots
# expected: 276 subjects; >72: 23; >50: 125
```
