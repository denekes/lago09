# Templates (copy-paste)

Read this when you write a commit, a PR body, an incident write-up, an ADR, a runbook section, or
when you change a skill. Every template follows practice measured in this repo's history. The
measurements and gates belong to `change-control`, so this file does not repeat them. Placeholders
are `<angle-bracketed>`. Delete every line that does not apply rather than writing "n/a".

<!-- evidence-check: off (templates, not claims; the evidence for the conventions is in SKILL.md and change-control) -->

## 1. Commit message

Rules (OPEN DECISION OD-7, owner; these are the defaults until the owner decides):

- Conventional Commits.
- Subject <= 72 characters hard, <= 50 preferred, measured as it lands on main. GitHub appends
  ` (#NNN)` on squash, so keep PR titles <= 64.
- Imperative mood, no trailing period. `misc` is allowed.
- Check with the `change-control` skill's commit-msg check.

Subject shapes seen in history:

```text
fix(events-processor): Skip kafka commit when no record is commitable          <- plain (9acd83e, #735)
[ING-543] fix(events-processor): Select the same charge filter as Rails        <- Linear ticket prefix (0b56915; also 3ac94a2, 9ef876a)
misc(events-processor): Remove flat filters and enriched expanded events       <- removal (d9c32b6)
```

Choose one of three body shapes. Each mirrors a commit worth imitating.

**A. Incident fix: one paragraph per fix (`9acd83e`).** Structure: the symptom and its trigger, then
the mechanism (root cause), then the change, then the ticket.

```text
fix(events-processor): <what the fix does>

When <trigger>, <component> <did what> (<observable symptom: log line, error, crash>).
<Root cause in one sentence: why the code did that.> <The change, in one or two sentences>
<and why it removes the cause, not the symptom>.

Refs: ING-<n>
```

What `9acd83e` actually says: "When the first record of a batch failed retryably,
findMaxCommitableRecord returned nil and the caller wrapped it in a slice passed to CommitRecords,
segfaulting the pod inside franz-go. Make the no-commitable-prefix case explicit via a (record, ok)
return and skip the commit when ok is false. Refs: ING-15"

**B. Context / Description (`02a4bc8`, `647de3e`; the lago-api convention).** Use it for behaviour
changes (C3, C4) and anything a reviewer must understand without the author.

```text
fix(<scope>): <imperative summary>

## Context

<The defect or need: what happens, when, and the consequence. Name the mechanism (e.g. "the
process-wide context is canceled on SIGTERM, so every Redis write in flight failed with
`context canceled`").>

## Description

<What changes, conceptually: the why and the what, not the how. Say what deliberately does NOT
change and why (e.g. "Connection setup keeps using the process context: aborting a startup ping
along with the process is the correct behavior").>

Refs: ING-<n>                       # or: Refs: https://linear.app/getlago/issue/INF-<n>
Co-Authored-By: <agent or person>   # when an agent wrote it
```

**C. Removal or design rationale (`d9c32b6`).** Plain paragraphs in this order:

1. The cost of what exists ("the main database load coming from the service").
2. Why removing it is safe (the only consumer sits behind a flag "off everywhere"; the payload is
   unaffected).
3. What still has to work, and how it works now.
4. What else goes with it.

Notes:

- Ticket references take three forms: a subject prefix `[ING-n] `, a `Refs: ING-n` trailer, or a
  Linear URL trailer (`2146a18`, `76159bd`). Pick one per commit.
- `$API/AGENTS.md:60` tells lago-api agents "Do not check previous commits". That rule is scoped to
  lago-api. In this repo, an incident fix should cite the chain it continues (shas). See
  `failure-archaeology`.
- Release bumps have their own subjects. Leave them to `release-and-images`.

## 2. PR body

Which template wins is part of OPEN DECISION OD-7 (owner):

- `PULL_REQUEST_TEMPLATE.md` is a checklist (fix/feature branch, one commit, `pnpm test`). It is
  written for a front-end repo, and two of its items do not apply (SC-35, SC-36 in `stale-claims.md`).
- `$API/AGENTS.md:37-43` and `$API/PULL_REQUEST_TEMPLATE.md:5-11` use Context / Description.

Default until decided: Context / Description, plus the class, evidence and decisions blocks that
change-control requires. Delete the template text that GitHub pre-fills.

```markdown
## Context

<Why this PR exists: symptom or need, who is affected, ticket (ING-n / INF-n / #issue). For a
stale-doc fix: "Fixes SC-NN from the docs-and-writing stale-claim register.">

## Description

<What changes and what deliberately does not. One bullet per file group.>

## Change class

C<n> (+C7 if security-relevant). Gates applied: see change-control's class table.

## Evidence

<Paste commands and their key output. See change-control N9 and change-control N13. For example:>
- `.claude/skills/build-and-env/scripts/ep-test.sh` -> ok x6
- `.claude/skills/build-and-env/scripts/ep-test.sh -race -count=1 ./...` -> ok x6
- `go vet ./...` -> clean; `gofmt -l <changed files>` -> empty; `golangci-lint run --allow-serial-runners --new-from-rev=$BASE ./...` -> 0 issues
- `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh --only SC-NN` -> before `STALE`, after `PASS`
- <probe / ledger / parity output for C3-C4>

## Decisions and open questions

- <DECIDED OD-n (owner, <date>): the decision this PR implements>
- <OPEN DECISION OD-n (owner): what this PR assumes until decided>
- <Anything UNVERIFIED, labelled as such>

## Cross-repo (C4 only)

Contract: K<n>. Paired PRs (DECIDED OD-4: one in each repo whose external dependent of K<n> the change
touches, per change-control `reference/cross-repo-protocol.md` §1): <links>, or "no external dependent of
K<n> is touched". Deploy order: <reader first, then writer>. Rollback: <steps>.
ADR: <link or the section below>.

Closes #<issue>   <!-- only if an issue exists -->
```

For events-processor code, the commands and expected outputs are `change-control`'s canonical
"Pre-PR gate for events-processor code" (change-control N9); run them from there, do not copy them
here. Then paste the pre-PR checklist from `change-control` (its "Pre-PR checklist" section). Keep
the title conventional and <= 64 characters.

## 3. Incident write-up

Use the same columns as the `failure-archaeology` ledger, so the write-up can be pasted into it
unchanged. Put it in the fix PR body or commit body. Add the row to `failure-archaeology` when the
fix merges.

```markdown
### <YYYY-MM-DD> <one-line title> (<ticket>)

| Date | Sha | PR | Kind | Symptom | Root cause | Fix / change | Status | Chain |
|---|---|---|---|---|---|---|---|---|
| <YYYY-MM-DD> | `<sha7>` | #<n> | FIX / HOTFIX / REGRESSION / REMOVAL | <what was observed: exact log line, error, metric> | <mechanism, with `path:line` at the parent sha> | <what changed> | settled / superseded / removed / residual / open | <chain letter or ->`<sha>` list> |

- **Symptom (verbatim):** `<log line / panic / SQLSTATE>`, seen <where> (<how often>).
- **Root cause:** <one paragraph; cite `path:line` at the parent commit>.
- **Evidence:** <command + output that reproduces it before the fix and passes after; a test name>.
- **Fix:** <sha, PR>. **What was tried first and rejected:** <shas or "none">.
- **Status:** <settled | superseded by `<sha>` | removed | residual: <what remains> | open>.
- **Do-not-re-fight rule:** <one imperative sentence a future engineer must not violate>.
- **Docs touched:** <SC-IDs closed, skills updated> (see SKILL.md "Doc maintenance").
```

Status words mean what `failure-archaeology` defines. Never write "fixed" for a residual class
(e.g. one query still uses gorm `First`, change-control N4).

## 4. ADR / design note (required for C4 by change-control N6 and change-control N7)

Write it in the PR body, or as a file the PR adds when the owner asks for one. It must cover what
change-control's cross-repo protocol and change-control N7 require.

```markdown
## ADR: <decision title>

- **Status:** Proposed | Accepted (<owner>, <date>, <link>) | Superseded by <link>
- **Owner decisions touched:** DECIDED OD-<n> (owner, <date>) it implements, or OPEN DECISION OD-<n> (owner)
  with the default assumed until decided. A delivery change states which ADR-001 points it implements
  (DECIDED OD-2; a deviation needs an owner decision first).
- **Change class:** C4 (<delivery semantics | cross-repo contract>)

### Context
<The problem, with evidence: probe or ledger output, incident shas. What is true today, with `path:line`.>

### Options considered
| Option | Delivery / correctness | Throughput impact | Operational cost | Reversible? |
|---|---|---|---|---|
| A <name> | <measured: e.g. ledger LOST=0 across N faults> | <measured or UNVERIFIED> | ... | ... |
| B <name> | ... | ... | ... | ... |

### Decision
<The chosen option, and why it beats the others on the drivers above.>

### Contract before / after (cross-repo changes)
- Before: <key/topic/payload/format, with writer and reader `path:line`>
- After: <new versioned name (`_v3`, new topic, new field)>. Never change the meaning of an existing name.
- Direction: <Go writes -> Rails reads | Rails writes -> Go reads>

### Mixed-version behaviour
- Old writer + new reader: <what happens>
- New writer + old reader: <what happens>

### Failure matrix (delivery changes)
| Fault | Expected disposition (enriched / DLQ / retried / blocked) | Test that proves it |
|---|---|---|

### Deploy order, rollback, cleanup
1. <Tolerant reader ships first: which repo, which release>
2. <Writer switches>
3. Cleanup in <release>, owned by <person/team>
Rollback: <writer first; irreversible steps only in cleanup>

### Evidence
<kfake test name and output (N7a); parity probe output; paired PR links both ways>

### Sign-off
- events-processor maintainer: <name/date>
- owner of each dependent repo's paired PR: <name/date>   (DECIDED OD-4; omit when no dependent is touched)
- Owner (delivery change conforms to ADR-001, DECIDED OD-2): <name/date>
```

## 5. Runbook section (for docs/ and skills)

```markdown
### <Task, imperative: "Rebuild libexpression_go.so for a new lago-expression tag">

**When:** <trigger or symptom, quoted exactly as it appears>.
**Preconditions:** <tools and versions; cwd (repo root unless stated); services that must run>.

1. <Step.> Run:
   ```bash
   <copy-pasteable command, no aliases, no secrets>
   ```
   Expect: `<key output line>` (as of <YYYY-MM-DD>).
2. ...

**Verify:** `<command>` -> `<expected>`.
**Undo / cleanup:** `<command>`.
**Not runnable in a daemon-less sandbox:** <steps>, verified by reading `<path:line>`.
**Sources:** `<path:line>`, `<sha>`. **Owner skill:** `<sibling>`.
```

Rules for runbooks:

- Every command runs as pasted from the stated cwd.
- `docker compose -f <file>` is always spelled out. Never `lago exec` alone (SKILL.md style rule S5).
- Every "Expect" line was observed on the date it shows. Otherwise label it UNVERIFIED.

## 6. Updating a skill in `.claude/skills/`

Checklist (the format contract every skill in this library follows):

1. **Frontmatter.**
   - `name` equals the directory name (lowercase, hyphens).
   - `description` is <= 600 characters (library rule; the format allows 1024), third person. It
     says what the skill is, then "Use when ..." with the literal strings people type (error
     messages, file names, env vars), then "Not for ... (use <sibling>)". An exact error or log
     string goes in one description only: the skill that triages it.
   - Check the length with
     `awk '/^description:/{sub(/^description: */,""); print length}' .claude/skills/<name>/SKILL.md`.
   - The frontmatter must parse as YAML. Quote the description if it contains `: ` or ` #`. Check
     every skill with
     `python3 -c "import yaml,re,sys;[yaml.safe_load(re.match(r'^---\n(.*?)\n---\n',open(f).read(),re.S).group(1)) for f in sys.argv[1:]]" .claude/skills/*/SKILL.md`
     (no output, exit 0).
2. **Skeleton order.** Title + 2-4 line purpose + a "Facts verified <date>" line that anchors code
   facts on an upstream commit, in this form: "Code facts as of `<sha7>` (events-processor tree
   `<tree12>`); the working branch may carry skills-only commits on top." Never anchor on a
   skills-only commit or an undated commit count of your clone: neither survives a squash merge.
   Then "When to use / when NOT to use" (each NOT names a sibling); Terms; core sections; Scripts
   table; "Provenance and maintenance" last. Target 180-450 lines; move long tables to
   `reference/<topic>.md` with a one-line "read when ...".
3. **Claims.**
   - Every factual line carries `path:line`, a 7-char sha, `(#PR)` or a command with its output
     (change-control N13).
   - Otherwise label it UNVERIFIED, CANDIDATE, OPEN DECISION OD-n (owner) or TARGET.
   - Cite doctrine as "change-control N#".
   - Never cite discovery-report IDs or scratch paths.
4. **Paths.**
   - Never hardcode a home, root or temp path. Get them from `history-setup.sh`,
     `pinned-checkout.sh` or `$LAGO_SKILLS_CACHE`.
   - You may cite another skill's script by its path when the script exists and you ran it
     (the library's consistency check verifies every such path). Otherwise name the skill.
   - Cite another skill's IDs as "<skill> <ID>" (e.g. "change-control N1"), never a bare ID.
5. **Scripts.**
   - Use `#!/usr/bin/env bash` + `set -euo pipefail` and a usage header that documents the exit codes.
   - Read-only on the repo. Write only to `$LAGO_SKILLS_CACHE`, `mktemp -d` or `--out`.
   - Make them idempotent and `chmod +x`. `bash -n` must pass.
   - Run each one and paste the exact command and its key output into the Scripts table.
   - No binaries, `*.out` or caches inside `.claude/skills/`.
6. **Re-verify before you change a number.** Run the skill's Provenance commands. If a value moved,
   update it and its "(as of <date>)" stamp in the same edit. Never update the date without
   re-running.
7. **Check.**
   - `bash -n .claude/skills/<name>/scripts/*.sh`.
   - Run the `research-methodology` skill's evidence-check on the SKILL.md.
   - Run `.claude/skills/docs-and-writing/scripts/doc-drift-check.sh -q`.
   - `git status --porcelain` shows only the skill directory.
   - If you added or renamed a skill, a script or an ID namespace, update the library index
     `.claude/skills/README.md` (start-here table, index, ID registry), and
     `grep -rn '<old name or ID>' .claude/skills` for inbound references.
8. **Commit.**
   - Subject `misc(skills): <summary>`, <= 72 characters, no WIP or fixup (check with
     `.claude/skills/change-control/scripts/commit-msg-check.sh`; WIP fails its rule M6).
   - Class: Markdown-only skill edits are C0; edits under `scripts/` are C1. An edit to doctrine
     (N#, C#, OD-#) needs the owner's sign-off (change-control section 3).
   - Body shape B, listing what was re-verified and what changed.

Provenance section skeleton:

```markdown
## Provenance and maintenance

- Sources: `<path:line>`, `<sha>`, `$API/<path>:<line>` (pinned `<sha7>`).
- Volatile facts (one re-verification command each):
  - `<fact>`: `<command>` -> expect `<output>` (as of <YYYY-MM-DD>)
- Update triggers: <events: a pin bump, a file rename, an OD decided, a sibling's script renamed>.
```

<!-- evidence-check: on -->
