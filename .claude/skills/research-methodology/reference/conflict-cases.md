# Conflict cases: two sources disagree -> which wins, and how you know

Read this when a doc, a report, a comment, a commit message or a previous skill contradicts another
source or your own run. Every case below was re-run on 2026-10-01. Setup:
`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`,
`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.

## Resolution rules (apply in order)

<!-- evidence-check: off (normative rules; each case below carries its evidence) -->
| # | Rule | Typical case |
|---|---|---|
| 1 | **Pin the claim's scope first.** State the path set, time window, repo and sha, mode (DB vs memory cache), and tool version. Many "conflicts" are two true statements about different scopes. | X4 commit counts, X7 rename |
| 2 | **The stronger evidence class wins.** Order: a run or probe with output and exit status, then a code read at a stated sha, then a test assertion you did not run, then a commit or PR body, then a code comment, then docs, then summaries and memory. | Example C (comment vs code), D2 (doc vs code) |
| 3 | **Same class, different pins: both may be true.** Say "true at `591ae90`" and "changed upstream in `6341824`". Never merge the two into one present-tense sentence. | lago-api drift (worked-examples Example E) |
| 4 | **Count by data, not by text classifiers.** Subject regexes and keyword greps are hunch generators. | X5 pin moves |
| 5 | **A number needs its exit status and denominator.** A coverage figure from a command that exited 1 is not a baseline. | X6 coverage |
| 6 | **Line numbers drift.** Re-grep at HEAD and cite an anchor plus the line (`go.mod:10`, the expression-go require). | X8 |
| 7 | **Still unresolved?** Label both claims UNVERIFIED, write a hypothesis card for the discriminating probe, or route to the owner (OPEN DECISION OD-n via change-control). Never pick the more convenient one. | production questions, OD-1, OD-8 |
| 8 | **Record the resolution where the fact lives** (the owning skill or doc), not only in your PR or chat. | all |

<!-- evidence-check: on -->

## Cases between earlier analyses (all re-verified)

Case IDs (X, D, M, V) are local to this file. They are not change classes (C0–C7) and not
open decisions (OD-n).

| Case | Disagreement | Resolution and rule | Verification (command -> output, 2026-10-01) |
|---|---|---|---|
| X1 | One source: floats become exponent form at >= 1e21. Another: at >= 1e6. | Both thresholds exist in different mechanisms. `fmt %v` switches at 1e6, while `encoding/json` switches at 1e21. The value path uses `%v` (`events-processor/processors/events_processor/enrichment_service.go:114`), so 1e6 matters here (rule 1). | Go probe printing both: `%v=1e+06 json=1000000`, `%v=1e+20 json=100000000000000000000`, `%v=1e+21 json=1e+21` |
| X2 | "ClickHouse may not parse exponent strings" (speculation) vs a run. | The run wins (rule 2). Exponent strings parse; the real loss is >= 1e12 and `"<nil>"`. | worked-examples Example B (`clickhouse local` 25.8.2.29) |
| X3 | "Delivery is at-least-once with redelivery" vs "retryable failures are skipped". | The probe with a control wins (rule 2). At-least-once holds only if no later commit happens on the partition. The mechanism is the commit-prefix rule (`events-processor/config/kafka/consumer.go:94-100`). | worked-examples Example A: treatment `retryable-fail:1`, control `retryable-fail:2` |
| X4 | events-processor commits: 96 total / 79 human / 62 by the top author, vs 88 / 72 / 55. | Both are right (rule 1). The first scope adds the pre-rename dir `events_processor/`. | `git -C "$H" log --format=%an -- events-processor \| wc -l` gives 88; with `events_processor` added, 96. `grep -vc dependabot` gives 72 and 79. Top-author counts are 55 and 62. |
| X5 | Non-release pointer moves since 2025: 14 vs 15. | 15, by data (rule 4). Keyword filters disagree with each other: one that also drops subjects matching `version` throws out `7251947` ("chore(dev): Upgrade Clickhouse version (#749)"), a non-release move, as if it were a release. | worked-examples Example D gives `15`; subject filters give 20, 18, or 16 with `grep -viE 'release\|bump\|version'` (which drops `7251947`) |
| X6 | "Coverage 47.4%" from `go test -coverprofile ./...` vs "that command fails". | Both: it prints 47.4% **and exits 1** (rule 5). Use the tested-packages form. | `go test -count=1 -coverprofile=… ./...` gives exit=1, 5x `go: no such tool "covdata"`, total 47.4%. The `$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...)` form gives exit=0, 47.4% (run after `source .claude/skills/build-and-env/scripts/ep-env.sh`). |
| X7 | The `LAGO_LICENSE` value was introduced in `16c8b68` vs in `84b6eef`. | Same chain (rule 1). `16c8b68` added it to `.env.development.example`; `84b6eef` renamed that file to `.env.development.default` with 0 content change; `6dd7e56` removed it. Rotation is OPEN DECISION OD-9. **Never print the value** (change-control N11). | `git -C "$H" log --format='%h %ad %s' --date=short -G'^LAGO_LICENSE=.' -- .env.development.default .env.development.example` lists `6dd7e56`, `16c8b68`. `git -C "$H" show 16c8b68:.env.development.example \| grep -c '^LAGO_LICENSE=..*'` gives `1` (count only). `git -C "$H" show --stat 84b6eef` shows `.env.development.example => .env.development.default \| 0`. |
| X8 | The expression-go require is cited at `go.mod:9` and at `go.mod:10`. | `:10` (rule 6). Line 9 is badger. | `grep -n 'expression-go\|badger' events-processor/go.mod` gives `9: …badger/v4 v4.8.0`, `10: …expression-go v0.1.4` |

## Docs, comments and commit messages vs code

| Case | Claim (source) | Truth and how verified | Rule |
|---|---|---|---|
| D1 | "Direct `go build` / `go test` won't work locally … Always use `lago exec`" (`events-processor/CLAUDE.md:10`) | They work with the CGO env. Run `source .claude/skills/build-and-env/scripts/ep-env.sh`, then `go test` over the tested packages: exit 0. | rule 2: a run beats a doc |
| D2 | "set `LAGO_CLICKHOUSE_ENABLED=false`" disables ClickHouse (`docs/dev_environment.md:154`) | `ENV["LAGO_CLICKHOUSE_ENABLED"].present?` (`$API/app/services/events/stores/store_factory.rb:10`) treats `"false"` as enabled. Upstream lago-api main still uses `.present?` (same file at `b5500bc`). | rule 2; the fix belongs to the `docs-and-writing` stale-claim register |
| D3 | ZSET score is "the event timestamp" (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:11`) | Go scores with `time.Now().Unix()` (`events-processor/models/stores.go:55,61`) | rule 2: code beats comment (worked-examples Example C) |
| M1 | The private copy existed "specifically to keep ECR URLs and the AWS account id out of a public repository" (`5308258` message body) | `201661579678` is in `.github/workflows/build-processors-image.yaml:15` and `.github/workflows/build-connectors-image.yaml:19`, public since `2146a18` / `4955f79` (`git -C "$H" log -S'201661579678'`) | rule 2: code beats a commit body |
| M2 | "The events-processor still produces to the expanded topic" (lago-api `6341824` body, 2026-09-24) | `d9c32b6` (2026-09-18) removed that producer here | A commit message in repo X is not evidence about repo Y |
| M3 | "misc: Bump version to 7 (#679)" (`449bf5b`) reads like a release | The diff is `redis:6-alpine` -> `redis:7-alpine` in `docker-compose.yml` (`git -C "$H" show 449bf5b -- docker-compose.yml`) | Read the diff; a subject alone is not evidence |

## Cases where the brief or the environment moved under you

| Case | Stated | Observed 2026-10-01 | Lesson |
|---|---|---|---|
| V1 | The working clone has 57 commits at HEAD `5308258` | `git rev-list --count HEAD` gives 58. A skills commit `08065ef` now sits on top of `5308258`. | Volatile facts carry a date and a one-line re-check; the shallow boundary stays `8ceca4b` (`.git/shallow`) |
| V2 | "The history clone has no tags" | True for the default clone, which comes from the fork remote (`git ls-remote --tags https://github.com/denekes/lago09 \| wc -l` gives 0). A clone from `https://github.com/getlago/lago` has 195 tags and 778 commits. | The property belongs to the remote, not to git; say which remote |
| V3 | "HEAD is the latest code" | Upstream `getlago/lago` main is `a0de065` (2026-09-29), 2 commits past the fork: `6dcdb62` (#806, connectors) and `a0de065` (#810, deploy env). | Run `git ls-remote https://github.com/getlago/lago refs/heads/main` before you claim "still true upstream". `6dcdb62` does not change the numeric `precise_total_amount_cents` passthrough (`git -C "$H" show 6dcdb62a0271d3f2f8c950d2e944e7800fc9250a -- connectors/http.yml`: the full sha makes the blob-less clone fetch the upstream-only commit lazily). |
