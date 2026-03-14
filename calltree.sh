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
#   --see               disable [seen] compression and always expand repeated subtrees
#
# Deps: bash >= 4.0, perl (standard on Linux/macOS)
set -euo pipefail

# =============================================================================
# ARG PARSING
# =============================================================================

FILE="" MAX_DEPTH=4 ROOT_FUNC=""
OUT_MERMAID="" OUT_DOT="" OUT_TXT=""
USE_COLOR=0
SEE_ALL=0

_AUTO="__AUTO__"
_is_value() { [[ ${1+x} == x ]] && [[ -n "${1-}" ]] && [[ "${1-}" != --* ]]; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --depth)       MAX_DEPTH=$2; shift 2 ;;
    --root)        ROOT_FUNC=$2; shift 2 ;;
    --out-mermaid) shift; if _is_value "${1-}"; then OUT_MERMAID=$1; shift; else OUT_MERMAID=$_AUTO; fi ;;
    --out-dot)     shift; if _is_value "${1-}"; then OUT_DOT=$1;     shift; else OUT_DOT=$_AUTO;     fi ;;
    --out-txt)     shift; if _is_value "${1-}"; then OUT_TXT=$1;     shift; else OUT_TXT=$_AUTO;     fi ;;
    --color)       USE_COLOR=1; shift ;;
    --see)         SEE_ALL=1; shift ;;
    *)             FILE=$1; shift ;;
  esac
done

[[ -z "$FILE" ]] && {
  echo "Usage: $0 <file.cpp> [--depth N] [--root FUNC] [--out-mermaid [F]] [--out-dot [F]] [--out-txt [F]] [--color] [--see]"
  exit 1
}
[[ -f "$FILE" ]] || { echo "ERROR: file not found: $FILE"; exit 1; }

BASE="${FILE%.*}"
[[ "$OUT_MERMAID" == "$_AUTO" ]] && OUT_MERMAID="${BASE}.mmd"
[[ "$OUT_DOT"     == "$_AUTO" ]] && OUT_DOT="${BASE}.dot"
[[ "$OUT_TXT"     == "$_AUTO" ]] && OUT_TXT="${BASE}.txt"

# =============================================================================
# PERL ANALYSIS
# =============================================================================

PERL_OUT=$(perl - "$FILE" <<'PERL'
use strict;
use warnings;

my $src = do { local $/; open my $f, $ARGV[0] or die $!; <$f> };

$src =~ s|//[^\n]*||g;
$src =~ s|/\*.*?\*/||gs;

my %kw = map { $_ => 1 } qw(
  if for while switch catch return new delete sizeof
  alignof decltype static_assert namespace class struct
  union enum template using typedef constexpr consteval constinit
  noexcept requires co_await co_return co_yield
);

# ---- Pass 1: collect definitions, return types and definition order ---------
my (%defined, %rtype, %seen_def);
my @defs_order;

while ($src =~ /\b([A-Za-z_]\w*)\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/g) {
  my ($name, $pos) = ($1, $-[0]);
  my $pre = substr($src, 0, $pos);
  next if $kw{$name} || $pre =~ /(?:->|\.)\s*$/;

  my $bol = rindex($pre, "\n");
  $bol = $bol < 0 ? 0 : $bol + 1;
  my $prefix = substr($pre, $bol);
  $prefix =~ s/\b\w[\w:]*::\s*$//;
  $prefix =~ s/\b(?:static|inline|virtual|explicit|constexpr|consteval|constinit|extern|friend)\b\s*//gx;
  $prefix =~ s/^\s+|\s+$//g;
  $prefix =~ s/\s+/ /g;

  if (!exists $rtype{$name}) {
    $rtype{$name} = (($prefix ne '') && ($prefix !~ /^[\:{;\(]*$/)) ? $prefix : 'void';
  }
  $defined{$name} = 1;
  push @defs_order, $name unless $seen_def{$name}++;
}

sub extract_body {
  my ($src, $fn) = @_;
  my $pat = qr/\b\Q$fn\E\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*\{/;
  my $brace_start;
  while ($src =~ /$pat/g) {
    next if substr($src, 0, $-[0]) =~ /(?:->|\.)\s*$/;
    $brace_start = $+[0] - 1;
    last;
  }
  return '' unless defined $brace_start;

  my ($depth, $body) = (0, '');
  for my $i ($brace_start .. length($src) - 1) {
    my $c = substr($src, $i, 1);
    $depth++ if $c eq '{';
    $depth-- if $c eq '}';
    $body .= $c;
    last if $depth == 0;
  }
  return $body;
}

# ---- Pass 2: ordered callees with duplicates preserved ----------------------
my (%ordered_calls, %freq);
for my $fn (@defs_order) {
  my $body = extract_body($src, $fn);
  next unless $body;

  while ($body =~ /(?<![>.])\b([A-Za-z_]\w*)\s*\(/g) {
    my $callee = $1;
    next unless $defined{$callee};
    next if $callee eq $fn;
    push @{ $ordered_calls{$fn} }, $callee;
    $freq{$callee} = ($freq{$callee} // 0) + 1;
  }
}

print "CALLS\n";
for my $fn (@defs_order) {
  my $calls = join(' ', @{ $ordered_calls{$fn} // [] });
  print "$fn\t$calls\n";
}
print "---\n";

print "TYPES\n";
print "$_\t$rtype{$_}\n" for @defs_order;
print "---\n";

print "FREQ\n";
print "$_\t" . ($freq{$_} // 0) . "\n" for @defs_order;
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
      IFS=$'\t' read -r FUNC REST <<< "$line"
      CALLS[$FUNC]="${REST:-}"
      ALL_FUNCS+=("$FUNC")
      ;;
    TYPES)
      IFS=$'\t' read -r F V <<< "$line"
      RTYPE[$F]="${V:-void}"
      ;;
    FREQ)
      IFS=$'\t' read -r F V <<< "$line"
      FREQ[$F]="${V:-0}"
      ;;
  esac
done <<< "$PERL_OUT"

[[ ${#ALL_FUNCS[@]} -eq 0 ]] && { echo "No functions found in $FILE"; exit 1; }

# =============================================================================
# REACHABLE SET
# =============================================================================

declare -a VISIBLE_FUNCS
if [[ -n "$ROOT_FUNC" ]]; then
  declare -A _REACHED
  declare -a _QUEUE=("$ROOT_FUNC")
  _REACHED[$ROOT_FUNC]=1

  while [[ ${#_QUEUE[@]} -gt 0 ]]; do
    _HEAD="${_QUEUE[0]}"
    _QUEUE=("${_QUEUE[@]:1}")
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

GREY_ANSI=244

colorize() {
  local NAME=$1 COL=${2:-0}
  if [[ $COL -eq 1 && -n "${FUNC_COLOR[$NAME]:-}" ]]; then
    printf '\033[38;5;%dm%s\033[0m' "${FUNC_COLOR[$NAME]}" "$NAME"
  else
    printf '%s' "$NAME"
  fi
}

greyize() {
  local TEXT=$1 COL=${2:-0}
  if [[ $COL -eq 1 ]]; then
    printf '\033[38;5;%dm%s\033[0m' "$GREY_ANSI" "$TEXT"
  else
    printf '%s' "$TEXT"
  fi
}

seen_marker() {
  local NAME=$1 COL=${2:-0}
  if [[ $COL -eq 1 && -n "${FUNC_COLOR[$NAME]:-}" ]]; then
    printf '  [\033[38;5;%dmseen\033[0m]' "${FUNC_COLOR[$NAME]}"
  else
    printf '  [seen]'
  fi
}

unique_calls_raw() {
  local RAW="${CALLS[$1]:-}"
  [[ -z "$RAW" ]] && return

  local -A SEEN_WORD=()
  local OUT="" WORD
  for WORD in $RAW; do
    [[ -n "${SEEN_WORD[$WORD]:-}" ]] && continue
    SEEN_WORD[$WORD]=1
    [[ -n "$OUT" ]] && OUT+=" "
    OUT+="$WORD"
  done
  printf '%s' "$OUT"
}

# =============================================================================
# ROOT DETECTION
# =============================================================================

declare -A IS_CALLEE
for FUNC in "${ALL_FUNCS[@]}"; do
  for CALLEE in ${CALLS[$FUNC]:-}; do
    IS_CALLEE[$CALLEE]=1
  done
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
# =============================================================================

declare -A SEEN_SUBTREE

emit() {
  local NODE=$1 PREFIX=$2 CONT=$3 DEPTH=$4 VISITED=$5 COL=${6:-0}
  local MARKER=""
  local CHILDREN="${CALLS[$NODE]:-}"

  if [[ ":${VISITED}:" == *":${NODE}:"* ]]; then
    MARKER="  [cycle]"
  elif [[ $SEE_ALL -eq 0 && -n "$CHILDREN" && -n "${SEEN_SUBTREE[$NODE]:-}" ]]; then
    MARKER="$(seen_marker "$NODE" "$COL")"
  fi

  echo "${PREFIX}$(colorize "$NODE" "$COL")()  $(greyize "-> ${RTYPE[$NODE]:-?}" "$COL")${MARKER}"
  [[ -n "$MARKER" || "$DEPTH" -ge "$MAX_DEPTH" ]] && return
  [[ -z "$CHILDREN" ]] && return

  SEEN_SUBTREE[$NODE]=1

  local NEW_VIS="${VISITED}:${NODE}"
  local -a ARR
  read -ra ARR <<< "$CHILDREN"
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
# =============================================================================

print_table() {
  local COL=${1:-0}

  calls_field() {
    local RAW="$(unique_calls_raw "$1")"
    [[ -z "$RAW" ]] && RAW="----"
    if [[ $COL -eq 0 ]]; then
      printf '%s' "$RAW"
      return
    fi
    if [[ "$RAW" == "----" ]]; then
      greyize "$RAW" "$COL"
      return
    fi
    local OUT="" WORD
    for WORD in $RAW; do
      [[ -n "$OUT" ]] && OUT+=" "
      OUT+="$(colorize "$WORD" "$COL")"
    done
    printf '%s' "$OUT"
  }

  printf '\n'
  printf '  %s  %6s  %s  %s\n' \
    "function                    " \
    "called" \
    "calls                                   " \
    "return type"
  printf '  %s  %s  %s  %s\n' \
    "────────────────────────────" \
    "──────" \
    "────────────────────────────────────────" \
    "──────────────────────"

  local F RAW_C COLOR_F COLOR_C PAD_F PAD_C
  for F in "${VISIBLE_FUNCS[@]}"; do
    RAW_C="$(unique_calls_raw "$F")"
    [[ -z "$RAW_C" ]] && RAW_C="----"
    COLOR_F="$(colorize "$F" "$COL")"
    COLOR_C="$(calls_field "$F")"
    PAD_F=$(( 28 - ${#F} ));    (( PAD_F < 0 )) && PAD_F=0
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
# =============================================================================

print_ascii() {
  local COL=${1:-0}
  SEEN_SUBTREE=()
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

if [[ -n "$OUT_TXT" ]]; then
  print_ascii 0 > "$OUT_TXT"
  printf '  -> plain text  : %s\n' "$OUT_TXT"
fi

if [[ -n "$OUT_MERMAID" ]]; then
  {
    printf '```mermaid\ngraph TD\n'
    for F in "${ALL_FUNCS[@]}"; do
      printf '    %s["%s %s()"]\n' "$F" "${RTYPE[$F]:-void}" "$F"
    done
    printf '\n'
    for F in "${ALL_FUNCS[@]}"; do
      declare -A EDGE_SEEN=()
      for C in ${CALLS[$F]:-}; do
        if [[ -z "${EDGE_SEEN[$C]:-}" ]]; then
          printf '    %s --> %s\n' "$F" "$C"
          EDGE_SEEN[$C]=1
        fi
      done
      unset EDGE_SEEN
    done
    printf '```\n'
  } > "$OUT_MERMAID"
  printf '  -> Mermaid     : %s\n' "$OUT_MERMAID"
fi

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
      declare -A EDGE_SEEN=()
      for C in ${CALLS[$F]:-}; do
        if [[ -z "${EDGE_SEEN[$C]:-}" ]]; then
          printf '    "%s" -> "%s";\n' "$F" "$C"
          EDGE_SEEN[$C]=1
        fi
      done
      unset EDGE_SEEN
    done
    printf '}\n'
  } > "$OUT_DOT"
  printf '  -> DOT    : %s  (render: dot -Tsvg -o graph.svg %s)\n' "$OUT_DOT" "$OUT_DOT"
fi
