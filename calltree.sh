#!/usr/bin/env bash
# calltree.sh | ASCII / Mermaid / DOT call graph for a single C++ file.
#
# Usage:
#   ./calltree.sh <file.cpp> [OPTIONS]
#
#   --depth N           max recursion depth in tree (default: 4)
#   --root  FUNC        start tree from FUNC, not auto-roots
#   --out-mermaid [F]   write Mermaid graph  (.mmd)  -- F optional, defaults to <file>.mmd
#   --out-dot     [F]   write Graphviz DOT   (.dot)  -- F optional, defaults to <file>.dot
#   --out-txt     [F]   write plain-text tree (.txt) -- F optional, defaults to <file>.txt
#   --color             colorize function names in terminal (256-color ANSI)
#                       usable range 40-210 avoids near-black and near-white tones
#                       index[i] = 40 + round(170 * i / (N-1))
#
# Deps: bash >= 4.0, perl (standard on Linux/macOS)
set -euo pipefail

# =============================================================================
# ARG PARSING
# =============================================================================

FILE="" MAX_DEPTH=4 ROOT_FUNC=""
OUT_MERMAID="" OUT_DOT="" OUT_TXT=""
USE_COLOR=0

_AUTO="__AUTO__"
_is_value() { [[ ${1+x} == x ]] && [[ -n "${1-}" ]] && [[ "${1-}" != --* ]]; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --depth)      MAX_DEPTH=$2;  shift 2 ;;
    --root)       ROOT_FUNC=$2;  shift 2 ;;
    --out-mermaid) shift; if _is_value "${1-}"; then OUT_MERMAID=$1; shift; else OUT_MERMAID=$_AUTO; fi ;;
    --out-dot)     shift; if _is_value "${1-}"; then OUT_DOT=$1;     shift; else OUT_DOT=$_AUTO;     fi ;;
    --out-txt)     shift; if _is_value "${1-}"; then OUT_TXT=$1;     shift; else OUT_TXT=$_AUTO;     fi ;;
    --color)      USE_COLOR=1;   shift   ;;
    *)            FILE=$1;       shift   ;;
  esac
done

[[ -z "$FILE" ]] && { echo "Usage: $0 <file.cpp> [--depth N] [--root FUNC] [--out-mermaid [F]] [--out-dot [F]] [--out-txt [F]] [--color]"; exit 1; }
[[ -f "$FILE" ]] || { echo "ERROR: file not found: $FILE"; exit 1; }

BASE="${FILE%.*}"
[[ "$OUT_MERMAID" == "$_AUTO" ]] && OUT_MERMAID="${BASE}.mmd"
[[ "$OUT_DOT"     == "$_AUTO" ]] && OUT_DOT="${BASE}.dot"
[[ "$OUT_TXT"     == "$_AUTO" ]] && OUT_TXT="${BASE}.txt"

# =============================================================================
# PERL ANALYSIS
#
# What counts as a function definition:
#   Any identifier followed by a parenthesised argument list and an opening
#   brace, i.e. the pattern:  name(...) [const|override|noexcept...] {
#   This catches free functions, methods and constructors but intentionally
#   skips control-flow keywords (if/for/while/...) which share that shape.
#   Member calls (obj.foo() / ptr->foo()) are excluded by rejecting identifiers
#   that are immediately preceded by '.' or '->'.
#
# Return type extraction:
#   For each matched definition the parser walks backward to the start of the
#   line, strips scope prefixes (Foo::) and storage-class keywords (static,
#   inline, constexpr, ...) and treats whatever remains as the return type.
#   Falls back to "void" when the prefix is empty or syntactic noise only.
#
# Call-edge detection:
#   For every function F, extract_body() locates the matching braced body by
#   counting brace depth from the opening '{'.  The body text is then scanned
#   for occurrences of every other known function name followed by '(' and
#   not preceded by '.' or '->'.  Each hit is counted; the total across all
#   callers becomes the frequency reported in the summary table.
#
# Output format (three sections separated by "---"):
#   CALLS  -- "<func> <callee1> <callee2> ..."  (space-separated)
#   TYPES  -- "<func>\t<return_type>"
#   FREQ   -- "<func>\t<total_call_count_across_all_callers>"
# =============================================================================

PERL_OUT=$(perl - "$FILE" << 'PERL'
use strict; use warnings;
my $src = do { local $/; open my $f, $ARGV[0] or die $!; <$f> };

$src =~ s|//[^\n]*||g;
$src =~ s|/\*.*?\*/||gs;

my %kw = map { $_ => 1 } qw(if for while switch catch return new delete sizeof
                            alignof decltype static_assert namespace class struct 
                            union enum template using typedef constexpr consteval constinit 
                            noexcept requires co_await co_return co_yield);

# ---- Pass 1: collect definitions and return types ---------------------------
my (%defined, %rtype);
while ($src =~ /\b([A-Za-z_]\w*)\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/g) {
  my ($name, $pos) = ($1, $-[0]);
  my $pre = substr($src, 0, $pos);
  next if $kw{$name} || $pre =~ /(?:->|\.)\s*$/;

  # Return type: text on the same line before the name,
  # after stripping scope qualifiers and storage-class keywords.
  my $bol = rindex($pre, "\n");
  $bol = $bol < 0 ? 0 : $bol + 1;
  my $prefix = substr($pre, $bol);
  $prefix =~ s/\b\w[\w:]*::\s*$//;
  $prefix =~ s/\b(?:static|inline|virtual|explicit|constexpr|consteval|constinit|extern|friend)\b\s*//gx;
  $prefix =~ s/^\s+|\s+$//g;
  $prefix =~ s/\s+/ /g;

  $rtype{$name}   //= ($prefix ne "" && $prefix !~ /^[:{;(]*$/) ? $prefix : "void";
  $defined{$name}   = 1;
}

# ---- extract_body: braced body of the first definition of $fn ---------------
sub extract_body {
  my ($src, $fn) = @_;
  my $pat = qr/\b\Q$fn\E\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/;
  my $brace_start;
  while ($src =~ /$pat/g) {
    next if substr($src, 0, $-[0]) =~ /(?:->|\.)\s*$/;
    $brace_start = $+[0] - 1;
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

# ---- Pass 2: callees and invocation counts ----------------------------------
my (%callees, %freq);
for my $fn (sort keys %defined) {
  my $body = extract_body($src, $fn);
  next unless $body;
  for my $other (sort keys %defined) {
    next if $other eq $fn;
    my @hits = ($body =~ /(?<![>.])\b\Q$other\E\s*\(/g);
    if (@hits) {
      $callees{$fn}{$other} = 1;
      $freq{$other} = ($freq{$other} // 0) + scalar @hits;
    }
  }
}

# ---- Emit three sections ----------------------------------------------------
print "CALLS\n";
for my $fn (sort keys %defined) {
  print "$fn " . join(" ", sort keys %{ $callees{$fn} // {} }) . "\n";
}
print "---\n";
print "TYPES\n";
print "$_\t$rtype{$_}\n" for sort keys %defined;
print "---\n";
print "FREQ\n";
print "$_\t" . ($freq{$_} // 0) . "\n" for sort keys %defined;
print "---\n";
PERL
)

[[ -z "$PERL_OUT" ]] && { echo "No functions found in $FILE"; exit 1; }

# =============================================================================
# LOAD PERL OUTPUT INTO BASH ASSOCIATIVE ARRAYS
# =============================================================================

declare -A CALLS RTYPE FREQ
declare -a ALL_FUNCS
SEC=""
while IFS= read -r line; do
  case "$line" in
    CALLS|TYPES|FREQ) SEC="$line"; continue ;;
    ---) SEC=""; continue ;;
    "") continue ;;
  esac
  case "$SEC" in
    CALLS)
      FUNC="${line%% *}"; REST="${line#* }"
      [[ "$REST" == "$FUNC" ]] && REST=""
      CALLS[$FUNC]="$REST"; ALL_FUNCS+=("$FUNC")
      ;;
    TYPES) IFS=$'\t' read -r F V <<< "$line"; RTYPE[$F]="${V:-void}" ;;
    FREQ)  IFS=$'\t' read -r F V <<< "$line"; FREQ[$F]="${V:-0}"     ;;
  esac
done <<< "$PERL_OUT"

[[ ${#ALL_FUNCS[@]} -eq 0 ]] && { echo "No functions found in $FILE"; exit 1; }
# =============================================================================
# REACHABLE SET
#
# When --root is given, compute the full set of functions reachable from that
# root via BFS.  This set drives both the color map and the summary table so
# that both only show functions that are actually part of the rooted subtree.
# When no --root is given, the reachable set is the full function list.
# =============================================================================

declare -a VISIBLE_FUNCS
if [[ -n "$ROOT_FUNC" ]]; then
  declare -A _REACHED
  declare -a _QUEUE=("$ROOT_FUNC")
  _REACHED[$ROOT_FUNC]=1
  while [[ ${#_QUEUE[@]} -gt 0 ]]; do
    _HEAD="${_QUEUE[0]}"; _QUEUE=("${_QUEUE[@]:1}")
    for _C in ${CALLS[$_HEAD]:-}; do
      if [[ -z "${_REACHED[$_C]:-}" ]]; then
        _REACHED[$_C]=1
        _QUEUE+=("$_C")
      fi
    done
  done
  for F in "${ALL_FUNCS[@]}"; do
    [[ -n "${_REACHED[$F]:-}" ]] && VISIBLE_FUNCS+=("$F")
  done
else
  VISIBLE_FUNCS=("${ALL_FUNCS[@]}")
fi



# =============================================================================
# 256-COLOR MAP
#
# The full 0-255 palette includes near-black (0-39) and near-white (211-255)
# tones that are unreadable on dark and light terminals respectively.
# The usable window is clamped to indices 40-210 (171 values).
#
#   index[i] = 40 + round(170 * i / (N-1))
#
# Functions are sorted alphabetically so colors stay stable across runs
# regardless of the order they appear in the source file.
#
# Colors are only asigned to "Visible functions" (if using '--root' only map root and upper lvls)
# =============================================================================

declare -A FUNC_COLOR
if [[ $USE_COLOR -eq 1 ]]; then
  mapfile -t _SORTED < <(printf '%s\n' "${VISIBLE_FUNCS[@]}" | sort)
  NF=${#_SORTED[@]}
  for (( ci=0; ci<NF; ci++ )); do
    (( NF == 1 )) && C=125 || C=$(( 40 + 170 * ci / (NF - 1) ))
    FUNC_COLOR["${_SORTED[$ci]}"]=$C
  done
fi

colorize() {
  local NAME=$1 COL=${2:-0}
  if [[ $COL -eq 1 && -n "${FUNC_COLOR[$NAME]:-}" ]]; then
    printf '\033[38;5;%dm%s\033[0m' "${FUNC_COLOR[$NAME]}" "$NAME"
  else
    printf '%s' "$NAME"
  fi
}

# =============================================================================
# ROOT DETECTION
# Roots are functions that no other function in this file calls.
# =============================================================================

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

# =============================================================================
# ASCII TREE EMITTER
#
# Taken verbatim from the original working version; N and i are declared
# together on one line so both are unambiguously local to each invocation.
# Cycle detection uses VISITED, a colon-delimited ancestor-path string.
# =============================================================================

emit() {
  local NODE=$1 PREFIX=$2 CONT=$3 DEPTH=$4 VISITED=$5 COL=${6:-0}
  local MARKER=""
  [[ ":${VISITED}:" == *":${NODE}:"* ]] && MARKER="  [cycle]"
  echo "${PREFIX}$(colorize "$NODE" "$COL")()  -> ${RTYPE[$NODE]:-?}${MARKER}"
  [[ -n "$MARKER" || "$DEPTH" -ge "$MAX_DEPTH" ]] && return
  local CHILDREN="${CALLS[$NODE]:-}"
  [[ -z "$CHILDREN" ]] && return
  local NEW_VIS="${VISITED}:${NODE}"
  local -a ARR; read -ra ARR <<< "$CHILDREN"
  local N=${#ARR[@]} i
  for (( i=0; i<N; i++ )); do
    if (( i == N-1 )); then
      emit "${ARR[$i]}" "${CONT}└── " "${CONT}    " $(( DEPTH+1 )) "$NEW_VIS" "$COL"
    else
      emit "${ARR[$i]}" "${CONT}├── " "${CONT}│   " $(( DEPTH+1 )) "$NEW_VIS" "$COL"
    fi
  done
}

# =============================================================================
# SUMMARY TABLE
# Columns: function | called (frequency) | calls | return type
# The "calls" list is colorized when --color is active.
# printf %-Ns counts ANSI bytes as visible characters and misaligns columns,
# so both the function-name and calls fields are padded manually.
# =============================================================================

print_table() {
  local COL=${1:-0}

  calls_field() {
    local RAW="${CALLS[$1]:----}"
    if [[ $COL -eq 0 || "$RAW" == "----" ]]; then printf '%s' "$RAW"; return; fi
    local OUT="" WORD
    for WORD in $RAW; do
      [[ -n "$OUT" ]] && OUT+=" "
      OUT+="$(colorize "$WORD" "$COL")"
    done
    printf '%s' "$OUT"
  }

  printf '\n'
  printf '  %-28s  %6s  %-40s  %s\n' "function" "called" "calls" "return type"
  printf '  %-28s  %6s  %-40s  %s\n' \
    "────────────────────────────" "──────" \
    "────────────────────────────────────────" "──────────────────────"

  local F RAW_F RAW_C COLOR_F COLOR_C PAD_F PAD_C
  for F in $(printf '%s\n' "${VISIBLE_FUNCS[@]}" | sort); do
    RAW_C="${CALLS[$F]:----}"
    COLOR_F="$(colorize "$F" "$COL")"
    COLOR_C="$(calls_field "$F")"
    PAD_F=$(( 28 - ${#F}    )); (( PAD_F < 0 )) && PAD_F=0
    PAD_C=$(( 40 - ${#RAW_C} )); (( PAD_C < 0 )) && PAD_C=0
    printf '  %s%*s  %6s  %s%*s  %s\n' \
      "$COLOR_F" "$PAD_F" "" \
      "${FREQ[$F]:-0}" \
      "$COLOR_C" "$PAD_C" "" \
      "${RTYPE[$F]:-?}"
  done
  printf '\n'
}

# =============================================================================
# ASCII OUTPUT (tree + table)
# COL=1 enables ANSI colors; COL=0 produces clean plain text safe for files.
# =============================================================================

print_ascii() {
  local COL=${1:-0}
  echo ""
  echo "  $FILE  (depth=$MAX_DEPTH)"
  echo ""
  for ROOT in "${ROOTS[@]}"; do
    emit "$ROOT" "" "" 0 "" "$COL"
    echo ""
  done
  print_table "$COL"
}

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================

print_ascii "$USE_COLOR"

# =============================================================================
# OPTIONAL FILE OUTPUTS
# =============================================================================

# ---- Plain text (no ANSI codes) ----------------------------------------
if [[ -n "$OUT_TXT" ]]; then
  print_ascii 0 > "$OUT_TXT"
  printf '  -> plain text  : %s\n' "$OUT_TXT"
fi

# ---- Mermaid --------------------------------------------------------------
# Node labels carry return type; isolated leaves appear via explicit node defs.
# Wrapped in fenced code block so it renders in GitHub / GitLab / Notion.
if [[ -n "$OUT_MERMAID" ]]; then
  {
    printf '```mermaid\ngraph TD\n'
    for F in "${ALL_FUNCS[@]}"; do
      printf '    %s["%s %s()"]\n' "$F" "${RTYPE[$F]:-void}" "$F"
    done
    printf '\n'
    for F in "${ALL_FUNCS[@]}"; do
      for C in ${CALLS[$F]:-}; do printf '    %s --> %s\n' "$F" "$C"; done
    done
    printf '```\n'
  } > "$OUT_MERMAID"
  printf '  -> Mermaid     : %s\n' "$OUT_MERMAID"
fi

# --- DOT (Graphviz) -----------------------------------------------------
# Render with: dot -Tsvg -o graph.svg <file>.dot
# Node labels: return_type / func() / called N
if [[ -n "$OUT_DOT" ]]; then
  {
    printf 'digraph callgraph {\n'
    printf '    graph [label="%s" labelloc=t fontname="Courier" fontsize=14];\n' "$FILE"
    printf '    node  [shape=box fontname="Courier" style=filled fillcolor="#f5f5f5"];\n'
    printf '    edge  [fontname="Courier" fontsize=10];\n'
    printf '    rankdir=LR;\n\n'
    for F in "${ALL_FUNCS[@]}"; do
      printf '    "%s" [label="%s\\n%s()\\ncalled: %s"];\n' \
        "$F" "${RTYPE[$F]:-void}" "$F" "${FREQ[$F]:-0}"
    done
    printf '\n'
    for F in "${ALL_FUNCS[@]}"; do
      for C in ${CALLS[$F]:-}; do printf '    "%s" -> "%s";\n' "$F" "$C"; done
    done
    printf '}\n'
  } > "$OUT_DOT"
  printf '  -> DOT    : %s  (render: dot -Tsvg -o graph.svg %s)\n' "$OUT_DOT" "$OUT_DOT"
fi

