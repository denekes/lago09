# Secrets in history and in workflows

Read this before you inspect a historical secret, answer "was X ever committed", touch a workflow
that uses credentials, or review OIDC/permissions changes. Facts checked 2026-10-01 in the full
history clone (`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`, 776 commits on
`main`, `5e9b9bb`..`5308258`).

## 1. Safe-inspection protocol (change-control N11)

Never print a value. Not in a terminal you paste from, not in a PR, not in a skill.

| You want to know | Do this (prints no value) | Do NOT do this |
|---|---|---|
| Which commits touched KEY | `git -C "$H" log --format='%h %ad %s' --date=short -G'KEY=' HEAD` | `git show <sha>` on an env file |
| Whether a line was a real value | `scripts/secret-defaults-scan.sh --history` (class EMPTY/INTERPOLATION/PLACEHOLDER/LITERAL) | `git log -p \| grep KEY` |
| Whether two commits hold the same value | compare in-shell: `a=$(...); b=$(...); [ "$a" = "$b" ] && echo SAME \|\| echo DIFFERENT` | echo either variable |
| How many commits match a credential pattern | `git -C "$H" log --format=%h -G'<regex>' HEAD \| wc -l` | `git log -G... -p` |
| Show a diff around a secret | `git -C "$H" show <sha> \| sed -E 's/(KEY[=:]).*/\1<redacted>/'` | unredacted `git show` |

Pattern counts on 2026-10-01 (all 0 unless noted; `-G` uses extended regex):

```bash
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)
for pat in 'AKIA[0-9A-Z]{16}' 'BEGIN [A-Z ]*PRIVATE KEY' 'ghp_[A-Za-z0-9]{36}' 'xox[baprs]-[A-Za-z0-9-]{10,}' \
           'sk_live_[A-Za-z0-9]{10,}' 'hooks\.slack\.com/services/' '[0-9]{12}\.dkr\.ecr'; do
  printf '%4s commits  %s\n' "$(git -C "$H" log --format=%h -G"$pat" HEAD | wc -l)" "$pat"; done
# AKIA/PRIVATE KEY/ghp_/xox/sk_live/slack: 0 each; '[0-9]{12}\.dkr\.ecr': 2 (2146a18, 4955f79; section 3)
```

No `.env`, `*.pem`, `*.key`, `*.p12` or `id_rsa*` file was ever added (`git log --diff-filter=A -- '.env' '*/.env' '*.pem' '*.key' '*.p12' '*.pfx' 'id_rsa*'` is empty).

## 2. `LAGO_LICENSE` (OPEN DECISION OD-9, owner)

| Date | Commit | What happened (no value shown) |
|---|---|---|
| 2025-01-23 | `16c8b68` | "refactor env variable to .env file for dev": a real licence value is added to `.env.development.example` (class LITERAL) |
| 2025-01-23 | `84b6eef` | same day, the file is renamed to `.env.development.default` (R100 rename, same value carried over). Both commits sit on branch `feat/improv-dev-env` |
| 2025-01-29 | `0a67ac0` (#455) | "Merge pull request #455 from getlago/feat/improv-dev-env": the value reaches `main` (`git -C "$H" log --ancestry-path --merges --format='%h %cd' --date=short 84b6eef..HEAD \| tail -1`) |
| 2025-03-07 | `6dd7e56` (#477) | "remove unintended lago license key": the line becomes `LAGO_LICENSE=` (class EMPTY). The removed value equals the one added in `16c8b68` (compared in-shell, SAME) |

The SAME check, runnable (prints only `SAME`/`DIFFERENT`; VERIFIED 2026-10-01 -> `SAME`):

```bash
H=$(.claude/skills/research-methodology/scripts/history-setup.sh)
getv(){ git -C "$H" show --format= "$1" -- .env.development.example .env.development.default \
          | grep "^$2LAGO_LICENSE=" | sed 's/^.LAGO_LICENSE=//'; }
a=$(getv 16c8b68 +); b=$(getv 6dd7e56 -); [ "$a" = "$b" ] && echo SAME || echo DIFFERENT; unset a b
```

- On `main` for 37 days (2025-01-29 `0a67ac0` -> 2025-03-07 `6dd7e56`). The feature branch lived in
  the public repository and may have been visible from 2025-01-23 (43 days); its push date is
  UNVERIFIED (not recorded in git). Still readable in history today.
- Rotation: UNVERIFIED. OD-9 asks the owner for a rotation record (date only).
- Treat as leaked until the owner confirms rotation. History rewriting is forbidden
  (change-control N2) and would not help: forks and clones keep the value.
- `16eb537` (2025-01-28) / `a41c6dc` (2025-02-13) added and removed `LAGO_LICENSE_URL`, a URL, not
  a secret. Do not confuse the two keys.
- Expected scanner output: `secret-defaults-scan.sh --history` prints exactly two LITERAL rows,
  `16c8b68 .env.development.example LAGO_LICENSE` and `84b6eef .env.development.default LAGO_LICENSE`.

Wide-scan leads (`--history-wide`, all paths), 5 LITERAL rows on 2026-10-01:
- the 2 `LAGO_LICENSE` rows above;
- `2002489` `docs/dev_environment.md` `LAGO_ORG_API_KEY`: a documentation example value;
- `530a0f3` `examples/agentic-ai-demo/compose.yml` `LAGO_ORG_API_KEY` and `run.sh` `API_KEY`: a fixed
  demo API key for a disposable local stack whose ports bind to `127.0.0.1`
  (`examples/agentic-ai-demo/compose.yml:16-17`). Low risk; never reuse it outside the demo.

## 3. AWS account id and ECR credentials in public workflows

- A 12-digit AWS account id is hard-coded in ECR image names:
  `.github/workflows/build-processors-image.yaml:15` (since `4955f79`, 2026-08-25) and
  `.github/workflows/build-connectors-image.yaml:19` (since `2146a18`, 2026-08-24). Do not copy the
  digits into docs or skills; cite the file:line.
- The `5308258` commit message says the staging Dockerfile copy "sat in the private lago-deploy repo
  specifically to keep ECR URLs and the AWS account id out of a public repository". Policy and
  practice disagree. An account id is not a credential, but the project itself treats it as
  sensitive. OPEN question for the owner: keep it public, or move it to a repository variable such
  as `vars.ECR_REGISTRY`?
- Both ECR callers pass long-lived keys: `secrets.AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  (`build-processors-image.yaml:21-23`, `build-connectors-image.yaml:26-28`).
- OIDC is plumbed but unused: `5ee8e98` (2026-08-25) added the `role-to-assume` input
  (`docker-build-multi-arch.yaml:90-94`, described as "Preferred over registry-user/registry-token")
  and `permissions: id-token: write` (`:126-129`); it is used at `:198-204` and `:339-344`. No caller
  passes `role-to-assume` (`grep -n role-to-assume .github/workflows/*.yaml` only hits the reusable
  file).
- Recommended (CANDIDATE, C5 + C7): create an IAM role trusted for `repo:getlago/lago:ref:refs/heads/main`,
  pass `role-to-assume` from both callers, then delete the static keys from repository secrets.
  Not verifiable here (no access to AWS or repository settings).

## 4. Workflow permissions and secret handling

| Item | Where | Risk | Status |
|---|---|---|---|
| Reusable workflow asks for `id-token: write`, `packages: write` | `docker-build-multi-arch.yaml:126-129` | Callers declare no `permissions:`; effective token scope depends on repo/org defaults, which the repo cannot show | UNVERIFIED (repository settings) |
| `secrets.build-secrets` interpolated into a shell script | `docker-build-multi-arch.yaml:255` | `${{ }}` text substitution happens before bash runs; a secret containing `"` or `$(` would alter the script. Logs are masked | latent: no caller passes `build-secrets` explicitly (this repo, lago-front `0c5e539`); `release-images.yml:42` uses `secrets: inherit`, so it only applies if a repository secret named `build-secrets` exists (UNVERIFIED). CANDIDATE fix: pass via `env:` and read `"$BUILD_SECRETS"` |
| Build-secret values feed a public tag suffix | `docker-build-multi-arch.yaml:271-274` (`sha256sum \| cut -c1-8` -> `.build-<8 hex>`) | 32-bit fingerprint of secret values in a public tag; lets anyone confirm a guessed low-entropy secret | inferred, latent (same condition as above); CANDIDATE: hash only names, or use a random build id |
| Cross-repo callers on `@main` | lago-front's release uses `getlago/lago/.github/workflows/docker-build-multi-arch.yaml@main` (lago-front `0c5e539` `.github/workflows/release.yml:13`) | any merge to this file changes another repo's release immediately | route through change-control C5 + C7 |
| Old action majors | `events-processor-tests.yml:38,41` (`checkout@v3`), `:59` (`setup-go@v4`) | older action code than the rest of the workflows (`@v4`+); mutable tags | see supply-chain.md |
| No `pull_request_target`, `workflow_run` or `issue_comment` triggers | `grep -n` over `.github/workflows/*` | fork PRs cannot reach secrets | positive control |

Secret names referenced by workflows (names only): `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD`, `GH_TOKEN`, `SEGMENT_WRITE_KEY`, `GITHUB_TOKEN`; reusable
inputs `registry-user`, `registry-token`, `repository-token`, `build-secrets`.
Re-list: `grep -ohE 'secrets\.[A-Za-z_-]+' .github/workflows/* | sort | uniq -c`.

CI fixtures that look like credentials but are not secrets: `docker-ci.yml:18-24` (ephemeral org,
password and API key for a throwaway CI stack; RSA key generated at run time with `openssl genrsa`),
`events-processor-tests.yml:29-34` (`lago`/`lago` for the CI Postgres service).

## 5. Other repository hygiene facts

- No `SECURITY.md`, no `CODEOWNERS`, no `dependabot.yml` / `renovate.json` committed
  (`git ls-files | grep -v '^\.claude/' | grep -iE 'security|codeowners|dependabot|renovate'` is
  empty; the `.claude/` filter keeps this skill's own path out), yet the history has
  17 dependabot commits (`git -C "$H" log --format=%an HEAD | grep -c dependabot`), all Go module
  bumps; probably enabled in repository settings (UNVERIFIED).
- `1035ffa` (2023-10-23) deleted 266 accidentally committed files (128 jars, 133 Windows
  `:Zone.Identifier` files) added in `c8f4133`; the blobs stay in history (not secrets). See the
  `failure-archaeology` skill.
