#!/usr/bin/env bash
# baseline.sh — measure the events-processor quality baseline and compare it with a baseline file.
#
# Usage (from anywhere in the lago repo; bash >= 4):
#   baseline.sh                         # measure + compare with scripts/baseline.json
#   baseline.sh --baseline FILE         # compare with another file (e.g. one written on the PR base)
#   baseline.sh --write FILE            # also write the current numbers to FILE (same format)
#   baseline.sh --no-lint --no-coverpkg # quicker run (~6 s warm instead of ~12 s; ~29 s with a cold lint cache)
#   baseline.sh --quiet                 # only FAIL/WARN rows and the SUMMARY line
#
# What it measures (cwd events-processor/, CGO env from build-and-env/scripts/ep-env.sh):
#   tests     go test -count=1 -json -coverprofile over the packages that HAVE test files
#             (listing them avoids the go1.25.0 'no such tool "covdata"' exit 1)
#             -> pass/fail/skip per package (top-level tests + subtests), own-package coverage
#   coverpkg  the same packages with -coverpkg=./... -> cross-package total (main and
#             processors are not in the profile: no test binary links them)
#   vet       go vet ./...            -> number of output lines
#   gofmt     gofmt -l .              -> number of files listed
#   lint      golangci-lint run --allow-serial-runners ./... -> issues per linter (no repo config: v2 defaults)
#
# Compare rules. FAIL (= regression, exit 1):
#   pass.total or any pass.<pkg> lower than baseline; fail.total > 0; a package that fails to build;
#   cover.total or any cover.<pkg> lower than baseline (0.1 point resolution);
#   vet.issues / gofmt.files / lint.total / any lint.<linter> above baseline.
# WARN (exit stays 0): skip.total up; coverpkg.total down; golangci-lint missing or another version;
#   Postgres unreachable (config/database will then fail and be reported as FAIL).
# Higher pass counts / coverage and lower lint counts are improvements: refresh the file with
#   --write <path> in the same PR (change-control C1), never silently.
#
# Writes only to mktemp dirs (and FILE given to --write). Never writes into the repo by itself.
# Exit: 0 no regression; 1 regression; 2 setup error (env, missing baseline file, go test crash).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
baseline="$here/baseline.json"
write_to=""
do_lint=1
do_coverpkg=1
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) baseline="${2:?--baseline needs a file}"; shift 2 ;;
    --write) write_to="${2:?--write needs a file}"; shift 2 ;;
    --no-lint) do_lint=0; shift ;;
    --no-coverpkg) do_coverpkg=0; shift ;;
    --quiet|-q) quiet=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "baseline: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$baseline" ] || { echo "baseline: baseline file not found: $baseline" >&2; exit 2; }
case "$write_to" in /*|"") ;; *) write_to="$PWD/$write_to" ;; esac

# shellcheck source=/dev/null
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" || { echo "baseline: ep-env.sh failed" >&2; exit 2; }
cd "$repo/events-processor"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vqa-baseline.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mod="$(go list -m)"
declare -A cur=()
warns=()

pg_note=""
if command -v pg_isready >/dev/null 2>&1 && ! pg_isready -q -d "$DATABASE_URL"; then
  pg_note="Postgres unreachable: config/database TestNewConnection will fail (start Postgres, see build-and-env)"
  warns+=("$pg_note")
fi

# ---------- tests + own-package coverage ----------
mapfile -t pkgs < <(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./... | sed '/^$/d')
[ ${#pkgs[@]} -gt 0 ] || { echo "baseline: no test packages found" >&2; exit 2; }
start=$(date +%s)
set +e
go test -count=1 -json -coverprofile="$tmp/cover.out" "${pkgs[@]}" > "$tmp/test.json" 2> "$tmp/test.err"
test_rc=$?
set -e
cur[time.test_s]=$(( $(date +%s) - start ))
if [ ! -s "$tmp/test.json" ]; then
  echo "baseline: go test produced no output (exit $test_rc):" >&2; sed -n '1,20p' "$tmp/test.err" >&2; exit 2
fi

# Per-package counts from the JSON event stream (one JSON object per line).
while IFS='=' read -r k v; do cur[$k]=$v; done < <(
  awk -v mod="$mod" '
    function field(name,   m) {
      if (match($0, "\"" name "\":\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub("^\"" name "\":\"", "", m); sub("\"$", "", m); return m }
      return ""
    }
    {
      act = field("Action"); pkg = field("Package"); tst = field("Test")
      p = pkg; sub("^" mod "/?", "", p); if (p == "") p = "."
      if (tst != "" && (act == "pass" || act == "fail" || act == "skip")) { n[act "." p]++; n[act ".total"]++ }
      if (tst == "" && act == "fail") { buildfail[p] = 1 }
      if (tst == "" && act == "output" && index($0, "[build failed]") > 0) { buildfail[p] = 1 }
      seen[p] = 1
    }
    END {
      for (p in seen) { for (a = 1; a <= 3; a++) { split("pass fail skip", acts, " "); k = acts[a] "." p; if (!(k in n)) n[k] = 0 } }
      for (k in n) print k "=" n[k]
      nb = 0; for (p in buildfail) { if (n["fail." p] == 0) { print "buildfail." p "=1"; nb++ } }
      print "buildfail.total=" nb
      if (!("pass.total" in n)) print "pass.total=0"
      if (!("fail.total" in n)) print "fail.total=0"
      if (!("skip.total" in n)) print "skip.total=0"
    }' "$tmp/test.json")

# Coverage from the profile: statements per package dir, a block counts once (max count wins).
cover_from_profile() { # $1 profile, $2 key prefix
  awk -v mod="$mod" -v pre="$2" '
    NR == 1 { next }
    { k = $1; s[k] = $2; if (!(k in c) || $3 > c[k]) c[k] = $3 }
    END {
      for (k in s) {
        f = k; sub(/:.*/, "", f); sub(/\/[^\/]*$/, "", f); sub("^" mod "/?", "", f); if (f == "") f = "."
        T[f] += s[k]; TT += s[k]; if (c[k] > 0) { C[f] += s[k]; CC += s[k] }
      }
      for (p in T) printf "%s.%s=%.1f\n", pre, p, (T[p] ? 100 * C[p] / T[p] : 0)
      printf "%s.total=%.1f\n%s.statements=%d/%d\n", pre, (TT ? 100 * CC / TT : 0), pre, CC, TT
    }' "$1"
}
if [ -s "$tmp/cover.out" ]; then
  while IFS='=' read -r k v; do cur[$k]=$v; done < <(cover_from_profile "$tmp/cover.out" cover)
fi

# ---------- cross-package coverage ----------
if [ "$do_coverpkg" = 1 ]; then
  if go test -count=1 -coverpkg=./... -coverprofile="$tmp/cover-all.out" "${pkgs[@]}" > "$tmp/coverpkg.txt" 2>&1; then
    while IFS='=' read -r k v; do
      case "$k" in coverpkg.total|coverpkg.statements) cur[$k]=$v ;; esac
    done < <(cover_from_profile "$tmp/cover-all.out" coverpkg)
  else
    warns+=("coverpkg not measured: the -coverpkg=./... run exited non-zero (a failing test or build error; see the FAIL rows)")
  fi
fi

# ---------- vet, gofmt ----------
set +e
go vet ./... > "$tmp/vet.txt" 2>&1; vet_rc=$?
set -e
cur[vet.issues]=$(grep -cvE '^#|^$' "$tmp/vet.txt" || true)
[ "$vet_rc" = 0 ] || [ "${cur[vet.issues]}" -gt 0 ] || cur[vet.issues]=1
cur[gofmt.files]=$(gofmt -l . | grep -c . || true)

# ---------- golangci-lint ----------
if [ "$do_lint" = 1 ]; then
  if command -v golangci-lint >/dev/null 2>&1; then
    cur[golangci_lint]="$(golangci-lint version --short 2>/dev/null || echo unknown)"
    set +e
    GOLANGCI_LINT_CACHE="${GOLANGCI_LINT_CACHE:-${LAGO_SKILLS_CACHE}/golangci-cache}" \
      golangci-lint run --allow-serial-runners --output.text.colors=false ./... > "$tmp/lint.txt" 2>&1
    lint_rc=$?
    set -e
    if [ "$lint_rc" -gt 1 ]; then
      warns+=("golangci-lint exited $lint_rc (tool error, not issues): $(tail -n 2 "$tmp/lint.txt" | tr '\n' ' ')")
    else
      cur[lint.total]=$(sed -nE 's/^([0-9]+) issues?[.:]$/\1/p' "$tmp/lint.txt" | tail -n1)
      [ -n "${cur[lint.total]}" ] || cur[lint.total]=0
      while read -r l n; do cur[lint.$l]=$n; done < <(sed -nE 's/^\* ([A-Za-z0-9_-]+): ([0-9]+)$/\1 \2/p' "$tmp/lint.txt")
    fi
  else
    warns+=("golangci-lint not installed: lint not compared (build-and-env lists the version, v2.5.0)")
  fi
fi
cur[go]="$(go env GOVERSION)"
cur[as_of]="$(date -u +%Y-%m-%d)"
cur[head]="$(git -C "$repo" rev-parse --short=7 HEAD)"
cur[ep_tree]="$(git -C "$repo" rev-parse --short=12 HEAD:events-processor)"
cur[ep_dirty]="$(git -C "$repo" status --porcelain -- events-processor | grep -c . || true)"

# ---------- read the baseline (flat JSON: one "key": value per line) ----------
declare -A base=()
while IFS='=' read -r k v; do base[$k]=$v; done < <(sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*"?([^",]*)"?,?[[:space:]]*$/\1=\2/p' "$baseline")

# ---------- compare ----------
fails=0
rows=()
x10() { awk -v v="$1" 'BEGIN{printf "%d", (v * 10) + (v >= 0 ? 0.5 : -0.5)}'; }
row() { # key base cur status note
  if [ "$quiet" = 0 ] || [ "$4" != OK ]; then rows+=("$(printf '%-36s %-10s %-10s %-5s %s' "$1" "$2" "$3" "$4" "${5:-}")"); fi
}
mapfile -t keys < <(printf '%s\n' "${!base[@]}" "${!cur[@]}" | sort -u)
for k in "${keys[@]}"; do
  b="${base[$k]-}"; c="${cur[$k]-}"
  case "$k" in
    as_of|head|ep_tree|ep_dirty|note|time.*|*.statements) [ "$quiet" = 1 ] || row "$k" "${b:--}" "${c:--}" INFO; continue ;;
    go)
      if [ -n "$b" ] && [ "$b" != "$c" ]; then row "$k" "$b" "$c" WARN "toolchain differs"; warns+=("go $c vs baseline $b"); else row "$k" "${b:--}" "$c" OK; fi; continue ;;
    golangci_lint)
      if [ "$do_lint" = 1 ] && [ -n "$c" ] && [ -n "$b" ] && [ "$b" != "$c" ]; then row "$k" "${b:--}" "$c" WARN "lint counts may differ by version"; warns+=("golangci-lint $c vs baseline $b"); else row "$k" "${b:--}" "${c:--}" OK; fi; continue ;;
    lint.*)
      [ "$do_lint" = 1 ] && [ -n "${cur[lint.total]-}" ] || { row "$k" "${b:--}" - SKIP; continue; }
      c="${c:-0}"; b="${b:-0}"
      if [ "$c" -gt "$b" ]; then row "$k" "$b" "$c" FAIL "new lint issues"; fails=$((fails+1));
      elif [ "$c" -lt "$b" ]; then row "$k" "$b" "$c" OK "improved: refresh the baseline"; else row "$k" "$b" "$c" OK; fi; continue ;;
    coverpkg.*)
      [ "$do_coverpkg" = 1 ] && [ -n "$c" ] || { row "$k" "${b:--}" - SKIP; continue; }
      if [ -n "$b" ] && [ "$(x10 "$c")" -lt "$(x10 "$b")" ]; then row "$k" "$b" "$c" WARN "cross-package coverage dropped"; warns+=("$k $b -> $c");
      else row "$k" "${b:--}" "$c" OK; fi; continue ;;
    cover.*)
      if [ -z "$c" ]; then row "$k" "$b" - FAIL "package no longer measured"; fails=$((fails+1));
      elif [ -z "$b" ]; then row "$k" - "$c" OK "new package";
      elif [ "$(x10 "$c")" -lt "$(x10 "$b")" ]; then row "$k" "$b" "$c" FAIL "coverage dropped"; fails=$((fails+1));
      elif [ "$(x10 "$c")" -gt "$(x10 "$b")" ]; then row "$k" "$b" "$c" OK "improved: refresh the baseline";
      else row "$k" "$b" "$c" OK; fi; continue ;;
    pass.*)
      if [ -z "$c" ]; then row "$k" "$b" - FAIL "package no longer has passing tests"; fails=$((fails+1));
      elif [ -z "$b" ]; then row "$k" - "$c" OK "new package";
      elif [ "$c" -lt "$b" ]; then row "$k" "$b" "$c" FAIL "fewer passing tests"; fails=$((fails+1));
      elif [ "$c" -gt "$b" ]; then row "$k" "$b" "$c" OK "more tests: refresh the baseline";
      else row "$k" "$b" "$c" OK; fi; continue ;;
    fail.*|buildfail.*)
      c="${c:-0}"
      if [ "$c" -gt 0 ]; then row "$k" "${b:-0}" "$c" FAIL; fails=$((fails+1)); else [ "$quiet" = 1 ] || row "$k" "${b:-0}" "$c" OK; fi; continue ;;
    skip.*)
      c="${c:-0}"; b="${b:-0}"
      if [ "$c" -gt "$b" ]; then row "$k" "$b" "$c" WARN "new skipped tests"; warns+=("$k $b -> $c"); else [ "$quiet" = 1 ] || row "$k" "$b" "$c" OK; fi; continue ;;
    vet.issues|gofmt.files)
      c="${c:-0}"; b="${b:-0}"
      if [ "$c" -gt "$b" ]; then row "$k" "$b" "$c" FAIL; fails=$((fails+1)); else row "$k" "$b" "$c" OK; fi; continue ;;
    *) [ "$quiet" = 1 ] || row "$k" "${b:--}" "${c:--}" INFO ;;
  esac
done

printf '%-36s %-10s %-10s %-5s %s\n' METRIC BASELINE CURRENT STATUS NOTE
[ ${#rows[@]} -eq 0 ] || printf '%s\n' "${rows[@]}"
if [ "$fails" -gt 0 ] && grep -q '"Action":"fail"' "$tmp/test.json"; then
  echo "--- failing tests (leaf names):"
  awk 'match($0, /"Action":"fail","Package":"[^"]*","Test":"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/.*"Test":"/, "", s); sub(/"$/, "", s); print "  " s }' "$tmp/test.json" | sort -u | head -n 40 || true
fi
for w in "${warns[@]}"; do echo "WARN $w"; done

if [ -n "$write_to" ]; then
  {
    echo "{"
    mapfile -t wkeys < <(printf '%s\n' "${!cur[@]}" | grep -vE '^(time\.|buildfail\.)' | sort)
    n=${#wkeys[@]}; i=0
    for k in "${wkeys[@]}"; do
      i=$((i+1)); v="${cur[$k]}"; sep=","; [ "$i" = "$n" ] && sep=""
      # Identity/version keys stay strings even when they look numeric (a short sha such as
      # 5308258 is all digits; written bare it is a JSON number, or invalid JSON with a leading 0).
      case "$k" in as_of|head|ep_tree|go|golangci_lint|note|*.statements) printf '  "%s": "%s"%s\n' "$k" "$v" "$sep"; continue ;; esac
      if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '  "%s": %s%s\n' "$k" "$v" "$sep"; else printf '  "%s": "%s"%s\n' "$k" "$v" "$sep"; fi
    done
    echo "}"
  } > "$write_to"
  echo "baseline: wrote current numbers to $write_to"
fi

echo "SUMMARY baseline: ${fails} FAIL, ${#warns[@]} WARN (baseline as_of ${base[as_of]:-?} head ${base[head]:-?}; go test exit ${test_rc}; ${cur[time.test_s]}s tests)"
[ "$fails" -eq 0 ] || exit 1
exit 0
