#!/usr/bin/env bash
# evidence-check.sh — citation lint for Markdown (change-control N13: claims carry evidence).
# Flags bullet and table-row "claims" that carry none of:
#   path:line (e.g. `events-processor/config/kafka/consumer.go:97`, `$API/clock.rb:210`),
#   a commit sha (7-40 hex with a letter and a digit; all-digit only as a backticked 7-char),
#   a PR/issue ref ((#123), #123+, lago-deploy#3331), a backticked command
#   (`git ...`, `curl ...`, `.claude/.../x.sh`, `go test ...`), a sibling-doctrine ref
#   (change-control N7), or a backticked sibling skill name (`rails-go-parity`: the
#   evidence lives in that skill).
# Lines labeled UNVERIFIED / OPEN DECISION / OD-n / CANDIDATE / TARGET / not runnable
# are honest and NOT flagged (counted as "labeled").
# Not claims (skipped): YAML front matter, fenced code, table header/separator rows,
# bullets ending with ":" (intros), checklist items ("- [ ]"), bullets under 4 words,
# lines linking reference/*.md, sections whose heading matches --skip, bullets under a
# plain label line matching --skip (e.g. "Update triggers:"), and blocks fenced by
# <!-- evidence-check: off <reason> --> ... <!-- evidence-check: on --> (use for procedure or
# normative text whose evidence sits in an adjacent code block; reviewers see the marker).
# --all-sections disables heading/label skipping (markers still apply).
#
# Usage:
#   .claude/skills/research-methodology/scripts/evidence-check.sh .claude/skills/*/SKILL.md
#   .../evidence-check.sh --explain path/to/file.md     # classify every claim line (E/L/F)
#   .../evidence-check.sh -q docs/*.md                   # summaries only
#   .../evidence-check.sh --skip 'When to use|Terms' f.md
# Output: "<file>:<line>: no evidence: <text>" per flagged claim (stdout);
#         "evidence-check: <file>: claims=N evidenced=E labeled=L flagged=F" (stderr).
# Exit: number of flagged claims across all files (capped at 255); 2 usage error.
#   (Exit 2 is ambiguous: a usage error prints "evidence-check: <reason>" to stderr and
#   no "claims=" summary line. Gate on "exit 0" = nothing flagged.)
# Heuristic, not proof: a flagged line may be fine (e.g. a plain definition); an
# evidenced line may still be wrong. Read flagged lines; do not game the regexes.
set -euo pipefail
quiet=0; explain=0
skip='When to use|when NOT to use|^Use when|^Do NOT use|^Terms|Contents|See also|Related skills|Update triggers'
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet)     quiet=1; shift;;
    --explain)      explain=1; shift;;
    --skip)         skip="${2:?--skip needs a regex}"; shift 2;;
    --all-sections) skip='(?!)'; shift;;
    -h|--help)      awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0;;
    --) shift; files+=("$@"); break;;
    -*) echo "evidence-check: unknown option $1" >&2; exit 2;;
    *)  files+=("$1"); shift;;
  esac
done
[ "${#files[@]}" -gt 0 ] || { echo "evidence-check: no files given (see --help)" >&2; exit 2; }
for f in "${files[@]}"; do [ -r "$f" ] || { echo "evidence-check: cannot read $f" >&2; exit 2; }; done

skills_root="$(cd "$(dirname "$0")/../.." && pwd)"
siblings="change-control failure-archaeology architecture-contract rails-go-parity domain-reference config-and-flags build-and-env run-and-operate release-and-images debugging-playbook diagnostics-and-tooling validation-and-qa docs-and-writing security-and-supply-chain event-accounting-campaign research-methodology"
for d in "$skills_root"/*/; do [ -d "$d" ] && siblings="$siblings $(basename "$d")"; done

set +e
SIBLINGS="$siblings" QUIET=$quiet EXPLAIN=$explain SKIP="$skip" perl -e '
use strict; use warnings;
my ($quiet,$explain,$skip) = ($ENV{QUIET},$ENV{EXPLAIN},$ENV{SKIP});
my %sib = map { $_ => 1 } split /\s+/, ($ENV{SIBLINGS} // "");
my $cmd = qr{^(?:[A-Z_][A-Z0-9_]*=\S*\s+)*(?:git|grep|rg|sed|awk|curl|go|gofmt|golangci-lint|docker|psql|pg_isready|pg_ctlcluster|bash|sh|make|find|ls|cat|jq|python3?|perl|gh|cargo|ldd|env|export|source|cd|wc|sort|diff|head|tail|echo|printf|kubectl|clickhouse|actionlint|shellcheck|mise|rpk|bundle|rails|rspec|stat|uniq|tr|cut|xargs|timeout|mktemp|openssl|redis-cli|readlink|command|type|npm|pnpm|test|\.{0,2}/\S+|\.claude/\S+|\$[A-Za-z_]+/\S+|\S+\.sh)(?:\s|$)};
my $total = 0;
for my $file (@ARGV) {
  open(my $fh, "<", $file) or die "cannot read $file\n";
  my @L = <$fh>; close $fh; chomp @L;
  my ($n,$e,$lab,$fl) = (0,0,0,0);
  my ($infence,$infront,$section,$off,$labskip) = (0,0,"",0,0);
  my @units;            # [lineno, text]
  for (my $i=0; $i<@L; $i++) {
    my $l = $L[$i];
    if ($i==0 && $l =~ /^---\s*$/) { $infront=1; next }
    if ($infront) { $infront=0 if $l =~ /^---\s*$/; next }
    if ($l =~ /^\s*(```|~~~)/) { $infence = !$infence; next }
    next if $infence;
    if ($l =~ /<!--\s*evidence-check:\s*off\b.*-->/) { $off = 1; next }     # "off <reason>" allowed
    if ($l =~ /<!--\s*evidence-check:\s*on\b.*-->/)  { $off = 0; next }
    next if $off;
    if ($l =~ /^\s{0,3}#{1,6}\s+(.*)$/) { $section = $1; $labskip = 0; next }
    next if $section =~ /$skip/i;
    if ($l =~ /^\S/ && $l !~ /^(?:[-*+]|\d+[.)])\s/ && $l !~ /^\|/) {           # plain text line
      my $lab = $l; $lab =~ s/[*_`]//g;
      $labskip = ($lab =~ /:\s*$/ && $lab =~ /$skip/i) ? 1 : 0;
      next;
    }
    next if $labskip && $l =~ /^\s*(?:[-*+]|\d+[.)])\s/;
    if ($l =~ /^\s*\|/) {
      next if $l =~ /^\s*\|?[\s:|-]+\|?\s*$/ && $l =~ /---/;                        # separator
      next if $i+1 < @L && $L[$i+1] =~ /^\s*\|?\s*:?-{3,}/;                          # header row
      push @units, [$i+1, $l]; next;
    }
    if ($l =~ /^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$/) {
      my ($ind,$txt) = (length $1, $2);
      my $j = $i+1;                                                                # continuation lines
      while ($j < @L && $L[$j] =~ /^\s+\S/ && $L[$j] !~ /^\s*(?:[-*+]|\d+[.)])\s+/ && $L[$j] !~ /^\s*(\||```|~~~)/) {
        $txt .= " " . $L[$j]; $j++;
      }
      push @units, [$i+1, $txt];
    }
  }
  for my $u (@units) {
    my ($ln,$t) = @$u;
    my $plain = $t; $plain =~ s/`[^`]*`/X/g;
    next if $t =~ /reference\/[\w.-]+\.md/;                                        # navigation
    next if $plain =~ /:[\s*_]*$/;                                                 # intro bullet ("**Label:**" too)
    next if $t =~ /^\s*\[[ xX]\]\s/;                                               # checklist item
    my @w = split /\s+/, $t; next if @w < 4 && $t !~ /^\s*\|/;
    $n++;
    my $cls = "F";
    my $ev = 0;
    $ev ||= $t =~ m{[A-Za-z0-9_./\$\@{}~-]*[A-Za-z0-9_-]\.[A-Za-z0-9_]+:\d+};         # file.ext:line
    $ev ||= $t =~ m{(?:^|[\s`(/])\.[A-Za-z]\w*:\d+};                               # .dotfile:line
    $ev ||= $t =~ m{(?:Dockerfile|Makefile|Procfile|Gemfile)[\w.-]*:\d+};
    $ev ||= $t =~ m{[\w.-]+/[\w./-]+:\d+};                                         # dir/file:line
    $ev ||= $t =~ m{(?<![0-9A-Za-z])(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}(?![0-9A-Za-z])};
    $ev ||= $t =~ m{`[0-9]{7}`};
    $ev ||= $t =~ m{\(#\d+\)|[A-Za-z][\w.-]*#\d+|#\d{3,}};
    $ev ||= $t =~ m{change-control\s+N\d+};
    if (!$ev) { while ($t =~ /`([a-z][a-z-]+)`/g) { if ($sib{$1}) { $ev=1; last } } }        # sibling skill ref
    if (!$ev) { while ($t =~ /`([^`]+)`/g) { my $c=$1; $c =~ s/^\s+//; if ($c =~ $cmd) { $ev=1; last } } }
    if ($ev) { $cls="E"; $e++ }
    elsif ($t =~ /UNVERIFIED|OPEN DECISION|\bOD-\d|CANDIDATE|\bTARGET|not runnable/i) { $cls="L"; $lab++ }
    else { $fl++; print "$file:$ln: no evidence: " . substr($t =~ s/^\s+//r, 0, 110) . "\n" unless $quiet || $explain }
    if ($explain) { print "$cls $file:$ln: " . substr($t =~ s/^\s+//r, 0, 100) . "\n" }
  }
  print STDERR "evidence-check: $file: claims=$n evidenced=$e labeled=$lab flagged=$fl\n";
  $total += $fl;
}
exit($total > 255 ? 255 : $total);
' "${files[@]}"
rc=$?
set -e
exit "$rc"
