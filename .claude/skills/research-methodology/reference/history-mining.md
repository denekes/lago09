# History mining recipes (getlago/lago umbrella)

Read this when a question starts with "when / why / who / how often / was it ever", or when you need
the sha behind a rule. Every command ran on 2026-10-01. Setup (repo root):

```bash
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)     # bare, blob-less, full history
git -C "$H" rev-list --count HEAD                                    # 776 (fork remote)
```

Narratives of incidents and chains belong to the `failure-archaeology` skill. This file is the
**method**: the generic recipes live here, `failure-archaeology` keeps only its own gotchas.

Commands that contain a shell pipe are in fenced blocks, never in table cells: in a Markdown table a
pipe has to be written `\|`, and a shell that receives `\|` passes it on as a literal argument.

## 0. The shallow-clone trap (check first, every session)

| Check | Output here | Meaning |
|---|---|---|
| `git rev-parse --is-shallow-repository` | `true` | The working clone lacks history. |
| `git rev-list --count 5308258` | `57` (count the code commit: HEAD's count grows with every skills-only commit on the working branch) | vs 776 in `H` |
| `cat .git/shallow` | `8ceca4b…` | the history boundary (2026-05) |
| blame in the working clone (block below) | `^8ceca4b` (all 308 lines) | Blame in the shallow clone is useless. |
| `git -C "$H" blame -s -L 97,97 5308258 -- events-processor/config/kafka/consumer.go` | `9acd83e8 97) // Skip the commit; …` | Use `H` for blame. |

```bash
git blame -s events-processor/config/kafka/consumer.go | awk '{print $1}' | sort -u    # ^8ceca4b only
```

Never conclude "this never happened" or "nobody touched this" from the working clone. Never deepen
the working clone (no `git fetch --unshallow` in the repo; change-control N10); use `H`.

## 1. Paths that moved: rename-aware pathspecs

The service lived in `events_processor/` until `d5bce86` (2025-03-21).

```bash
git -C "$H" log --format=%h -- events-processor | wc -l                                   # 88
git -C "$H" log --format=%h -- events-processor events_processor | wc -l                  # 96
git -C "$H" log --format='%h %ad %s' --date=short -- events-processor/main.go | tail -1    # d5bce86 2025-03-21 misc: Align go module name…
git -C "$H" log --follow --format='%h %ad %s' --date=short -- events-processor/main.go | tail -1   # 4100da0 2025-03-11 feat(events): Add events post-processor (#474)
```

- `git log --follow` works for one file only. For directories, list both names.
- `git -C "$H" log --follow --reverse --format=%h -- events-processor/main.go` prints a single commit (10 without `--reverse`). Reverse with `| tac` instead.
- At commits before `d5bce86`, `git show <sha>:<path>` and `git ls-tree` need the old path: `git -C "$H" show 4100da0:events_processor/main.go` works; `4100da0:events-processor/main.go` exits 128.
- Other moves: `.env.development.example` became `.env.development.default` in `84b6eef`.

## 2. Pickaxe: `-S` (occurrence count changed) vs `-G` (a diff line matches a regex)

| Question | Command | Output |
|---|---|---|
| When did a literal enter or leave? | `git -C "$H" log -S'subscription_refreshed_v2' --format='%h %ad %s' --date=short` | `42615c9 2026-03-27 fix(subscription): Fix flagging for refresh (#720)` |
| When did a typo get fixed? | `git -C "$H" log -S'events_processors' --format='%h %ad %s' --date=short -- docker-compose.dev.yml` | `aecb8be` (#482), `4100da0` |
| A value set or cleared (regex), across a rename | `git -C "$H" log -G'^LAGO_LICENSE=.' --format='%h %ad %s' --date=short -- .env.development.default .env.development.example` | `6dd7e56` (removed), `16c8b68` (added). Count lines, never print the value (change-control N11). |
| Every commit that touched the expanded topic env | `git -C "$H" log -G'LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC' --format='%h %ad %s' --date=short -- events-processor` | `d9c32b6`, `264beb5`, `9a64eb2`, `3dae52f` |

`-S` misses edits that keep the count (moving a line). `-G` catches them. Both need blobs, so the first
run fetches lazily (network). `history-setup.sh` disables auto-maintenance in `H`; without that, every
lazy fetch prints "Auto packing the repository in background…".

## 3. Function and fix-chain history

```bash
git -C "$H" log -L ':processRecordsAndCommit:events-processor/config/kafka/consumer.go' --format='%h %ad %s' --date=short -s
```
Output: `9acd83e` (#735), `475761d` (#633), `b6d3616` (#608), `600e195` (#628).

The function only exists since `600e195`, so `-L` misses the chain's start. Widen with `-G` on the file
under both names:
```bash
git -C "$H" log -G'return' --format='%h %ad %s' --date=short -- events-processor/config/kafka/consumer.go events_processor/config/kafka/consumer.go
```
Output: `9acd83e`, `b6d3616`, `b604769`, `600e195`, `cec0eb2`, `4100da0`. That is the full commit-path
chain (13 months).

Then read each step: `git -C "$H" show --stat <sha>`, then `git -C "$H" show <sha> -- <file>`.

Deleted files: `git -C "$H" log --diff-filter=D --format='%h %ad %s' --date=short -- 'events-processor/models/flat_filters*.go'`
gives `d9c32b6`.

Removals here are forward commits, not `git revert`: `git -C "$H" log -i --grep=revert --format=%h -- events-processor events_processor`
gives nothing. Search removals with `--diff-filter=D`, `-S` or `-G`, never with `--grep=revert`.

## 4. Tags (the default history clone has none)

- `git -C "$H" tag | wc -l` gives 0, because `H` is cloned from the fork remote. The fork has 0 tags; upstream has 195.
- Map tags with `.claude/skills/research-methodology/scripts/tag-map.sh` (`git ls-remote`).
- Distance from a tag: `git -C "$H" rev-list --count ba292b6..5308258` gives 10 (v1.53.0 to the fork HEAD).
- On or off main: `git -C "$H" merge-base --is-ancestor <full-sha> HEAD`. `tag-map.sh --gitlinks` prints `off-main` for `v1.40.1` (`8c83bd2`).
- A full sha that is missing locally is fetched lazily from the promisor remote. GitHub forks share objects, so even upstream-only commits resolve: `git -C "$H" log -1 a0de065beab237f357f033c6aa92058ebd417d5c` works. A short sha (`a0de065`) fails with "unknown revision" until that commit has been fetched once by its full sha; after that it resolves locally.
- For a tag-complete clone, use a separate cache. `LAGO_SKILLS_CACHE=<dir> .claude/skills/research-methodology/scripts/history-setup.sh --remote https://github.com/getlago/lago` gives 778 commits and 195 tags. With an existing cache, `--remote` is ignored with a warning.

## 5. PR numbers, merge style, tickets

```bash
# squash merges carry (#NNN): 216 of 293 non-merge commits since 2025
git -C "$H" log --since=2025-01-01 --no-merges --format=%s | grep -cE '\(#[0-9]+\)$'    # 216
# true merge commits: 48 since 2025, e.g. "Merge pull request #782 from getlago/misc-v-52-0"
git -C "$H" log --merges --since=2025-01-01 --format=%s | head -2
# PR number to sha
git -C "$H" log --format='%h %s' | grep -E '\(#797\)$'          # d9c32b6 misc(events-processor): Remove flat filters…
# ticket ids (private tracker)
git -C "$H" log --format='%s%n%b' | grep -oE '\b(ING|INF)-[0-9]+' | sort -u   # INF-366 INF-395 ING-123 ING-143 ING-15 ING-543
```

- PR pages are not reachable from this session: `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/getlago/lago/pulls/797` gives 403 (see `registry-probing.md`).
- For squash merges, the commit body is the PR description: `git -C "$H" show -s d9c32b6`.
- Ticket contents are invisible. A ticket id is a pointer, not evidence: ING-15 appears only as `Refs: ING-15` in `9acd83e`'s body (`git -C "$H" log --format=%h --grep='ING-15\b'`).

## 6. People and bus factor (route questions, do not over-personalize)

```bash
git -C "$H" log --no-merges --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -3
git -C "$H" log --since=2025-01-01 --no-merges --format=%an -- .github | sort | uniq -c | sort -rn | head -3
```
Output, as of 2026-10-01:
<!-- evidence-check: off (outputs of the two commands above) -->
- `events-processor/`: one author has 55 of 72 non-dependabot commits (62 of 79 with `events_processor/`). That is the bus factor.
- `.github/` since 2025: the top three authors have 12, 8 and 8 commits.
<!-- evidence-check: on -->

Name people only in an owner-question routing line. Facts cite shas, not names.

## 7. Upstream and fork drift

```bash
git ls-remote https://github.com/getlago/lago refs/heads/main      # a0de065… (fork HEAD is 5308258)
U=$(mktemp -d)/up.git && git clone -q --bare --filter=blob:none --shallow-since=2026-09-01 https://github.com/getlago/lago "$U"
git -C "$U" log --format='%h %ad %s' --date=short 5308258..main
```
Output: `a0de065 2026-09-29 misc(deploy): add LAGO_WEBHOOK_ALLOW_PRIVATE_URLS (#810)` and
`6dcdb62 2026-09-22 fix(connectors): Add missing fields on each connector (#806)`.

Re-check any finding about the files those commits touch before you say "still true upstream".

## 8. Author date vs commit date

- `%ad` is the author date and `%cd` the committer date: `git -C "$H" log -1 --format='%ad | %cd' --date=iso 5308258` gives `2026-09-18 11:21:36 +0200 | 2026-09-18 14:37:02 +0200`.
- Rebases and squash merges set the committer date to the landing time, as with `5308258` (authored 11:21, landed 14:37). Use `%cd` for "when did it land on main", for example when comparing with an image's `last_updated`.
- Use `%ad` for "when was it written" (`git log --format=%ad`).
- A commit body written before the merge can describe a state that changed in between (lago-api `6341824` vs this repo's `d9c32b6`: worked-examples Example E).
