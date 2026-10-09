#!/usr/bin/env bash
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# kit-pack.sh — build a pack of the three kit skills (reimplementation-kit, billing-engine-spec,
# events-processor-spec) laid out as .claude/skills/<skill>/, for a clean-room implementer or a maintainer.
#
# Usage:
#   kit-pack.sh [--cleanroom | --maintainer] [--skills-dir DIR] (--out FILE.tar.gz | --out-dir DIR) [--allow-invalid]
#
#   --cleanroom (default) strips every scripts/maintainer/ directory, maintainer-data/ (holdout vectors),
#               reference/maintainer-oracle.md and any file whose first lines carry the MAINTAINER-ONLY header,
#               then refuses the pack if forbidden content remains (umbrella-repo or cache paths, scratch paths,
#               planning-document or discovery ids, the MAINTAINER-ONLY marker, Ruby source, holdout vector ids).
#   --maintainer  keeps everything (for moving the kit between maintainer machines).
#   --skills-dir  directory holding the three skills (default: the one containing this kit).
#   --out         deterministic tarball (sorted names, mtime 0, owner 0); --out-dir copies the tree instead
#               (e.g. into a scratch clone that becomes a pack-only branch).
#   --allow-invalid  do not fail when validate-vectors.py reports errors inside the pack.
#
# Checks: kit.json (if present) — every listed file present with its sha256 (maintainer-only entries may be absent in
# a clean-room pack); validate-vectors.py run inside the pack (0 errors); forbidden-content scan.
# Output: PACK lines per check, then
#   SUMMARY kit-pack: mode=M files=N bytes=N stripped=N forbidden=N validate_errors=N sha256=<tarball|->
# Exit: 0 pack written; 1 a check failed (nothing written); 2 usage error.
# Writes only to a mktemp -d directory and to --out / --out-dir.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$HERE/../../.." && pwd)
MODE=cleanroom OUT="" OUTDIR="" ALLOW_INVALID=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanroom) MODE=cleanroom; shift ;;
    --maintainer) MODE=maintainer; shift ;;
    --skills-dir) SRC=$(cd "$2" && pwd); shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --out-dir) OUTDIR=$2; shift 2 ;;
    --allow-invalid) ALLOW_INVALID=1; shift ;;
    -h|--help) sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT$OUTDIR" ] || { echo "need --out FILE.tar.gz or --out-dir DIR" >&2; exit 2; }
[ -d "$SRC/reimplementation-kit" ] || { echo "no reimplementation-kit under $SRC" >&2; exit 2; }
SKILLS=(reimplementation-kit billing-engine-spec events-processor-spec)
export PYTHONDONTWRITEBYTECODE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=$TMP/pack/.claude/skills
mkdir -p "$P"
for s in "${SKILLS[@]}"; do
  if [ -d "$SRC/$s" ]; then cp -a "$SRC/$s" "$P/$s"; else echo "PACK missing-skill $s (skipped)"; fi
done
find "$P" \( -name __pycache__ -o -name '*.pyc' -o -name '.DS_Store' \) -prune -exec rm -rf {} +

stripped=0
if [ "$MODE" = cleanroom ]; then
  # holdout ids (before maintainer-data is removed) for the leak scan
  find "$P" -path '*/maintainer-data/*' -name '*.jsonl' -exec cat {} + 2>/dev/null |
    python3 -c 'import sys,json; [print(json.loads(l)["id"]) for l in sys.stdin if l.strip()]' > "$TMP/holdout-ids" || true
  while IFS= read -r d; do stripped=$((stripped + $(find "$d" -type f | wc -l))); rm -rf "$d"; done \
    < <(find "$P" -type d \( -path '*/scripts/maintainer' -o -name maintainer-data \) -prune -print)
  if [ -f "$P/reimplementation-kit/reference/maintainer-oracle.md" ]; then
    rm -f "$P/reimplementation-kit/reference/maintainer-oracle.md"; stripped=$((stripped + 1))
  fi
  while IFS= read -r f; do
    if head -3 "$f" | grep -q 'MAINTAINER-ONLY: needs lago-api'; then rm -f "$f"; stripped=$((stripped + 1)); fi
  done < <(find "$P" -type f)
  echo "PACK strip $stripped maintainer-only file(s) removed"
fi

# kit.json manifest ------------------------------------------------------------------------------------------------
manifest_bad=0
if [ -f "$P/reimplementation-kit/kit.json" ]; then
  manifest_bad=$(python3 - "$P" "$MODE" <<'EOF'
import hashlib, json, os, sys
root, mode = sys.argv[1], sys.argv[2]
doc = json.load(open(os.path.join(root, "reimplementation-kit", "kit.json")))
files = doc.get("files", {})
if isinstance(files, list):
    files = {f["path"]: f for f in files}
bad = 0
for rel, meta in files.items():
    meta = meta if isinstance(meta, dict) else {"sha256": meta}
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        if mode == "cleanroom" and meta.get("maintainer"):
            continue
        print(f"PACK manifest missing {rel}", file=sys.stderr); bad += 1; continue
    if meta.get("sha256") and hashlib.sha256(open(p, "rb").read()).hexdigest() != meta["sha256"]:
        print(f"PACK manifest sha256 mismatch {rel}", file=sys.stderr); bad += 1
print(bad)
EOF
)
  echo "PACK manifest kit.json checked: $manifest_bad problem(s)"
else
  echo "PACK manifest kit.json absent (not checked)"
fi

# forbidden content ---------------------------------------------------------------------------------------------------
forbidden=0
if [ "$MODE" = cleanroom ]; then
  # the generic default ${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills} is allowed; concrete cache contents are not
  pat='/home/user/lago09|/root/\.cache|\.cache/lago-skills/(lago-api|lago-front|k7-state|rubies|tools)|lago-api@[0-9a-f]|/tmp/claude|scratchpad|MAINTAINER-ONLY: needs lago-api|KIT-PLAN|KIT-BRIEF|discovery/k[1-8]|\bk[1-8]-(probe|probes|harness|recompute|run-lago-api|vector-recorder)'
  if grep -rInE "$pat" "$P" > "$TMP/forbidden.txt" 2>/dev/null; then
    forbidden=$((forbidden + $(wc -l < "$TMP/forbidden.txt")))
    sed "s#^$P/#PACK forbidden #" "$TMP/forbidden.txt" | head -20
  fi
  while IFS= read -r f; do forbidden=$((forbidden + 1)); echo "PACK forbidden source file ${f#"$P"/}"; done \
    < <(find "$P" -type f \( -name '*.rb' -o -name '*.erb' -o -name 'Gemfile*' \))
  if [ -s "$TMP/holdout-ids" ]; then
    if grep -rFqf "$TMP/holdout-ids" "$P"; then
      n=$(grep -rFof "$TMP/holdout-ids" "$P" | wc -l); forbidden=$((forbidden + n)); echo "PACK forbidden $n holdout id occurrence(s)"
    fi
  fi
  echo "PACK forbidden-content scan: $forbidden finding(s)"
fi

# validate inside the pack -----------------------------------------------------------------------------------------
verr=0
if python3 "$P/reimplementation-kit/scripts/validate-vectors.py" --kit-root "$P" --quiet > "$TMP/validate.txt" 2>&1; then :; fi
verr=$(sed -n 's/^SUMMARY validate-vectors: .*errors=\([0-9]*\).*/\1/p' "$TMP/validate.txt")
verr=${verr:-1}
echo "PACK validate $(grep '^SUMMARY' "$TMP/validate.txt" || echo 'validator did not run')"

nfiles=$(find "$P" -type f | wc -l); bytes=$(du -sb "$TMP/pack" | cut -f1)
fail=0
[ "$manifest_bad" = 0 ] || fail=1
[ "$forbidden" = 0 ] || fail=1
if [ "$verr" != 0 ] && [ "$ALLOW_INVALID" = 0 ]; then fail=1; fi
sha=-
if [ "$fail" = 0 ]; then
  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$TMP/pack" -cf - .claude | gzip -n > "$OUT"
    sha=$(sha256sum "$OUT" | cut -d' ' -f1)
    echo "PACK wrote $OUT"
  fi
  if [ -n "$OUTDIR" ]; then
    mkdir -p "$OUTDIR"
    cp -a "$TMP/pack/.claude" "$OUTDIR/"
    echo "PACK copied tree to $OUTDIR/.claude"
  fi
fi
echo "SUMMARY kit-pack: mode=$MODE files=$nfiles bytes=$bytes stripped=$stripped forbidden=$forbidden validate_errors=$verr sha256=$sha"
exit $fail
