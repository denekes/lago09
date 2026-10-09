#!/usr/bin/env bash
# MAINTAINER-ONLY: needs the lago repository (events-processor tree 83e012866f29) and the Go/CGO toolchain (build-and-env ep-env.sh); excluded from clean-room packs.
#
# build-go-reference.sh - build the Go reference events-processor and the ep-oracle (an
# adapter-protocol server answering the ep.* unit ops with the reference packages) from a
# read-only export of one events-processor tree.
#
# Usage: build-go-reference.sh [--tree TREE_ID] [--repo DIR] [--print-env]
#   --tree       events-processor tree id to export (default 83e012866f29, the kit's pin)
#   --repo       lago repository (default: the checkout containing this script, else $LAGO_REPO)
#   --print-env  only print the variables below (build if missing)
#
# Output (stdout, sourceable):
#   EP_REF_DIR=<cache>/ep-reference/<tree>
#   EP_REF_BIN=<cache>/ep-reference/<tree>/bin/events-processor
#   EP_ORACLE_BIN=<cache>/ep-reference/<tree>/bin/ep-oracle
#   EP_REF_LD_LIBRARY_PATH=<directory of libexpression_go.so>
# Use with the suite:
#   run-suite.sh --impl-cmd "$EP_REF_BIN" --impl-env LD_LIBRARY_PATH=$EP_REF_LD_LIBRARY_PATH
# and with kitrun: --impl-cmd "env LD_LIBRARY_PATH=$EP_REF_LD_LIBRARY_PATH $EP_ORACLE_BIN"
#
# The tree is exported with `git archive` (read-only on the repository) into the cache; two
# files are ADDED to the export only: cmd/ep-oracle/main.go (from this directory) and a
# one-function export of the commit-prefix selection in config/kafka. No repository file is
# modified. Exit: 0 ok; 1 build failure; 2 usage / repository not found.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tree=83e012866f29; repo=""; print_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) tree="${2:?}"; shift ;;
    --repo) repo="${2:?}"; shift ;;
    --print-env) print_only=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "build-go-reference: unknown argument $1" >&2; exit 2 ;;
  esac; shift
done
if [ -z "$repo" ]; then
  repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo" ] && [ -d "$repo/events-processor" ] || repo="${LAGO_REPO:-}"
fi
[ -n "$repo" ] && [ -d "$repo/events-processor" ] || { echo "build-go-reference: lago repository not found (run from a checkout, pass --repo or set LAGO_REPO)" >&2; exit 2; }
git -C "$repo" cat-file -e "$tree^{tree}" 2>/dev/null || { echo "build-go-reference: tree $tree not in $repo" >&2; exit 2; }

# CGO library for the expression engine (exports CGO_LDFLAGS, LD_LIBRARY_PATH, LAGO_SKILLS_CACHE).
# shellcheck disable=SC1091
source "$repo/.claude/skills/build-and-env/scripts/ep-env.sh" >/dev/null 2>&1 \
  || { echo "build-go-reference: ep-env.sh failed (libexpression_go.so)" >&2; exit 1; }
cache="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"
dir="$cache/ep-reference/$tree"
src="$dir/src"
osha="$(cat "$here/ep-oracle/main.go" | sha256sum | cut -c1-16)"

need_ref=0; need_oracle=0
[ -x "$dir/bin/events-processor" ] && [ "$(cat "$dir/bin/.tree" 2>/dev/null)" = "$tree" ] || need_ref=1
[ -x "$dir/bin/ep-oracle" ] && [ "$(cat "$dir/bin/.oracle-sha" 2>/dev/null)" = "$osha" ] || need_oracle=1
if [ "$need_ref" = 1 ] || [ "$need_oracle" = 1 ]; then
  [ "$print_only" = 1 ] && echo "build-go-reference: building (first use or changed ep-oracle source)" >&2
  if [ ! -f "$src/go.mod" ] || [ "$(cat "$dir/.src-tree" 2>/dev/null)" != "$tree" ]; then
    rm -rf "$src"; mkdir -p "$src"
    git -C "$repo" archive "$tree" | tar -x -C "$src"
    echo "$tree" > "$dir/.src-tree"
  fi
  mkdir -p "$dir/bin" "$src/cmd/ep-oracle"
  cp "$here/ep-oracle/main.go" "$src/cmd/ep-oracle/main.go"
  cat > "$src/config/kafka/zz_ep_oracle_export.go" <<'EOF2'
package kafka

import "github.com/twmb/franz-go/pkg/kgo"

// OracleFindMaxCommitableRecord exposes the commit-prefix selection to the ep-oracle
// (added only to the maintainer's exported build tree; not part of the events-processor).
func OracleFindMaxCommitableRecord(processed, records []*kgo.Record) (*kgo.Record, bool) {
	return findMaxCommitableRecord(processed, records)
}
EOF2
  # Build to temporary names, then rename: a suite run using the old binary is never disturbed.
  if [ "$need_ref" = 1 ]; then
    (cd "$src" && GOFLAGS=-mod=readonly go build -o "$dir/bin/events-processor.tmp" .) \
      || { echo "build-go-reference: go build (events-processor) failed" >&2; exit 1; }
    mv -f "$dir/bin/events-processor.tmp" "$dir/bin/events-processor"
    echo "$tree" > "$dir/bin/.tree"
  fi
  if [ "$need_oracle" = 1 ]; then
    (cd "$src" && GOFLAGS=-mod=readonly go build -o "$dir/bin/ep-oracle.tmp" ./cmd/ep-oracle) \
      || { echo "build-go-reference: go build (ep-oracle) failed" >&2; exit 1; }
    mv -f "$dir/bin/ep-oracle.tmp" "$dir/bin/ep-oracle"
    echo "$osha" > "$dir/bin/.oracle-sha"
  fi
fi
echo "EP_REF_DIR=$dir"
echo "EP_REF_BIN=$dir/bin/events-processor"
echo "EP_ORACLE_BIN=$dir/bin/ep-oracle"
echo "EP_REF_LD_LIBRARY_PATH=$LAGO_EXPRESSION_LIB"
