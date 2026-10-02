#!/usr/bin/env bash
# bool-semantics.sh - list every read of ONE environment variable in lago-api (pinned SHA) and in the
# events-processor Go code, classify each read idiom, print how each idiom interprets the values people
# actually type (unset, "", true, false, 0, no, False, 1, " "), and say whether the reads AGREE.
# Read-only. The lago-api checkout comes from the research-methodology foundation script.
#
# Usage (from anywhere inside the repo):
#   .claude/skills/config-and-flags/scripts/bool-semantics.sh [--api DIR | --no-api] VAR
#   e.g. bool-semantics.sh LAGO_CLICKHOUSE_ENABLED   -> MIXED (.present? in store_factory.rb:10 ...)
#
# Idioms (family in brackets; ON = the guarded code path runs):
#   PRESENT    [present]   Ruby .present? / .blank? / shell -n : ON for any non-blank string, "false" included
#   EQ_TRUE    [eq_true]   == "true" (Ruby, shell, Go)         : ON only for the exact lowercase string "true"
#   BOOL_CAST  [bool_cast] ActiveModel::Type::Boolean.cast     : off for false/0/f/F/FALSE/off/OFF and ""; ON for anything else ("no", "False")
#   TRUTHY     [truthy]    if ENV["X"] / ENV.key?("X") / -v    : ON whenever the variable is SET, even to "" or "false"
#   PARSEBOOL  [parsebool] Go utils.GetEnvAsBool(X, def)        : strconv.ParseBool; unparsable ("", "yes", "no", " ") -> def
#   value idioms (not booleans): FETCH (ENV.fetch: "" is kept, default only when UNSET), PRESENCE (.presence:
#   "" -> default), OR_FALLBACK (ENV["A"] || x: "" wins), NUM (.to_i/.to_f: leading digits, "5m" -> 5, "abc" -> 0),
#   RAW, GO_ATOI (junk -> error),
#   GO_DEFAULT ("" -> default), GO_RAW, INDIRECT (const passed to a helper; read that helper)
#
# Exit codes: 0 = reads found, a single boolean family (or a plain value variable)
#             1 = reads found, MIXED boolean families (the same string means different things at different sites)
#             2 = usage error
#             3 = no reads found, or lago-api checkout unavailable (use --no-api to skip it)
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

API_DIR="${API:-}"; USE_API=1; VAR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --api) [ $# -ge 2 ] || { echo "--api needs a directory" >&2; exit 2; }; API_DIR="$2"; shift 2 ;;
    --no-api) USE_API=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    *) [ -z "$VAR" ] || { echo "only one VAR at a time" >&2; exit 2; }; VAR="$1"; shift ;;
  esac
done
[ -n "$VAR" ] || { usage >&2; exit 2; }
[[ "$VAR" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "VAR must look like an env name (A-Z0-9_): '$VAR'" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside the lago repo" >&2; exit 3; }
if [ "$USE_API" = 1 ] && [ -z "$API_DIR" ]; then
  API_DIR="$("$ROOT/.claude/skills/research-methodology/scripts/pinned-checkout.sh" api 2>/dev/null)" \
    || { echo "cannot obtain the pinned lago-api checkout; pass --api DIR or --no-api" >&2; exit 3; }
fi
if [ "$USE_API" = 1 ] && [ ! -d "$API_DIR/app" ]; then echo "lago-api checkout not found at '$API_DIR'" >&2; exit 3; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
: > "$WORK/sites"   # lines: LANG<TAB>LOCATION<TAB>IDENT<TAB>CODE

# lago-api: Ruby / YAML-ERB / rake / rackup reads, and shell scripts
if [ "$USE_API" = 1 ]; then
  grep -rnE --include='*.rb' --include='*.yml' --include='*.erb' --include='*.rake' --include='*.ru' \
      "ENV(\[|\.fetch\(|\.key\?\()[[:space:]]*[\"']$VAR[\"']" "$API_DIR" 2>/dev/null \
    | sed -E "s#^$API_DIR/##" | grep -vE '^(spec|\.github)/' \
    | sed -E 's#^([^:]+):([0-9]+):#rb\t$API/\1:\2\t-\t#' >> "$WORK/sites" || true
  grep -rnE --include='*.sh' "(\\\$\{?$VAR\b|-v $VAR\b)" "$API_DIR/scripts" 2>/dev/null \
    | sed -E "s#^$API_DIR/##" \
    | sed -E 's#^([^:]+):([0-9]+):#sh\t$API/\1:\2\t-\t#' >> "$WORK/sites" || true
fi

# events-processor: literal "VAR" in non-test Go; a const declaration is resolved to its use sites
EP="$ROOT/events-processor"
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; code="${rest#*:}"
  rel="${file#"$ROOT"/}"
  if [[ "$code" =~ ^[[:space:]]*(env[A-Za-z0-9]*)[[:space:]]*=[[:space:]]*\"$VAR\" ]]; then
    ident="${BASH_REMATCH[1]}"; dir="$(dirname "$file")"
    uses="$(grep -rnw --include='*.go' --exclude='*_test.go' -e "$ident" "$dir" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*$ident[[:space:]]*=" || true)"
    if [ -z "$uses" ]; then
      printf 'go\t%s:%s\t%s\t%s\n' "$rel" "$line" "$ident" "DEAD const (declared, never read)" >> "$WORK/sites"
    else
      while IFS= read -r u; do
        uf="${u%%:*}"; ur="${u#*:}"; ul="${ur%%:*}"; uc="${ur#*:}"
        printf 'go\t%s:%s\t%s\t%s\n' "${uf#"$ROOT"/}" "$ul" "$ident" "$uc" >> "$WORK/sites"
      done <<< "$uses"
    fi
  else
    printf 'go\t%s:%s\t%s\t%s\n' "$rel" "$line" "\"$VAR\"" "$code" >> "$WORK/sites"
  fi
done < <(grep -rn --include='*.go' --exclude='*_test.go' -e "\"$VAR\"" "$EP" 2>/dev/null || true)

if [ ! -s "$WORK/sites" ]; then
  echo "no reads of $VAR found in ${API_DIR:+lago-api ($API_DIR) or }events-processor" >&2
  exit 3
fi

# where this repo sets it (first non-comment hit per file)
SETS=""
for f in .env.development.default docker-compose.dev.yml docker-compose.yml deploy/docker-compose.local.yml \
         deploy/docker-compose.light.yml deploy/docker-compose.production.yml docker/runner.sh examples/agentic-ai-demo/compose.yml; do
  hit="$(grep -nE "(^|[^A-Z0-9_])$VAR([^A-Z0-9_]|$)" "$ROOT/$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 || true)"
  [ -n "$hit" ] && SETS="$SETS  $f:${hit%%:*}  $(echo "${hit#*:}" | sed -E 's/^[[:space:]]+//' | cut -c1-90)"$'\n'
done

API_SHA=""; [ "$USE_API" = 1 ] && API_SHA="$(git -C "$API_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
export VAR API_SHA SETS
export EP_SHA="$(git -C "$ROOT" log -1 --format=%h -- events-processor 2>/dev/null)"

perl -e '
use strict; use warnings;
my $V = $ENV{VAR};
my @vals = (undef, "", "true", "false", "0", "no", "False", "1", " ");
my @labels = ("<unset>", q(""), q("true"), q("false"), q("0"), q("no"), q("False"), q("1"), q(" "));
my %fam = (PRESENT=>"present", EQ_TRUE=>"eq_true", BOOL_CAST=>"bool_cast", TRUTHY=>"truthy", PARSEBOOL=>"parsebool");
my @FALSEV = qw(0 f F false FALSE off OFF);
sub on {   # returns 1 / 0 / undef(unknown) for family f, value v, default d (parsebool only)
  my ($f, $v, $d) = @_;
  return (defined $v && $v !~ /^\s*$/) ? 1 : 0 if $f eq "present";
  return (defined $v && $v eq "true") ? 1 : 0 if $f eq "eq_true";
  if ($f eq "bool_cast") { return 0 if !defined $v || $v eq ""; return (grep { $_ eq $v } @FALSEV) ? 0 : 1 }
  return defined $v ? 1 : 0 if $f eq "truthy";
  if ($f eq "parsebool") {
    if (defined $v && $v =~ /^(1|t|T|TRUE|true|True)$/) { return 1 }
    if (defined $v && $v =~ /^(0|f|F|FALSE|false|False)$/) { return 0 }
    return $d eq "true" ? 1 : $d eq "false" ? 0 : undef;
  }
  return undef;
}
my (@rows, %famsites);
open my $fh, "<", $ARGV[0] or die;
while (my $l = <$fh>) {
  chomp $l; my ($lang, $loc, $id, $code) = split /\t/, $l, 4;
  my ($idiom, $note) = ("RAW", "");
  my $q = qr/["\x27]\Q$V\E["\x27]/;
  if ($lang eq "rb") {
    if    ($code =~ /ActiveModel::Type::Boolean\.new\.cast\(\s*ENV\[\s*$q\s*\]\s*\)/) { $idiom = "BOOL_CAST" }
    elsif ($code =~ /ENV\[\s*$q\s*\]\s*[!=]=\s*["\x27]true["\x27]/ || $code =~ /ENV\.fetch\(\s*$q[^)]*\)\s*[!=]=\s*["\x27]true["\x27]/) { $idiom = "EQ_TRUE"; $note = "guarded by .present?" if $code =~ /ENV\[\s*$q\s*\]\.present\?/ }
    elsif ($code =~ /ENV\[\s*$q\s*\]\.(present\?|blank\?)/) { $idiom = "PRESENT"; $note = ".$1" }
    elsif ($code =~ /ENV\[\s*$q\s*\]\.presence/) { $idiom = "PRESENCE" }
    elsif ($code =~ /ENV\.key\?\(\s*$q\s*\)/) { $idiom = "TRUTHY"; $note = "ENV.key?" }
    elsif ($code =~ /ENV\.fetch\(\s*$q\s*(?:,\s*([^)]*))?\)/) { $idiom = "FETCH"; $note = defined $1 ? "default $1" : "no default: KeyError if unset" }
    elsif ($code =~ /ENV\[\s*$q\s*\]\s*\|\|/) { $idiom = "OR_FALLBACK" }
    elsif ($code =~ /ENV\[\s*$q\s*\]\.to_[if]/) { $idiom = "NUM" }
    elsif ($code =~ /\b(?:if|unless)\s+ENV\[\s*$q\s*\]\s*(?:$|then|#|\)|%>)/ || $code =~ /ENV\[\s*$q\s*\]\s*\?/) { $idiom = "TRUTHY"; $note = "if ENV[..]" }
  } elsif ($lang eq "sh") {
    if    ($code =~ /"?\$\{?\Q$V\E\}?"?\s*==?\s*"?true"?/) { $idiom = "EQ_TRUE"; $note = "shell" }
    elsif ($code =~ /-n\s+"?\$\{?\Q$V\E/) { $idiom = "PRESENT"; $note = "shell -n" }
    elsif ($code =~ /-v\s+\Q$V\E\b/) { $idiom = "TRUTHY"; $note = "shell -v" }
  } elsif ($lang eq "go") {
    my $i = quotemeta($id);
    if    ($code =~ /^DEAD/) { $idiom = "DEAD" }
    elsif ($code =~ /os\.Getenv\(\s*$i\s*\)\s*==\s*"true"/) { $idiom = "EQ_TRUE"; $note = "Go" }
    elsif ($code =~ /GetEnvAsBool\(\s*$i\s*,\s*([^)]+)\)/) { $idiom = "PARSEBOOL"; $note = "default $1" }
    elsif ($code =~ /GetEnvAsInt\(\s*$i\s*,\s*([^)]+)\)/) { $idiom = "GO_ATOI"; $note = "default $1; junk -> error" }
    elsif ($code =~ /GetEnvOrDefault\(\s*$i\s*,\s*([^)]+)\)/) { $idiom = "GO_DEFAULT"; $note = "default $1" }
    elsif ($code =~ /os\.Getenv\(\s*$i\s*\)/) { $idiom = "GO_RAW" }
    elsif ($code =~ /(\w+)\([^()]*\b$i\b/) { $idiom = "INDIRECT"; $note = "passed to $1()" }
  }
  (my $c = $code) =~ s/^\s+//; $c = substr($c, 0, 96);
  push @rows, [$idiom, $loc, $note, $c];
  if (my $f = $fam{$idiom}) { my $d = ""; ($d) = $note =~ /default (\S+)/ if $f eq "parsebool"; push @{$famsites{"$f|$d"}}, $loc }
}
my $hdr = "bool-semantics $V  (lago-api " . ($ENV{API_SHA} ne "" ? "\@$ENV{API_SHA}" : "not read") . "; events-processor \@$ENV{EP_SHA})";
print "$hdr\n\nRead sites (" . scalar(@rows) . "):\n";
printf "  %-10s %-70s %s\n", "IDIOM", "WHERE", "NOTE | CODE";
printf "  %-10s %-70s %s\n", $_->[0], $_->[1], ($_->[2] ne "" ? "$_->[2] | " : "") . $_->[3] for sort { my ($fa, $la) = $a->[1] =~ /^(.*):(\d+)$/; my ($fb, $lb) = $b->[1] =~ /^(.*):(\d+)$/; $fa cmp $fb || $la <=> $lb } @rows;
print "\nSet in this repo:\n" . ($ENV{SETS} ne "" ? $ENV{SETS} : "  (nowhere: not in .env.development.default, compose files, deploy/*.yml, runner.sh, demo)\n");
my @fk = sort keys %famsites;
if (!@fk) { print "\nVerdict: VALUE - no boolean idiom; the string is used as-is (see NOTE for empty/unset handling).\n"; exit 0 }
print "\nTruth table (ON = guarded path runs; ? = depends on a runtime default):\n";
printf "  %-9s", "value"; for my $k (@fk) { my ($f, $d) = split /\|/, $k; printf " %-16s", $f . ($d ne "" ? "($d)" : "") . "[" . scalar(@{$famsites{$k}}) . "]" } print "\n";
my (@disagree, @allon, @alloff);
for my $j (0..$#vals) {
  printf "  %-9s", $labels[$j]; my %seen;
  for my $k (@fk) { my ($f, $d) = split /\|/, $k; my $r = on($f, $vals[$j], $d); printf " %-16s", !defined $r ? "?" : $r ? "ON" : "off"; $seen{defined $r ? $r : "?"}++ }
  print "\n";
  my @s = keys %seen;
  if (@s > 1) { push @disagree, $labels[$j] } elsif ($s[0] eq "1") { push @allon, $labels[$j] } elsif ($s[0] eq "0") { push @alloff, $labels[$j] }
}
my %distinct = map { (split /\|/)[0] => 1 } @fk;
if (keys %distinct > 1 && @disagree) {
  print "\nVerdict: MIXED - " . join(", ", @disagree) . " mean different things at different read sites.\n";
  print "  Safe to turn ON everywhere : " . (@allon ? join(" ", @allon) : "(no single value)") . "\n";
  print "  Safe to turn OFF everywhere: " . (@alloff ? join(" ", @alloff) : "(no single value)") . "\n";
  exit 1;
}
print "\nVerdict: UNIFORM - every boolean read uses the same family (" . join(", ", sort keys %distinct) . ").\n";
print "  ON : " . join(" ", @allon) . "\n  OFF: " . join(" ", @alloff) . "\n";
exit 0;
' "$WORK/sites"
