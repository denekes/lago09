#!/usr/bin/env bash
# triage-ep-log.sh - bucket an events-processor log (slog JSON lines mixed with plain panic,
# stack-trace and go-redis lines) by error_code, msg and panic; count the silent-loss signals;
# check memory-cache snapshot completeness and row counts (production runs memory-cache mode);
# map every distinct ERROR/WARN/panic line to a
# debugging-playbook entry id through explain-error.sh.
#
# Usage:
#   triage-ep-log.sh [--top N] [--fail-on-findings] <file|->
#     <file|->            log file or - for stdin. Accepts raw binary stdout+stderr, `kubectl logs`
#                         (with or without --timestamps), `docker compose logs` ("svc  | " prefixes).
#     --top N             distinct examples shown per bucket (default 3)
#     --fail-on-findings  exit 3 when ERROR lines, panics or silent-loss signals were found
#   Lines starting with "#" are ignored (fixture comments).
#   Get a log: kubectl logs <pod> > ep.log ; docker compose -f docker-compose.dev.yml logs --no-color
#   events-processor > ep.log (needs a daemon) ; or the binary's own output.
#
# Exit codes: 0 triaged; 1 no events-processor line recognised; 2 usage or unreadable input;
#             3 findings present (only with --fail-on-findings)
# Read-only: writes one temp dir under ${TMPDIR:-/tmp} (removed on exit). Needs bash, awk, sort.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

top=3 fail_on=0 src=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --top) top="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --fail-on-findings) fail_on=1; shift ;;
    -) src="-"; shift ;;
    -*) echo "triage-ep-log: unknown option $1" >&2; exit 2 ;;
    *) src="$1"; shift ;;
  esac
done
[ -n "$src" ] || { usage >&2; exit 2; }
case "$top" in ''|*[!0-9]*) echo "triage-ep-log: --top needs a number" >&2; exit 2 ;; esac
if [ "$src" != "-" ] && [ ! -r "$src" ]; then echo "triage-ep-log: cannot read $src" >&2; exit 2; fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/triage-ep.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
name="stdin"; [ "$src" = "-" ] || name="$(basename "$src")"

if [ "$src" = "-" ]; then cat > "$tmp/in"; else cat -- "$src" > "$tmp/in"; fi

set +e
awk -v TOP="$top" -v NAME="$name" -v EXPL="$tmp/explain" -v FLAGS="$tmp/flags" '
function jstr(s, k,    p, i, c, n, out, L) {
  p = index(s, "\"" k "\":")
  if (p == 0) return ""
  i = p + length(k) + 3; L = length(s); c = substr(s, i, 1)
  if (c != "\"") {
    out = ""
    while (i <= L) { c = substr(s, i, 1); if (c == "," || c == "}") break; out = out c; i++ }
    return out
  }
  i++; out = ""
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == "\\") {
      n = substr(s, i + 1, 1)
      if (n == "n" || n == "t" || n == "r") out = out " "; else out = out n
      i += 2; continue
    }
    if (c == "\"") break
    out = out c; i++
  }
  return out
}
function has(s, k) { return index(s, "\"" k "\":") > 0 }
function trunc(s, n) { sub(/[ \t]+$/, "", s); return (length(s) > n) ? substr(s, 1, n - 3) "..." : s }
function short_err(code, e,   p) {
  p = index(e, " with json: ")
  if (p > 0) e = substr(e, 1, p - 1) " with json: {...}"
  return trunc(e, 110)
}
# space-joined keys of arr in ascending order (deterministic across awk implementations)
function sorted_keys(arr,    k, out, best, n, i) {
  for (k in sk_done) delete sk_done[k]
  n = 0; for (k in arr) n++
  out = ""
  for (i = 0; i < n; i++) {
    best = ""
    for (k in arr) if (!(k in sk_done) && (best == "" || k < best)) best = k
    sk_done[best] = 1; out = out " " best
  }
  return out
}
function explain_once(key, line) { if (!(key in expl_seen)) { expl_seen[key] = 1; print line > EXPL } }
# print up to n keys of arr, by count desc then key asc; keys must start with prefix (stripped on print)
function top_print(arr, prefix, n, indent,    k, best, bestk, i, lp, shown, total, rest) {
  for (k in done_) delete done_[k]
  lp = length(prefix); total = 0
  for (k in arr) if (substr(k, 1, lp) == prefix) total++
  shown = 0
  for (i = 0; i < n; i++) {
    best = -1; bestk = ""
    for (k in arr) {
      if (substr(k, 1, lp) != prefix || (k in done_)) continue
      if (arr[k] > best || (arr[k] == best && k < bestk)) { best = arr[k]; bestk = k }
    }
    if (best < 0) break
    done_[bestk] = 1; shown++
    printf "%s%5d  %s\n", indent, best, substr(bestk, lp + 1)
  }
  rest = total - shown
  if (rest > 0) printf "%s       (+%d more distinct)\n", indent, rest
  return total
}
BEGIN { SEP = "\034" }
{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^#/) { comments++; next }
  # strip collector prefixes so plain panic / stack-frame / go-redis lines are recognised too:
  # kubectl logs --timestamps ("<RFC3339Nano> "), docker compose logs ("<svc>  | "),
  # docker compose logs --timestamps ("<svc>  | <RFC3339Nano> ")
  sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][.0-9]*(Z|[+-][0-9][0-9]:?[0-9][0-9]) /, "", line)
  sub(/^[A-Za-z0-9][A-Za-z0-9_.-]* +\| /, "", line)
  sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][.0-9]*(Z|[+-][0-9][0-9]:?[0-9][0-9]) /, "", line)
  if (line ~ /^[ \t]*$/) next
  total++
  p = index(line, "{\"time\":\"")
  if (p > 0) {
    json = substr(line, p); nj++
    svc = jstr(json, "service"); if (svc == "post_process") { ep++ }
    lvl = jstr(json, "level"); lv[lvl]++
    t = jstr(json, "time"); if (t != "") { if (first_t == "") first_t = t; last_t = t }
    msg = jstr(json, "msg"); comp = jstr(json, "component"); pkg = jstr(json, "pkg"); model = jstr(json, "model")
    err = jstr(json, "error"); if (err == "") err = jstr(json, "err")
    if (msg == "Starting event consumer") starts++
    if (msg == "Received shutdown signal") sigs++
    if (msg == "Event processor stopped") stops++
    if (index(json, "\"kafka-topic-consumer\":\"\"") > 0 || index(json, "\"group\":\"_\"") > 0) emptytopic++
    if (msg == "Starting snapshot load") { snap_s[model]++; snap_any = 1 }
    if (msg == "Completed snapshot load") { snap_c[model]++; snap_any = 1; snap_n[model] = jstr(json, "count") }
    if (msg == "Starting consumer" && pkg == "cache") { cdc_start++; snap_any = 1 }
    if (lvl != "ERROR" && lvl != "WARN") next
    if (lvl == "ERROR") findings++
    handled = 0
    if (has(json, "error_code")) {
      code = jstr(json, "error_code"); if (code == "") code = "(empty)"
      codes[code]++; handled = 1
      if (code == "build_enriched_event" || code == "evaluate_expression") dlq[code]++
      else if (code == "fetch_billable_metric") { if (err == "record not found" || err == "Key not found") dlq[code]++; else retry[code]++ }
      else if (code == "fetch_subscription" || code == "fetch_pay_in_advance_charge" || code == "flag_subscription_refresh") retry[code]++
      else unknown_code[code]++
      codeerr[code SEP short_err(code, err)]++
      explain_once("C|" code "|" substr(err, 1, 60), json)
    }
    if (msg == "Error unmarshalling message") { loss_unmarshal++; lossex["u" SEP trunc(err, 110)]++; handled = 1; explain_once("U|" substr(err, 1, 60), json) }
    if (index(msg, "No commitable record in batch") == 1) { loss_nocommit++; handled = 1; explain_once("N", json) }
    if (msg == "record had a produce error while synchronously producing") { loss_produce++; lossex["p" SEP trunc(err, 110)]++; handled = 1; explain_once("P|" substr(err, 1, 60), json) }
    if (msg == "error while pushing to dead letter topic") { loss_dlq++; handled = 1; explain_once("D", json) }
    if (msg == "Fetch error" && pkg != "cache") { fetch_panic++; handled = 1; explain_once("F|" substr(err, 1, 60), json) }
    if (index(msg, "Error when committing offets to kafka") == 1) { commit_err++; handled = 1; explain_once("K", json) }
    if (pkg == "cache" && msg == "Fetch error") { cdc_fetch++; handled = 1; explain_once("CF|" model, json) }
    if (pkg == "cache" && (msg == "Failed to unmarshal" || msg == "Failed to update cache from stream" || msg == "Failed to cache item" || msg == "Failed to delete from cache")) { cdc_write++; handled = 1; explain_once("CW|" msg, json) }
    if (handled) next
    tag = (comp != "") ? comp : ((pkg != "") ? pkg : "app")
    other["[" tag "] " lvl " " trunc(msg, 100) ((err != "" && index(msg, err) == 0) ? " | " trunc(err, 60) : "")]++
    explain_once("O|" tag "|" substr(msg, 1, 60) "|" substr(err, 1, 40), json)
    next
  }
  # ---- plain (non-JSON) lines ----
  np++
  if (line ~ /^panic: /) { panics[line]++; findings++; ep_plain++; explain_once("PANIC|" substr(line, 1, 80), line); in_trace = 1; next }
  if (index(line, "[signal SIGSEGV") == 1) { segv++; want_frames = 2; ep_plain++; next }
  if (line ~ /^fatal error: /) { fatals[line]++; findings++; ep_plain++; explain_once("FATAL|" substr(line, 1, 80), line); next }
  if (index(line, "error while loading shared libraries") > 0) { loader[line]++; findings++; ep_plain++; explain_once("LOADER", line); next }
  if (line ~ /^redis: .*pool\.go:[0-9]+: /) {
    m = line; sub(/^redis: [0-9\/]+ [0-9:]+ pool\.go:[0-9]+: /, "", m)
    rpool[m]++; ep_plain++; explain_once("RPOOL|" substr(m, 1, 80), line); next
  }
  if (line ~ /^goroutine [0-9]+ \[/) { ep_plain++; next }
  if (line ~ /^\t/ || line ~ /^[A-Za-z0-9_.\/-]+\(.*\)( \+0x[0-9a-f]+)?$/ || line ~ /^created by /) {
    ep_plain++
    if (want_frames > 0 && line !~ /^\t/) { if (frame1 == "") frame1 = line; want_frames--; explain_once("FRAME|" substr(line, 1, 80), line) }
    next
  }
  unrec++
}
END {
  printf "== events-processor log triage: %s\n", NAME
  printf "lines: %d (json %d, of which service=post_process %d; plain %d; unrecognised %d; # comments skipped %d)\n", total, nj, ep, np, unrec, comments
  printf "levels: ERROR=%d WARN=%d INFO=%d DEBUG=%d\n", lv["ERROR"], lv["WARN"], lv["INFO"], lv["DEBUG"]
  if (first_t != "") printf "time: %s .. %s\n", first_t, last_t
  printf "lifecycle: starts=%d shutdown_signals=%d stopped=%d\n", starts, sigs, stops
  if (emptytopic > 0) printf "  WARNING: empty raw topic or consumer group (kafka-topic-consumer \"\" / group \"_\"): nothing is consumed (start-empty-topic)\n"

  print "== startup / crash"
  nshown = 0
  for (k in panics) { npan += panics[k] }
  if (npan > 0) { printf "  panics: %d\n", npan; top_print(panics, "", TOP, "  "); nshown++ }
  if (segv > 0) { printf "  SIGSEGV: %d, first frame: %s\n", segv, frame1; nshown++ }
  for (k in fatals) { printf "  %d x %s\n", fatals[k], k; nshown++ }
  for (k in loader) { printf "  loader: %d x %s\n", loader[k], trunc(k, 140); nshown++ }
  nr = 0; for (k in rpool) nr += rpool[k]
  if (nr > 0) { printf "  go-redis pool (plain text) lines: %d\n", nr; top_print(rpool, "", TOP, "  "); nshown++ }
  if (nshown == 0) print "  none"

  print "== per-event failures by error_code"
  nc = 0; for (k in codes) nc++
  if (nc == 0) print "  none"
  else {
    printf "  %-30s %6s %8s %10s\n", "error_code", "lines", "to-DLQ", "retryable"
    for (k in done2) delete done2[k]
    for (i = 0; i < nc; i++) {
      best = -1; bestk = ""
      for (k in codes) { if (k in done2) continue; if (codes[k] > best || (codes[k] == best && k < bestk)) { best = codes[k]; bestk = k } }
      done2[bestk] = 1
      d = (bestk in dlq) ? dlq[bestk] : 0; r = (bestk in retry) ? retry[bestk] : 0
      if (bestk == "(empty)") printf "  %-30s %6d %8s %10s\n", bestk, best, "?", "?"
      else if (bestk in unknown_code) printf "  %-30s %6d %8s %10s\n", bestk, best, "?", "?"
      else printf "  %-30s %6d %8d %10d\n", bestk, best, d, r
      top_print(codeerr, bestk SEP, TOP, "      e.g.")
      tretry += r
    }
    if (tretry > 0) printf "  NOTE: %d retryable line(s): not committed and not on the DLQ while ingested_at < 12 h; skipped forever if a later batch on the partition commits (loss-retryable-skip)\n", tretry
  }

  print "== silent-loss signals"
  printf "  %-62s %5d\n", "dropped, committed, NO DLQ (Error unmarshalling message)", loss_unmarshal
  top_print(lossex, "u" SEP, TOP, "      e.g.")
  printf "  %-62s %5d\n", "head-of-batch retryable, commit skipped (No commitable record)", loss_nocommit
  printf "  %-62s %5d\n", "produce failed -> DLQ row with empty error_code", loss_produce
  top_print(lossex, "p" SEP, TOP, "      e.g.")
  printf "  %-62s %5d\n", "DLQ produce failed too -> Sentry only, LOST", loss_dlq
  printf "  %-62s %5d\n", "main consumer fetch error -> process panic", fetch_panic
  printf "  %-62s %5d\n", "offset commit errors (redelivery = duplicates)", commit_err

  print "== memory-cache mode"
  if (!snap_any && cdc_fetch == 0 && cdc_write == 0) {
    print "  not active in this log (no snapshot / CDC lines): DB mode (dev), or the process start is not in this log."
    print "  Production runs memory-cache mode: capture the log from pod start (kubectl logs --previous for a restarted pod)."
  } else {
    ss = 0; sc = 0
    for (k in snap_s) ss += snap_s[k]
    for (k in snap_c) sc += snap_c[k]
    printf "  snapshot loads: started %d, completed %d\n", ss, sc
    if (sc > 0) {
      rows = ""; lst = sorted_keys(snap_n); nk = split(lst, ks, " ")
      for (i = 1; i <= nk; i++) if (ks[i] != "") rows = rows " " ks[i] "=" snap_n[ks[i]]
      printf "  snapshot rows:%s\n", rows
      if (("billable_metrics" in snap_n) && snap_n["billable_metrics"] == "0") {
        print "  WARNING: snapshot loaded 0 billable_metrics - unless this is an empty install, DATABASE_URL points at the wrong database;"
        print "           every event then DLQs as fetch_billable_metric \"Key not found\" (cache-snapshot-failed)"
        findings++; nzero++
      }
    }
    for (k in snap_s) if (snap_c[k] < snap_s[k]) { inc[k] = 1; ninc++ }
    if (ninc > 0) {
      lst = sorted_keys(inc)
      printf "  WARNING: EMPTY/PARTIAL CACHE - no \"Completed snapshot load\" for:%s\n", lst
      print "           every event of those models fails the lookup (fetch_billable_metric \"Key not found\" for billable_metrics) (cache-snapshot-failed)"
      findings++
    }
    printf "  CDC consumers started: %d | CDC fetch errors: %d | CDC decode/write errors: %d\n", cdc_start, cdc_fetch, cdc_write
  }

  print "== other ERROR/WARN messages"
  no = 0; for (k in other) no++
  if (no == 0) print "  none"; else top_print(other, "", TOP + 2, "  ")

  sig = loss_unmarshal + loss_nocommit + loss_produce + loss_dlq + fetch_panic + tretry + ninc + nzero + emptytopic
  printf "FINDINGS %d\n", findings + sig > FLAGS
  printf "EPLINES %d\n", ep + ep_plain > FLAGS
}
' "$tmp/in"
rc=$?
set -e
[ $rc -eq 0 ] || { echo "triage-ep-log: awk failed (rc=$rc)" >&2; exit 2; }

findings=$(awk '$1=="FINDINGS"{print $2}' "$tmp/flags")
eplines=$(awk '$1=="EPLINES"{print $2}' "$tmp/flags")

echo "== playbook entries (explain-error.sh on each distinct ERROR/WARN/panic line)"
if [ -s "$tmp/explain" ]; then
  nd=$(wc -l < "$tmp/explain" | tr -d ' ')
  if out=$("$here/explain-error.sh" --brief - < "$tmp/explain" 2>/dev/null); then
    printf '%s\n' "$out" | awk -F'\t' '{printf "  %-26s %3d  %s\n", $1, $2, $3}'
  else
    echo "  none of the $nd distinct line(s) is a known entry: triage by area (SKILL.md section 1)"
  fi
  echo "  ($nd distinct line(s) examined; details: explain-error.sh --id <id>)"
else
  echo "  nothing to explain (no ERROR/WARN/panic lines)"
fi

if [ "${eplines:-0}" -eq 0 ]; then
  echo "triage-ep-log: no events-processor line recognised (expected slog JSON with \"service\":\"post_process\")" >&2
  exit 1
fi
if [ "$fail_on" -eq 1 ] && [ "${findings:-0}" -gt 0 ]; then exit 3; fi
exit 0
