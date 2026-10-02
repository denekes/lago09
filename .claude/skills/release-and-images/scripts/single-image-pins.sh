#!/usr/bin/env bash
# single-image-pins.sh — pre-release check of the all-in-one image (docker/Dockerfile):
# do its Ruby / Node / Bundler / pnpm choices match what the pinned lago-api and lago-front
# require, and are the guards for past release-day breakages still in place?
# Read-only on the repo. Needs network (pinned-checkout.sh fetch on first use; Docker Hub API
# for the Debian check unless --offline).
#
# Usage (from anywhere inside the repo):
#   .claude/skills/release-and-images/scripts/single-image-pins.sh               # working-tree Dockerfile vs INDEX gitlinks
#   .../single-image-pins.sh --ref v1.53.0                                       # a published umbrella tag
#   .../single-image-pins.sh --ref <sha|branch>                                  # any commit (working or history clone)
#   .../single-image-pins.sh --offline                                           # skip the Docker Hub Debian check
#
# Default mode reads docker/Dockerfile, docker/runner.sh and the release workflow from the
# WORKING TREE and the api/front gitlinks from the INDEX (`git ls-files -s`), so a bump being
# prepared (gitlinks staged) is checked before it is committed.
#
# Checks (one line each: OK / WARN / FAIL / INFO):
#   ruby      ARG RUBY_VERSION == lago-api .ruby-version == Gemfile `ruby "x"`   (else bundle install exits 18)
#   node      ARG NODE_VERSION major == lago-front engines.node major   (FAIL = policy guard; exact patch: WARN only)
#   bundler   ENV BUNDLER_VERSION vs Gemfile.lock BUNDLED WITH (ENV disables Bundler auto-switch)
#   pnpm      corepack prepare pnpm@<x> vs lago-front packageManager; --frozen-lockfile
#   without   no `bundle install --without` (removed in Bundler 4; v1.45.0 breakage)
#   debian    the Debian release behind ruby:<v>-slim ships the postgresql-NN the Dockerfile installs
#             (trixie=17, bookworm=15; the PGDG apt line in docker/Dockerfile is broken)   (network)
#   seed      runner.sh runs roles:seed_predefined before signup:seed_organization when lago-api's
#             scripts/migrate.sh does (v1.41.1 breakage, fixed by fd77a74)
#   workflow  release-docker-image.yml checks out with submodules: true          (first-release breakage)
# Exit: 0 no FAIL; 1 at least one FAIL; 2 usage error; 3 could not read a source (network / sha).
set -euo pipefail
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
# No auto-gc / auto-maintenance in the shared history clone while lazy blob fetches add objects
# (other agents may be reading it): every git call on a clone goes through gitc.
gitc() { git -c gc.auto=0 -c maintenance.auto=false -C "$@"; }
ref=""; offline=0
need() { [ -n "$2" ] || { echo "single-image-pins: $1" >&2; exit 2; }; }   # missing option value = usage error
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     need "--ref needs a tag or commit" "${2:-}"; ref="$2"; shift 2;;
    --offline) offline=1; shift;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0;;
    *) echo "single-image-pins: unknown argument: $1" >&2; exit 2;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git rev-parse --show-toplevel 2>/dev/null || gitc "$here" rev-parse --show-toplevel)"
# Foundation scripts: next to THIS script first (works on a release branch cut from a main
# that does not carry .claude/skills), else in the checkout being audited.
rm_dir="$(cd "$here/../.." && pwd)/research-methodology/scripts"
[ -x "$rm_dir/pinned-checkout.sh" ] || rm_dir="$repo/.claude/skills/research-methodology/scripts"
pco="$rm_dir/pinned-checkout.sh"
fails=0
ok()   { printf 'OK    %-8s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-8s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-8s %s\n' "$1" "$2"; fails=$((fails+1)); }
info() { printf 'INFO  %-8s %s\n' "$1" "$2"; }

# --- resolve sources -----------------------------------------------------------------
if [ -z "$ref" ]; then
  src="working tree + index"
  rd() { cat "$repo/$1"; }
  api_sha="$(gitc "$repo" ls-files -s api | awk '{print $2}')"
  front_sha="$(gitc "$repo" ls-files -s front | awk '{print $2}')"
else
  H="$("$rm_dir/history-setup.sh")"
  c=""
  if [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    lr="$(git ls-remote --tags https://github.com/getlago/lago "refs/tags/$ref" "refs/tags/$ref^{}")" \
      || { echo "single-image-pins: git ls-remote failed" >&2; exit 3; }
    c="$(awk '/\^\{\}$/ {p=$1} !/\^\{\}$/ {t=$1} END {print (p!="")?p:t}' <<<"$lr")"
    [ -n "$c" ] || { echo "single-image-pins: getlago/lago has no tag $ref" >&2; exit 2; }
  fi
  if g="$repo" && gitc "$g" cat-file -e "${c:-$ref}^{commit}" 2>/dev/null; then :
  elif g="$H" && gitc "$g" cat-file -e "${c:-$ref}^{commit}" 2>/dev/null; then :
  else echo "single-image-pins: cannot resolve $ref in the working or history clone" >&2; exit 2; fi
  c="$(gitc "$g" rev-parse "${c:-$ref}^{commit}")"
  src="$ref (${c:0:7})"
  rd() { gitc "$g" show "$c:$1"; }
  api_sha="$(gitc "$g" rev-parse "$c:api")"; front_sha="$(gitc "$g" rev-parse "$c:front")"
fi
API="$("$pco" api "$api_sha")" || { echo "single-image-pins: cannot check out lago-api@$api_sha" >&2; exit 3; }
FRONT="$("$pco" front "$front_sha")" || { echo "single-image-pins: cannot check out lago-front@$front_sha" >&2; exit 3; }
DF="$(rd docker/Dockerfile)" || { echo "single-image-pins: cannot read docker/Dockerfile" >&2; exit 3; }
RUNNER="$(rd docker/runner.sh 2>/dev/null || true)"
WF="$(rd .github/workflows/release-docker-image.yml 2>/dev/null || true)"
info source "umbrella=$src  lago-api@${api_sha:0:7}  lago-front@${front_sha:0:7}"

# --- read values -----------------------------------------------------------------------
d_ruby="$(sed -n -E 's/^ARG RUBY_VERSION=([^[:space:]]+).*/\1/p' <<<"$DF" | head -1)"
d_node="$(sed -n -E 's/^ARG NODE_VERSION=([^[:space:]]+).*/\1/p' <<<"$DF" | head -1)"
d_bundler="$(sed -n -E "s/^ENV BUNDLER_VERSION=['\"]?([^'\"[:space:]]+).*/\1/p" <<<"$DF" | head -1)"
d_pnpm="$(grep -o -E 'corepack prepare pnpm@[^[:space:]]+' <<<"$DF" | head -1 | sed 's/.*pnpm@//' || true)"
a_ruby="$(tr -d '[:space:]' < "$API/.ruby-version" 2>/dev/null || true)"
a_gemruby="$(sed -n -E 's/^ruby ["'"'"']([^"'"'"']+)["'"'"'].*/\1/p' "$API/Gemfile" 2>/dev/null | head -1)"
a_bundled="$(awk '/^BUNDLED WITH/ {getline; gsub(/[[:space:]]/,""); print}' "$API/Gemfile.lock" 2>/dev/null)"
f_node="$(jq -r '.engines.node // empty' "$FRONT/package.json" 2>/dev/null || true)"
f_pm="$(jq -r '.packageManager // empty' "$FRONT/package.json" 2>/dev/null || true)"
major() { sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$1"; }

# --- ruby ------------------------------------------------------------------------------
if [ -z "$d_ruby" ] || [ -z "$a_ruby" ]; then fail ruby "cannot read versions (Dockerfile='$d_ruby' api/.ruby-version='$a_ruby')"
elif [ "$d_ruby" = "$a_ruby" ] && { [ -z "$a_gemruby" ] || [ "$a_gemruby" = "$a_ruby" ]; }; then
  ok ruby "docker/Dockerfile RUBY_VERSION=$d_ruby == api/.ruby-version=$a_ruby == Gemfile ruby \"${a_gemruby:-n/a}\""
else
  fail ruby "docker/Dockerfile RUBY_VERSION=$d_ruby but api/.ruby-version=$a_ruby, Gemfile ruby \"$a_gemruby\" -> bundle install aborts (\"Your Ruby version is $d_ruby, but your Gemfile specified $a_gemruby\", exit 18)"
fi
# --- node ------------------------------------------------------------------------------
if [ -z "$d_node" ] || [ -z "$f_node" ]; then warn node "cannot compare (Dockerfile NODE_VERSION='$d_node', front engines.node='$f_node')"
elif [ "$(major "$d_node")" != "$(major "$f_node")" ]; then
  fail node "docker/Dockerfile NODE_VERSION=$d_node but front engines.node=$f_node (major differs; policy guard: pnpm ignores the root engines field and Node 20 built v1.37.0..v1.52.1, but the v1.53.0 release needed b267320: keep majors equal)"
elif [ "$d_node" != "$f_node" ]; then
  warn node "NODE_VERSION=$d_node (floating: newest $d_node.x at build time) vs front engines.node=$f_node; pnpm does not enforce the root engines field"
else ok node "NODE_VERSION=$d_node == front engines.node"; fi
# --- bundler ---------------------------------------------------------------------------
if [ -z "$d_bundler" ] || [ -z "$a_bundled" ]; then warn bundler "cannot compare (Dockerfile='$d_bundler', Gemfile.lock BUNDLED WITH='$a_bundled')"
elif [ "$(major "$d_bundler")" != "$(major "$a_bundled")" ]; then
  fail bundler "ENV BUNDLER_VERSION=$d_bundler vs Gemfile.lock BUNDLED WITH $a_bundled (major differs)"
elif [ "$d_bundler" != "$a_bundled" ]; then
  warn bundler "ENV BUNDLER_VERSION=$d_bundler vs Gemfile.lock BUNDLED WITH $a_bundled (ENV disables Bundler auto-switch: gems install with $d_bundler)"
else ok bundler "BUNDLER_VERSION=$d_bundler == BUNDLED WITH"; fi
if ! grep -q -E 'bundle install[^&|;]*--without' <<<"$DF"; then ok without "no 'bundle install --without' (Bundler 4 safe)"
elif [ -n "$d_bundler" ] && [ "$(major "$d_bundler")" -ge 4 ]; then
  fail without "docker/Dockerfile uses 'bundle install --without' with Bundler $d_bundler (flag removed in Bundler 4; v1.45.0 breakage, fixed by 558814a)"
else warn without "'bundle install --without' works on Bundler ${d_bundler:-?} but breaks the day Bundler moves to 4 (558814a)"; fi
# --- pnpm ------------------------------------------------------------------------------
if [ -z "$f_pm" ]; then
  if [ "$d_pnpm" = latest ]; then fail pnpm "front has no packageManager field, so corepack really runs pnpm@latest (v1.35.0 breakage class)"
  else warn pnpm "front has no packageManager field; Dockerfile prepares pnpm@${d_pnpm:-?}"; fi
elif [ "$d_pnpm" = latest ]; then
  warn pnpm "Dockerfile prepares pnpm@latest (downloaded every build, unused); inside /app corepack runs front's $f_pm"
elif [ -n "$d_pnpm" ] && [ "pnpm@$d_pnpm" != "$f_pm" ]; then
  warn pnpm "Dockerfile prepares pnpm@$d_pnpm but front packageManager is $f_pm (corepack uses $f_pm inside /app)"
else ok pnpm "pnpm pinned by front packageManager $f_pm"; fi
if grep -q -E 'pnpm install[^&|;]*--frozen-lockfile' <<<"$DF"; then ok lockfile "pnpm install --frozen-lockfile"
else warn lockfile "pnpm install without --frozen-lockfile (lockfile drift is silently re-resolved; front's own Dockerfile uses --frozen-lockfile)"; fi
# --- debian base -----------------------------------------------------------------------
if [ "$offline" = 1 ] || [ -z "$d_ruby" ]; then info debian "skipped (offline)"
elif [ "$(curl -s -o /dev/null -w '%{http_code}' https://hub.docker.com/v2/repositories/library/ruby/ || true)" != 200 ]; then
  warn debian "Docker Hub API unreachable: Debian/PostgreSQL check skipped (re-run with network, or pass --offline)"
else
  dg() { curl -sS "https://hub.docker.com/v2/repositories/library/ruby/tags/$1" | jq -r '.digest // empty' 2>/dev/null || true; }
  base="$(dg "$d_ruby-slim")"; tri="$(dg "$d_ruby-slim-trixie")"; bwm="$(dg "$d_ruby-slim-bookworm")"
  pg="$(grep -o -E 'postgresql-[0-9]+' <<<"$DF" | head -1 | sed 's/postgresql-//' || true)"
  if [ -z "$base" ]; then fail debian "ruby:$d_ruby-slim not found on Docker Hub (or API unreachable)"
  elif [ "$base" = "$tri" ]; then
    if [ "$pg" = 17 ]; then ok debian "ruby:$d_ruby-slim == ruby:$d_ruby-slim-trixie; postgresql-17 (+partman) come from Debian trixie main"
    else fail debian "ruby:$d_ruby-slim is trixie (ships PostgreSQL 17) but the Dockerfile installs postgresql-$pg; the PGDG apt line is broken, so it cannot come from there (v1.33.0-v1.33.2 breakage)"; fi
  elif [ -n "$bwm" ] && [ "$base" = "$bwm" ]; then
    if [ "$pg" = 15 ]; then ok debian "ruby:$d_ruby-slim is bookworm; postgresql-15 comes from Debian main"
    else fail debian "ruby:$d_ruby-slim is bookworm (ships PostgreSQL 15) but the Dockerfile installs postgresql-$pg and the PGDG apt line is broken"; fi
  else warn debian "ruby:$d_ruby-slim is neither -trixie nor -bookworm: check that postgresql-$pg is in its Debian main before release"; fi
fi
# --- runner.sh seed order --------------------------------------------------------------
if [ -z "$RUNNER" ]; then warn seed "docker/runner.sh not found"
elif ! grep -q 'seed_predefined' "$API/scripts/migrate.sh" 2>/dev/null; then
  info seed "lago-api@${api_sha:0:7} scripts/migrate.sh has no roles:seed_predefined step (check not applicable)"
else
  rl="$(grep -n 'roles:seed_predefined' <<<"$RUNNER" | head -1 | cut -d: -f1 || true)"
  sl="$(grep -n 'signup:seed_organization' <<<"$RUNNER" | head -1 | cut -d: -f1 || true)"
  if [ -n "$rl" ] && [ -n "$sl" ] && [ "$rl" -lt "$sl" ]; then ok seed "runner.sh seeds roles (L$rl) before the organization (L$sl), like api/scripts/migrate.sh"
  else fail seed "runner.sh must run 'rake roles:seed_predefined' before 'rails signup:seed_organization' (fd77a74)"; fi
fi
# --- release workflow ------------------------------------------------------------------
if [ -z "$WF" ]; then warn workflow "release-docker-image.yml not found at this ref"
elif grep -q -E 'submodules:[[:space:]]*true' <<<"$WF"; then ok workflow "release-docker-image.yml checks out submodules (c91af2b)"
else fail workflow "release-docker-image.yml checks out WITHOUT submodules: the image would have empty api/ and front/"; fi
echo "# fails=$fails"
[ "$fails" -eq 0 ]
