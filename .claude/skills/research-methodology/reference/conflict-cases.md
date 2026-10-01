# Conflict cases: two sources disagree -> which wins, and how you know

Read this when a doc, a report, a comment, a commit message or a previous skill contradicts another
source or your own run. Every case below was re-run on 2026-10-01. Setup:
`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`,
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.

Commands that contain a shell pipe are kept out of the tables, in the fenced blocks under each table.
Copy those; in a Markdown table a pipe would have to be written `\|`, which the shell does not undo.

## Resolution rules (apply in order)

<!-- evidence-check: off (normative rules; each case below carries its evidence) -->
| # | Rule | Typical case |
|---|---|---|
| 1 | **Pin the claim's scope first.** State the path set, time window, repo and sha, mode (DB vs memory cache), and tool version. Many "conflicts" are two true statements about different scopes. | CC4 commit counts, CC7 rename |
| 2 | **The stronger evidence class wins.** Order: a run or probe with output and exit status, then a code read at a stated sha, then a test assertion you did not run, then a commit or PR body, then a code comment, then docs, then summaries and memory. | Example C (comment vs code), CD2 (doc vs code) |
| 3 | **Same class, different pins: both may be true.** Say "true at `591ae90`" and "changed upstream in `6341824`". Never merge the two into one present-tense sentence. | lago-api drift (worked-examples Example E) |
| 4 | **Count by data, not by text classifiers.** Subject regexes and keyword greps are hunch generators. | CC5 pin moves |
| 5 | **A number needs its exit status and denominator.** A coverage figure from a command that exited 1 is not a baseline. | CC6 coverage |
| 6 | **Line numbers drift.** Re-grep at HEAD and cite an anchor plus the line (`go.mod:10`, the expression-go require). | CC8 |
| 7 | **Still unresolved?** Label both claims UNVERIFIED, write a hypothesis card for the discriminating probe, or route to the owner (OPEN DECISION OD-n via change-control). Never pick the more convenient one. | production questions, OD-1, OD-8 |
| 8 | **Record the resolution where the fact lives** (the owning skill or doc), not only in your PR or chat. | all |

<!-- evidence-check: on -->

## Cases between earlier analyses (all re-verified)

Case IDs (CC, CD, CM, CV) are local to this skill; from another skill cite them as
`research-methodology CC4`. They are not failure-archaeology chains (X1-X13), architecture-contract
design decisions (D1-D21), change-control commit-msg rule ids (M1-M7), change classes (C0–C7) or
open decisions (OD-n).

| Case | Disagreement | Resolution and rule | Verification (command -> output, 2026-10-01) |
|---|---|---|---|
| CC1 | One source: floats become exponent form at >= 1e21. Another: at >= 1e6. | Both thresholds exist in different mechanisms. `fmt %v` switches at 1e6, while `encoding/json` switches at 1e21. The value path uses `%v` (`events-processor/processors/events_processor/enrichment_service.go:114`), so 1e6 matters here (rule 1). | Go probe printing both: `%v=1e+06 json=1000000`, `%v=1e+20 json=100000000000000000000`, `%v=1e+21 json=1e+21` |
| CC2 | "ClickHouse may not parse exponent strings" (speculation) vs a run. | The run wins (rule 2). Exponent strings parse; the real loss is >= 1e12 and `"<nil>"`. | worked-examples Example B (`clickhouse local` 25.8.2.29) |
| CC3 | "Delivery is at-least-once with redelivery" vs "retryable failures are skipped". | The probe with a control wins (rule 2). At-least-once holds only if no later commit happens on the partition. The mechanism is the commit-prefix rule (`events-processor/config/kafka/consumer.go:94-100`). | worked-examples Example A: treatment `retryable-fail:1`, control `retryable-fail:2` |
| CC4 | events-processor commits: 96 total / 79 human / 62 by the top author, vs 88 / 72 / 55. | Both are right (rule 1). The first scope adds the pre-rename dir `events_processor/`. | `git -C "$H" log --format=%h -- events-processor` lists 88, 96 with `events_processor` added; 72 and 79 without dependabot; top author 55 and 62 (block CC4 below) |
| CC5 | Non-release pointer moves since 2025: 14 vs 15. | 15, by data (rule 4). Keyword filters disagree with each other: one that also drops subjects matching `version` throws out `7251947` ("chore(dev): Upgrade Clickhouse version (#749)"), a non-release move, as if it were a release. | worked-examples Example D gives `15`; the subject filters in block CC5 below give 20, 18 and 16 (the last drops `7251947`) |
| CC6 | "Coverage 47.4%" from `go test -coverprofile ./...` vs "that command fails". | Both: it prints 47.4% **and exits 1** (rule 5). Use the tested-packages form; that is the gated figure (`validation-and-qa` `baseline.sh`, `cover.total`). Other denominators (`-coverpkg` 44.9%, whole-module 42.0%; measured in `validation-and-qa`) are informational and must be labelled so. | `go test -count=1 -coverprofile=… ./...` gives exit=1, 5x `go: no such tool "covdata"`, total 47.4%. The `$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...)` form gives exit=0, 47.4% (run in `events-processor/` after `source .claude/skills/build-and-env/scripts/ep-env.sh`). |
| CC7 | The `LAGO_LICENSE` value was introduced in `16c8b68` vs in `84b6eef`. | Same chain (rule 1). `16c8b68` (2025-01-23) added it to `.env.development.example`; `84b6eef` renamed that file to `.env.development.default` with 0 content change; `6dd7e56` (2025-03-07) removed it. Exposure: 37 days on main (merge `0a67ac0` 2025-01-29 -> `6dd7e56`); up to 43 days if the feature branch was public from 2025-01-23 (UNVERIFIED). Rotation is OPEN DECISION OD-9. **Never print the value** (change-control N11). | block CC7 below: `-G` lists `6dd7e56`, `16c8b68`; the count is `1`; the rename has 0 changed lines |
| CC8 | The expression-go require is cited at `go.mod:9` and at `go.mod:10`. | `:10` (rule 6). Line 9 is badger. | `grep -n -e expression-go -e badger events-processor/go.mod` gives `9: …badger/v4 v4.8.0`, `10: …expression-go v0.1.4` |

```bash
# CC4: commit counts by scope (rename-aware vs not)
git -C "$H" log --format=%h -- events-processor | wc -l                                   # 88
git -C "$H" log --format=%h -- events-processor events_processor | wc -l                  # 96
git -C "$H" log --format=%an -- events-processor | grep -vc dependabot                    # 72
git -C "$H" log --format=%an -- events-processor events_processor | grep -vc dependabot   # 79
git -C "$H" log --no-merges --format=%an -- events-processor | grep -v dependabot | sort | uniq -c | sort -rn | head -1   # 55 (62 with events_processor)

# CC5: subject filters (hunch generators); Example D's data count is 15
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | grep -viE 'release|bump' | wc -l             # 20
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | grep -viE 'release|bump|v1\.[0-9]+' | wc -l   # 18
git -C "$H" log --since=2025-01-01 --format='%h %s' -- api front | grep -viE 'release|bump|version' | wc -l     # 16, drops 7251947

# CC7: the LAGO_LICENSE chain; count lines, never print the value (change-control N11)
git -C "$H" log --format='%h %ad %s' --date=short -G'^LAGO_LICENSE=.' -- .env.development.default .env.development.example   # 6dd7e56, 16c8b68
git -C "$H" show 16c8b68:.env.development.example | grep -c '^LAGO_LICENSE=..*'     # 1
git -C "$H" show --stat --format= 84b6eef      # .env.development.example => .env.development.default | 0
```

## Docs, comments and commit messages vs code

| Case | Claim (source) | Truth and how verified | Rule |
|---|---|---|---|
| CD1 | "Direct `go build` / `go test` won't work locally … Always use `lago exec`" (`events-processor/CLAUDE.md:10`) | They work with the CGO env. Run `source .claude/skills/build-and-env/scripts/ep-env.sh`, then `go test` over the tested packages: exit 0. | rule 2: a run beats a doc |
| CD2 | "set `LAGO_CLICKHOUSE_ENABLED=false`" disables ClickHouse (`docs/dev_environment.md:154`) | MIXED, not "off" (the full site list is in `config-and-flags`). `ENV["LAGO_CLICKHOUSE_ENABLED"].present?` (`$API/app/services/events/stores/store_factory.rb:10`) treats `"false"` as enabled; org creation casts it to a boolean (`$API/app/services/organizations/create_service.rb:17`) and treats it as disabled. Upstream lago-api main still uses `.present?` in the store factory (same file at `b5500bc`). | rule 2; the doc fix belongs to the `docs-and-writing` stale-claim register |
| CD3 | ZSET score is "the event timestamp" (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11`) | Go scores with `time.Now().Unix()` (`events-processor/models/stores.go:55,61`) | rule 2: code beats comment (worked-examples Example C) |
| CM1 | The private copy existed "specifically to keep ECR URLs and the AWS account id out of a public repository" (`5308258` message body) | The account id is in the ECR `image-name` at `.github/workflows/build-processors-image.yaml:15` and `.github/workflows/build-connectors-image.yaml:19`, public since `2146a18` / `4955f79` (pickaxe on the literal, without printing it: `git -C "$H" log -S"$(grep -oE '[0-9]{12}' .github/workflows/build-processors-image.yaml)" --format=%h`). Whether it may stay public is OPEN DECISION OD-18. | rule 2: code beats a commit body |
| CM2 | "The events-processor still produces to the expanded topic" (lago-api `6341824` body, 2026-09-24) | `d9c32b6` (2026-09-18) removed that producer here | A commit message in repo X is not evidence about repo Y |
| CM3 | "misc: Bump version to 7 (#679)" (`449bf5b`) reads like a release | The diff is `redis:6-alpine` -> `redis:7-alpine` in `docker-compose.yml` (`git -C "$H" show 449bf5b -- docker-compose.yml`) | Read the diff; a subject alone is not evidence |

## Cases where the brief or the environment moved under you

| Case | Stated | Observed 2026-10-01 | Lesson |
|---|---|---|---|
| CV1 | The working clone has 57 commits at HEAD `5308258` | `git rev-list --count HEAD` grows with every skills-only commit on the working branch (63 when checked on 2026-10-01). Count the code commit instead: `git rev-list --count 5308258` gives 57. | Anchor volatile facts to a sha, not to HEAD, and give them a date and a one-line re-check; the shallow boundary stays `8ceca4b` (`.git/shallow`) |
| CV2 | "The history clone has no tags" | True for the default clone, which comes from the fork remote (`git ls-remote --tags https://github.com/denekes/lago09` prints nothing). A clone from `https://github.com/getlago/lago` has 195 tags and 778 commits. | The property belongs to the remote, not to git; say which remote |
| CV3 | "HEAD is the latest code" | Upstream `getlago/lago` main is `a0de065` (2026-09-29), 2 commits past the fork: `6dcdb62` (#806, connectors) and `a0de065` (#810, deploy env). The gitlinks are identical. | Run `git ls-remote https://github.com/getlago/lago refs/heads/main` before you claim "still true upstream". `6dcdb62` does not change the numeric `precise_total_amount_cents` passthrough (`git -C "$H" show 6dcdb62a0271d3f2f8c950d2e944e7800fc9250a -- connectors/http.yml`: the full sha makes the blob-less clone fetch the upstream-only commit lazily). |
