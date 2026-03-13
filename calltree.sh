#!/usr/bin/env bash
# callgraph.sh — ASCII call graph for functions within a single C++ file
# Usage: ./callgraph.sh <file.cpp> [--depth N] [--root func_name]
# Deps : bash + perl (standard on any Linux/macOS)
set -euo pipefail

# -- Args ----------------------------------------------
FILE="" MAX_DEPTH=4 ROOT_FUNC=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --depth) MAX_DEPTH=$2; shift 2 ;;
    --root)  ROOT_FUNC=$2; shift 2 ;;
    *)       FILE=$1; shift ;;
  esac
done
[[ -z "$FILE" ]] && { echo "Usage: $0 <file.cpp> [--depth N] [--root func]"; exit 1; }
[[ -f "$FILE" ]] || { echo "File not found: $FILE"; exit 1; }

# --- Build call map (perl) ---------------------------------------
# One line per function: "funcname callee1 callee2 ..."
CALL_MAP=$(perl - "$FILE" << 'PERL'
use strict; use warnings;
my $src = do { local $/; open my $f, $ARGV[0] or die $!; <$f> };

$src =~ s|//[^\n]*||g;
$src =~ s|/\*.*?\*/||gs;

my %kw = map { $_ => 1 } qw(if for while switch catch return new delete sizeof
                             alignof decltype static_assert namespace class
                             struct union enum template using typedef);

# Pass 1 — collect names of functions defined in this file
my %defined;
while ($src =~ /\b([A-Za-z_]\w*)\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/g) {
  my ($name, $pre) = ($1, substr($src, 0, $-[0]));
  next if $kw{$name} || $pre =~ /(?:->|\.)\s*$/;
  $defined{$name} = 1;
}

# extract_body: scan for the first non-call-site definition of $fn
# Returns the text from '{' to its matching '}' inclusive.
sub extract_body {
  my ($src, $fn) = @_;
  my $pat = qr/\b\Q$fn\E\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/;
  my $brace_start = undef;
  while ($src =~ /$pat/g) {
    my $pre = substr($src, 0, $-[0]);
    next if $pre =~ /(?:->|\.)\s*$/;
    $brace_start = $+[0] - 1;   # position of the '{' that ended the match
    last;
  }
  return "" unless defined $brace_start;
  my ($depth, $body) = (0, "");
  for my $i ($brace_start .. length($src) - 1) {
    my $c = substr($src, $i, 1);
    $depth++ if $c eq '{';
    $depth-- if $c eq '}';
    $body .= $c;
    last if $depth == 0;
  }
  return $body;
}

# Pass 2 — for each function find calls to other file-local functions
for my $fn (sort keys %defined) {
  my $body = extract_body($src, $fn);
  next unless $body;
  my %callees;
  for my $other (sort keys %defined) {
    next if $other eq $fn;
    $callees{$other} = 1 if $body =~ /(?<![>.])\b\Q$other\E\s*\(/;
  }
  print "$fn " . join(" ", sort keys %callees) . "\n";
}
PERL
)

[[ -z "$CALL_MAP" ]] && { echo "No functions found in $FILE"; exit 1; }

# ---- Load into bash -----------------------------------------------
declare -A CALLS
declare -a ALL_FUNCS
while IFS= read -r line; do
  FUNC="${line%% *}"
  REST="${line#* }"
  [[ "$REST" == "$FUNC" ]] && REST=""   # single token = no callees
  CALLS[$FUNC]="$REST"
  ALL_FUNCS+=("$FUNC")
done <<< "$CALL_MAP"

# -- Roots = functions not called in file--------------------------
declare -A IS_CALLEE
for FUNC in "${ALL_FUNCS[@]}"; do
  for CALLEE in ${CALLS[$FUNC]:-}; do IS_CALLEE[$CALLEE]=1; done
done

if [[ -n "$ROOT_FUNC" ]]; then
  ROOTS=("$ROOT_FUNC")
else
  ROOTS=()
  for FUNC in "${ALL_FUNCS[@]}"; do
    [[ -z "${IS_CALLEE[$FUNC]:-}" ]] && ROOTS+=("$FUNC")
  done
  [[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("${ALL_FUNCS[@]}")
fi

# -- Recursive ASCII tree -------------------------------
emit() {
  local NODE=$1 PREFIX=$2 CONT=$3 DEPTH=$4 VISITED=$5
  local MARKER=""
  [[ ":${VISITED}:" == *":${NODE}:"* ]] && MARKER="  ↩"
  echo "${PREFIX}${NODE}()${MARKER}"
  [[ -n "$MARKER" || "$DEPTH" -ge "$MAX_DEPTH" ]] && return
  local CHILDREN="${CALLS[$NODE]:-}"
  [[ -z "$CHILDREN" ]] && return
  local NEW_VIS="${VISITED}:${NODE}"
  local -a ARR; read -ra ARR <<< "$CHILDREN"
  local N=${#ARR[@]} i
  for (( i=0; i<N; i++ )); do
    if (( i == N-1 )); then
      emit "${ARR[$i]}" "${CONT}└── " "${CONT}    " $(( DEPTH+1 )) "$NEW_VIS"
    else
      emit "${ARR[$i]}" "${CONT}├── " "${CONT}│   " $(( DEPTH+1 )) "$NEW_VIS"
    fi
  done
}





# -- Print ------------------------------------
echo ""
echo "  $FILE  (depth=$MAX_DEPTH)"
echo ""
for ROOT in "${ROOTS[@]}"; do
  emit "$ROOT" "" "" 0 ""
  echo ""
done

printf "  %-26s  %s\n" "──────────────────────────" "────────────────────────────────"
printf "  %-26s  %s\n" "function" "calls"
printf "  %-26s  %s\n" "──────────────────────────" "────────────────────────────────"
for FUNC in $(printf '%s\n' "${ALL_FUNCS[@]}" | sort); do
  printf "  %-26s  %s\n" "$FUNC" "${CALLS[$FUNC]:----}"
done
echo ""
