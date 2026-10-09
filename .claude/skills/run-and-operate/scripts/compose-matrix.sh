#!/usr/bin/env bash
# compose-matrix.sh — daemon-less inventory of EVERY docker compose file tracked in the repo.
#
# For each file (found with `git ls-files`, so new files are picked up automatically):
#   - validity:   `docker compose config --quiet` exit code + number of "variable is not set" warnings
#   - project:    resolved compose project name (root file = directory name, no `name:` key)
#   - profiles:   every profile, and the service list each profile resolves to
#   - services:   service | image | profiles | host ports | named volumes | Traefik router rules
#   - volumes:    resolved (project-prefixed) volume names, external flag
# Optional --check-scripts: every `./scripts/<x>.sh` a compose service runs must exist in the
#   pinned lago-api checkout (catches deploy/docker-compose.production.yml start.pdf.worker.sh).
#
# Runs with a CLEAN environment (env -i) and `--env-file /dev/null`, so neither your shell nor a
# stray .env changes the result. Needs: docker CLI with compose v2, jq. No Docker daemon needed.
# Read-only: writes nothing (the pinned checkout used by --check-scripts lives in $LAGO_SKILLS_CACHE).
#
# Usage:  compose-matrix.sh [--brief] [--check-scripts] [FILE...]
#   --brief          validity + profile/service lists only (no per-service table)
#   --check-scripts  also verify ./scripts/*.sh references against the pinned lago-api checkout
#   FILE...          restrict to these repo-relative compose files (default: all tracked ones)
# Exit codes: 0 all files valid (and all scripts found); 1 at least one invalid file or missing
#             script; 2 usage/tooling error.
set -euo pipefail

brief=0; check_scripts=0; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief=1 ;;
    --check-scripts) check_scripts=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) files+=("$1") ;;
  esac
  shift
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
command -v docker >/dev/null 2>&1 || { echo "docker CLI not found" >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 plugin not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }

if [ ${#files[@]} -eq 0 ]; then
  mapfile -t files < <(git -C "$repo" ls-files | grep -E '(^|/)([^/]*compose[^/]*)\.ya?ml$' | grep -v '^\.claude/')
fi

# clean-env compose runner; LAGO_DOMAIN etc. stay unset on purpose (warnings are counted, not hidden)
dc() { (cd "$repo" && env -i PATH="$PATH" HOME="$HOME" ${DC_EXTRA:-} docker compose --env-file /dev/null "$@"); }

api=""
if [ "$check_scripts" = 1 ]; then
  api="$("$repo/.claude/skills/research-methodology/scripts/pinned-checkout.sh" api)" || { echo "pinned-checkout.sh api failed" >&2; exit 2; }
fi

bad=0
echo "compose-matrix: $(docker compose version --short 2>/dev/null | sed 's/^/compose /'), repo HEAD $(git -C "$repo" rev-parse --short HEAD), ${#files[@]} file(s)"
for f in "${files[@]}"; do
  echo
  echo "=== $f"
  if [ ! -f "$repo/$f" ]; then echo "  MISSING file"; bad=1; continue; fi
  err="$(dc -f "$f" config --quiet 2>&1)" && rc=0 || rc=$?
  nwarn="$(printf '%s\n' "$err" | grep -c 'is not set' || true)"
  unset_vars="$(printf '%s\n' "$err" | sed -nE 's/.*The \\?"([A-Z0-9_]+)\\?" variable is not set.*/\1/p' | sort -u | tr '\n' ' ')"
  if [ "$rc" -ne 0 ]; then
    echo "  valid: NO (exit $rc)"; printf '%s\n' "$err" | grep -v 'is not set' | sed 's/^/    /' | head -5
    bad=1; continue
  fi
  echo "  valid: yes   unset-variable warnings: $nwarn ${unset_vars:+(${unset_vars% })}"
  # placeholder domain only for the table, so Traefik rules render (validity above used a clean env)
  json="$(DC_EXTRA="LAGO_DOMAIN=lago.example.com" dc -f "$f" --profile '*' config --format json 2>/dev/null)"
  echo "  project: $(jq -r '.name' <<<"$json")"
  profiles="$(dc -f "$f" --profile '*' config --profiles 2>/dev/null | tr '\n' ' ')"
  noprof="$(dc -f "$f" config --services 2>/dev/null | sort | tr '\n' ' ')"
  echo "  services with no profile ($(wc -w <<<"$noprof")): ${noprof% }"
  if [ -n "${profiles// /}" ]; then
    for p in $profiles; do
      s="$(dc -f "$f" --profile "$p" config --services 2>/dev/null | sort | tr '\n' ' ')"
      echo "  --profile $p ($(wc -w <<<"$s")): ${s% }"
    done
  else
    echo "  profiles: none"
  fi
  if [ "$brief" = 0 ]; then
    echo "  service | image | profiles | host ports | named volumes | traefik router rules (LAGO_DOMAIN shown as lago.example.com)"
    jq -r '.services | to_entries | sort_by(.key)[] |
      "  - \(.key) | \(.value.image // "(build)") | \((.value.profiles // []) | join(",") | if .=="" then "-" else . end) | " +
      "\([.value.ports[]? | "\(.host_ip // "" | if .=="" then "" else .+":" end)\(.published // "?")->\(.target)"] | join(" ") | if .=="" then "-" else . end) | " +
      "\([.value.volumes[]? | select(.type=="volume") | "\(.source):\(.target)"] | join(" ") | if .=="" then "-" else . end) | " +
      "\([(.value.labels // {}) | to_entries[] | select(.key|test("routers\\..*\\.rule$")) | .value] | unique | join("; ") | if .=="" then "-" else . end)"' <<<"$json"
    jq -r '(.volumes // {}) | to_entries[] | "  volume \(.key) -> \(.value.name)\(if .value.external then " (EXTERNAL: must exist before up)" else "" end)"' <<<"$json"
  fi
  if [ "$check_scripts" = 1 ]; then
    while read -r svc script; do
      [ -z "$script" ] && continue
      if [ -f "$api/${script#./}" ]; then
        echo "  script OK      $svc -> $script"
      else
        echo "  script MISSING $svc -> $script (not in lago-api@$(git -C "$api" rev-parse --short HEAD 2>/dev/null || echo pinned))"
        bad=1
      fi
    done < <(jq -r '.services | to_entries[] | .key as $s |
        ([.value.command] | flatten | map(select(. != null)) | join(" ")) |
        [scan("\\./scripts/[A-Za-z0-9_.-]+\\.sh")] | unique[] | "\($s) \(.)"' <<<"$json" | sort -u)
  fi
done
echo
if [ "$bad" = 0 ]; then echo "RESULT: all ${#files[@]} compose file(s) valid${api:+, all referenced scripts present}"; else echo "RESULT: problems found (see above)"; fi
exit "$bad"
