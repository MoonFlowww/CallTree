#!/usr/bin/env bash
# calltree.sh | ASCII / Mermaid / DOT call graph — single or multi-file C++ analysis.
#
# Single-file usage (fully backward-compatible):
#   ./calltree.sh <file.cpp> [OPTIONS]
#
# Multi-file / project-wide usage:
#   ./calltree.sh file1.cpp file2.cpp [OPTIONS]
#   ./calltree.sh --dir src/ [OPTIONS]
#   ./calltree.sh --dir src/ --include "*.cpp" --exclude "test_*" [OPTIONS]
#
# Options (all original flags preserved):
#   --depth N           max recursion depth (default: 4)
#   --root FUNC         start tree from FUNC; for multi-file use FUNC (auto-pick)
#                       or the full key form FILE::::FUNC to pin a specific file
#   --dir DIR           recursively scan DIR for C++ files (repeatable)
#                       default extensions: .cpp .hpp .cc .cxx .h .hxx
#   --include PATTERN   keep only files whose basename matches glob (repeatable)
#   --exclude PATTERN   drop files whose basename matches glob  (repeatable)
#   --color             colorize function names in terminal (256-color ANSI)
#   --see               always expand repeated subtrees (disable [seen] compression)
#   --out-mermaid [F]   write Mermaid graph (.mmd) — multi-file uses subgraphs
#   --out-dot [F]       write Graphviz DOT (.dot)  — multi-file uses clusters
#   --out-txt [F]       write plain-text tree (.txt)
#
# Multi-file behaviour:
#   - Each function's internal key is  filepath::::funcname
#   - Cross-file calls are resolved: same-file definition is preferred; otherwise
#     the first file that defines the callee is used
#   - The ASCII tree annotates each node with [basename.ext]
#   - The summary table gains a "file" column
#   - Mermaid output wraps each file's functions in a subgraph
#   - DOT output wraps each file's functions in a cluster
#
# Limitations:
#   - File paths containing spaces or the literal string "::::" are not supported
#   - Single-file only per-function: cross-file template specialisations map to
#     whichever file the matching definition was first encountered in
#
# Deps: bash >= 4.0, perl (standard on Linux/macOS), graphviz (optional, for .dot)
set -euo pipefail

# =============================================================================
# INTERNAL KEY FORMAT:  filepath::::funcname
# ::::" cannot appear in C++ identifiers; avoid spaces in paths.
# =============================================================================
readonly _SEP="::::"
_kfile() { printf '%s' "${1%%${_SEP}*}";  }
_kfunc() { printf '%s' "${1##*${_SEP}}";  }
_kbase() { local _f; _f=$(_kfile "$1"); printf '%s' "${_f##*/}"; }

# =============================================================================
# TIMING  (perl Time::HiRes — works on Linux and macOS without extra modules)
# =============================================================================
_ts_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# =============================================================================
# ARG PARSING
# =============================================================================
_MAX_DEPTH=4; _ROOT_FUNC=""; _USE_COLOR=0; _SEE_ALL=0
_OUT_MMD=""; _OUT_DOT=""; _OUT_TXT=""
declare -a _INPUT_FILES=() _SCAN_DIRS=() _INC_PATS=() _EXC_PATS=()
readonly _AUTO="__AUTO__"

_is_val() { [[ ${1+x} == x ]] && [[ -n "${1-}" ]] && [[ "${1-}" != --* ]]; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --depth)   _MAX_DEPTH=$2;      shift 2 ;;
    --root)    _ROOT_FUNC=$2;      shift 2 ;;
    --dir)     _SCAN_DIRS+=("$2"); shift 2 ;;
    --include) _INC_PATS+=("$2");  shift 2 ;;
    --exclude) _EXC_PATS+=("$2");  shift 2 ;;
    --color)   _USE_COLOR=1;       shift   ;;
    --see)     _SEE_ALL=1;         shift   ;;
    --out-mermaid) shift; if _is_val "${1-}"; then _OUT_MMD=$1; shift; else _OUT_MMD=$_AUTO; fi ;;
    --out-dot)     shift; if _is_val "${1-}"; then _OUT_DOT=$1; shift; else _OUT_DOT=$_AUTO; fi ;;
    --out-txt)     shift; if _is_val "${1-}"; then _OUT_TXT=$1; shift; else _OUT_TXT=$_AUTO; fi ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)   _INPUT_FILES+=("$1"); shift ;;
  esac
done

# -- Collect files from --dir -------------------------------------------------
for _DIR in "${_SCAN_DIRS[@]+"${_SCAN_DIRS[@]}"}"; do
  [[ -d "$_DIR" ]] || { printf 'ERROR: not a directory: %s\n' "$_DIR" >&2; exit 1; }
  while IFS= read -r -d '' _F; do
    _BN="${_F##*/}"; _OK=1
    if [[ ${#_INC_PATS[@]} -gt 0 ]]; then
      _OK=0
      for _P in "${_INC_PATS[@]}"; do
        # shellcheck disable=SC2254
        case "$_BN" in $_P) _OK=1; break ;; esac
      done
    fi
    [[ $_OK -eq 0 ]] && continue
    for _P in "${_EXC_PATS[@]+"${_EXC_PATS[@]}"}"; do
      case "$_BN" in $_P) _OK=0; break ;; esac
    done
    [[ $_OK -eq 0 ]] && continue
    _INPUT_FILES+=("$_F")
  done < <(find "$_DIR" -type f \( \
      -name "*.cpp" -o -name "*.hpp" -o -name "*.cc" \
      -o -name "*.cxx" -o -name "*.h"   -o -name "*.hxx" \
    \) -print0 | sort -z)
done

if [[ ${#_INPUT_FILES[@]} -eq 0 ]]; then
  printf 'Usage: %s <file.cpp> [--depth N] [--root FUNC]\n' "$0"
  printf '       [--dir DIR] [--include PAT] [--exclude PAT]\n'
  printf '       [--out-mermaid [F]] [--out-dot [F]] [--out-txt [F]]\n'
  printf '       [--color] [--see]\n'
  exit 1
fi
for _F in "${_INPUT_FILES[@]}"; do
  [[ -f "$_F" ]] || { printf 'ERROR: file not found: %s\n' "$_F" >&2; exit 1; }
done

# -- Mode, title, default output base -----------------------------------------
if [[ ${#_INPUT_FILES[@]} -eq 1 ]]; then
  _MULTI=0
  _TITLE="${_INPUT_FILES[0]}"
  _BASE="${_INPUT_FILES[0]%.*}"
else
  _MULTI=1
  if [[ ${#_SCAN_DIRS[@]} -gt 0 ]]; then
    _TITLE="${_SCAN_DIRS[0]}  (${#_INPUT_FILES[@]} files)"
    _BASE="${_SCAN_DIRS[0]%/}/calltree"
  else
    _TITLE="${#_INPUT_FILES[@]} files"
    _BASE="calltree"
  fi
fi
[[ "$_OUT_MMD" == "$_AUTO" ]] && _OUT_MMD="${_BASE}.mmd"
[[ "$_OUT_DOT" == "$_AUTO" ]] && _OUT_DOT="${_BASE}.dot"
[[ "$_OUT_TXT" == "$_AUTO" ]] && _OUT_TXT="${_BASE}.txt"

# =============================================================================
# PERL: multi-file static analysis
# Keys in output use "::::" as filepath/funcname separator.
# =============================================================================
_T_START=$(_ts_ms)
_PERL_OUT=$(perl - "${_INPUT_FILES[@]}" <<'PERL'
use strict;
use warnings;

my $SEP   = "::::";
my @files = @ARGV;

my %kw = map { $_ => 1 } qw(
  if for while switch catch return new delete sizeof
  alignof decltype static_assert namespace class struct
  union enum template using typedef constexpr consteval constinit
  noexcept requires co_await co_return co_yield
);

# ---- Pass 1: collect definitions & return types ----------------------------
my (%src, %file_defs, %func_to_files, %rtype, %seen_def);

for my $file (@files) {
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    $text =~ s|//[^\n]*||g;
    $text =~ s|/\*.*?\*/||gs;
    $src{$file} = $text;

  while ($text =~ /\b([A-Za-z_]\w*)\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*(?:\s*:[^{]*)?\{/g) {
        my ($name, $pos) = ($1, $-[0]);
        my $pre = substr($text, 0, $pos);
        next if $kw{$name} || $pre =~ /(?:->|\.)\s*$/;

        my $bol = rindex($pre, "\n");
        $bol = $bol < 0 ? 0 : $bol + 1;
        my $prefix = substr($pre, $bol);
        $prefix =~ s/\b\w[\w:]*::\s*$//;
        $prefix =~ s/\b(?:static|inline|virtual|explicit|constexpr|consteval|constinit|extern|friend)\b\s*//gx;
        $prefix =~ s/^\s+|\s+$//g;
        $prefix =~ s/\s+/ /g;

        my $key = "${file}${SEP}${name}";
        $rtype{$key} //= (($prefix ne '') && ($prefix !~ /^[\:{;\(]*$/)) ? $prefix : 'void';

        unless ($seen_def{"${file}\0${name}"}++) {
            push @{$file_defs{$file}}, $name;
        }
        unless (grep { $_ eq $file } @{$func_to_files{$name} // []}) {
            push @{$func_to_files{$name}}, $file;
        }
    }
}

my %all_known = map { $_ => 1 } keys %func_to_files;

# ---- extract_body -----------------------------------------------------------
sub extract_body {
    my ($text, $fn) = @_;
    my $pat = qr/\b\Q$fn\E\s*\([^()]*\)\s*(?:const\s*|override\s*|noexcept\s*)*(?:\s*:[^{]*)?\{/;
    my $brace_start;
    while ($text =~ /$pat/g) {
        next if substr($text, 0, $-[0]) =~ /(?:->|\.)\s*$/;
        $brace_start = $+[0] - 1;
        last;
    }
    return '' unless defined $brace_start;
    my ($depth, $body) = (0, '');
    for my $i ($brace_start .. length($text) - 1) {
        my $c = substr($text, $i, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        $body .= $c;
        last if $depth == 0;
    }
    return $body;
}

# ---- Pass 2: call edges -----------------------------------------------------
my (%calls, %freq);

for my $file (@files) {
    for my $fn (@{$file_defs{$file} // []}) {
        my $caller_key = "${file}${SEP}${fn}";
        my $body = extract_body($src{$file}, $fn);
        next unless $body;

        while ($body =~ /(?<![>.])\b([A-Za-z_]\w*)\s*\(/g) {
            my $callee = $1;
            next unless $all_known{$callee};
            next if $callee eq $fn;

            # prefer same-file definition; else first file that defines it
            my $callee_files_ref = $func_to_files{$callee} // [];
            my $callee_file =
                (grep { $_ eq $file } @$callee_files_ref)
                    ? $file
                    : $callee_files_ref->[0];
            next unless defined $callee_file;

            my $callee_key = "${callee_file}${SEP}${callee}";
            push @{$calls{$caller_key}}, $callee_key;
            $freq{$callee_key} = ($freq{$callee_key} // 0) + 1;
        }
    }
}

# ---- Output -----------------------------------------------------------------
print "CALLS\n";
for my $file (@files) {
    for my $fn (@{$file_defs{$file} // []}) {
        my $key = "${file}${SEP}${fn}";
        printf "%s\t%s\n", $key, join(' ', @{$calls{$key} // []});
    }
}
print "---\n";

print "TYPES\n";
for my $file (@files) {
    for my $fn (@{$file_defs{$file} // []}) {
        my $key = "${file}${SEP}${fn}";
        printf "%s\t%s\n", $key, $rtype{$key} // 'void';
    }
}
print "---\n";

print "FREQ\n";
for my $file (@files) {
    for my $fn (@{$file_defs{$file} // []}) {
        my $key = "${file}${SEP}${fn}";
        printf "%s\t%d\n", $key, $freq{$key} // 0;
    }
}
print "---\n";

print "LINESREAD\n";
my $total_lines = 0;
for my $file (@files) {
    # Count raw newlines in the original source (before comment stripping).
    open my $fh, '<', $file or next;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $nl = ($raw =~ tr/\n//);
    # If the last line has no trailing newline it still counts as a line.
    $nl++ if length($raw) && substr($raw, -1) ne "\n";
    $total_lines += $nl;
}
print "$total_lines\n";
print "---\n";
PERL
)

[[ -z "$_PERL_OUT" ]] && { printf 'No functions found in specified files.\n' >&2; exit 1; }

# =============================================================================
# LOAD PERL OUTPUT INTO BASH ASSOCIATIVE ARRAYS
# =============================================================================
declare -A CALLS=() RTYPE=() FREQ=()
declare -a ALL_FUNCS=()
_SEC=""
_LINES_READ=0

while IFS= read -r _line; do
  case "$_line" in
    CALLS|TYPES|FREQ|LINESREAD) _SEC="$_line"; continue ;;
    ---) _SEC=""; continue ;;
    "") continue ;;
  esac
  case "$_SEC" in
    CALLS)
      IFS=$'\t' read -r _KEY _REST <<< "$_line"
      CALLS[$_KEY]="${_REST:-}"
      ALL_FUNCS+=("$_KEY")
      ;;
    TYPES)
      IFS=$'\t' read -r _KEY _V <<< "$_line"
      RTYPE[$_KEY]="${_V:-void}"
      ;;
    FREQ)
      IFS=$'\t' read -r _KEY _V <<< "$_line"
      FREQ[$_KEY]="${_V:-0}"
      ;;
    LINESREAD)
      _LINES_READ="$_line"
      ;;
  esac
done <<< "$_PERL_OUT"

[[ ${#ALL_FUNCS[@]} -eq 0 ]] && { printf 'No functions found.\n' >&2; exit 1; }
_T_BACKEND_END=$(_ts_ms)

# =============================================================================
# REACHABLE SET  (when --root is given)
# =============================================================================
declare -a VISIBLE_FUNCS=()
_ROOT_KEY=""

if [[ -n "$_ROOT_FUNC" ]]; then
  # Accept either bare funcname (auto-pick first file) or full FILE::::FUNC key
  if [[ "$_ROOT_FUNC" == *"${_SEP}"* ]]; then
    _ROOT_KEY="$_ROOT_FUNC"
  else
    for _K in "${ALL_FUNCS[@]}"; do
      if [[ "$(_kfunc "$_K")" == "$_ROOT_FUNC" ]]; then
        _ROOT_KEY="$_K"; break
      fi
    done
  fi
  [[ -z "$_ROOT_KEY" ]] && { printf 'ERROR: function "%s" not found.\n' "$_ROOT_FUNC" >&2; exit 1; }

  declare -A _REACHED=()
  declare -a _QUEUE=("$_ROOT_KEY")
  _REACHED[$_ROOT_KEY]=1
  while [[ ${#_QUEUE[@]} -gt 0 ]]; do
    _H="${_QUEUE[0]}"; _QUEUE=("${_QUEUE[@]:1}")
    for _C in ${CALLS[$_H]:-}; do
      [[ -z "${_REACHED[$_C]:-}" ]] && { _REACHED[$_C]=1; _QUEUE+=("$_C"); }
    done
  done
  for _K in "${ALL_FUNCS[@]}"; do
    [[ -n "${_REACHED[$_K]:-}" ]] && VISIBLE_FUNCS+=("$_K")
  done
else
  VISIBLE_FUNCS=("${ALL_FUNCS[@]}")
fi

# =============================================================================
# 256-COLOR MAP  (keyed by funcname for display)
# =============================================================================
declare -A FUNC_COLOR=()
if [[ $_USE_COLOR -eq 1 ]]; then
  declare -A _SNAME=()
  declare -a _UNAMES=()
  for _K in "${VISIBLE_FUNCS[@]}"; do
    _N=$(_kfunc "$_K")
    if [[ -z "${_SNAME[$_N]:-}" ]]; then _UNAMES+=("$_N"); _SNAME[$_N]=1; fi
  done
  mapfile -t _SORTED < <(printf '%s\n' "${_UNAMES[@]}" | sort)
  _NF=${#_SORTED[@]}
  for (( _ci=0; _ci<_NF; _ci++ )); do
    (( _NF == 1 )) && _C=125 || _C=$(( 40 + 170 * _ci / (_NF - 1) ))
    FUNC_COLOR["${_SORTED[$_ci]}"]=$_C
  done
fi

_GREY=244

_color() {  # funcname  use_color
  if [[ ${2:-0} -eq 1 && -n "${FUNC_COLOR[$1]:-}" ]]; then
    printf '\033[38;5;%dm%s\033[0m' "${FUNC_COLOR[$1]}" "$1"
  else
    printf '%s' "$1"
  fi
}
_grey() {   # text  use_color
  if [[ ${2:-0} -eq 1 ]]; then
    printf '\033[38;5;%dm%s\033[0m' "$_GREY" "$1"
  else
    printf '%s' "$1"
  fi
}
_seen_marker() {  # funcname  use_color
  if [[ ${2:-0} -eq 1 && -n "${FUNC_COLOR[$1]:-}" ]]; then
    printf '  [\033[38;5;%dmseen\033[0m]' "${FUNC_COLOR[$1]}"
  else
    printf '  [seen]'
  fi
}

_uniq_calls_raw() {  # key → unique callee-keys, space-separated
  local _raw="${CALLS[$1]:-}"
  [[ -z "$_raw" ]] && return
  local -A _sw=(); local _out="" _w
  for _w in $_raw; do
    [[ -n "${_sw[$_w]:-}" ]] && continue
    _sw[$_w]=1; [[ -n "$_out" ]] && _out+=" "; _out+="$_w"
  done
  printf '%s' "$_out"
}

_uniq_calls_names() {  # key → unique callee funcnames (display only)
  local _raw; _raw=$(_uniq_calls_raw "$1")
  [[ -z "$_raw" ]] && return
  local _out="" _ck
  for _ck in $_raw; do
    local _fn; _fn=$(_kfunc "$_ck")
    [[ -n "$_out" ]] && _out+=" "; _out+="$_fn"
  done
  printf '%s' "$_out"
}

# =============================================================================
# ROOT DETECTION
# =============================================================================
declare -A _IS_CALLEE=()
for _K in "${ALL_FUNCS[@]}"; do
  for _CK in ${CALLS[$_K]:-}; do _IS_CALLEE[$_CK]=1; done
done

declare -a ROOTS=()
if [[ -n "$_ROOT_KEY" ]]; then
  ROOTS=("$_ROOT_KEY")
else
  for _K in "${ALL_FUNCS[@]}"; do
    [[ -z "${_IS_CALLEE[$_K]:-}" ]] && ROOTS+=("$_K")
  done
  [[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("${ALL_FUNCS[@]}")
fi

# =============================================================================
# TREE EMITTER
# =============================================================================
declare -A _SEEN_SUB=()

_emit() {
  local _key=$1 _pre=$2 _cont=$3 _depth=$4 _vis=$5 _col=${6:-0}
  local _fn _children _marker _ann

  _fn=$(_kfunc "$_key")
  _children="${CALLS[$_key]:-}"
  _marker=""; _ann=""

  if [[ $_MULTI -eq 1 ]]; then
    local _bn; _bn=$(_kbase "$_key")
    _ann="  [${_bn}]"
  fi

  if [[ ":${_vis}:" == *":${_key}:"* ]]; then
    _marker="  [cycle]"
  elif [[ $_SEE_ALL -eq 0 && -n "$_children" && -n "${_SEEN_SUB[$_key]:-}" ]]; then
    _marker="$(_seen_marker "$_fn" "$_col")"
  fi

  printf '%s%s()%s  %s%s\n' \
    "$_pre" \
    "$(_color "$_fn" "$_col")" \
    "$(_grey "$_ann" "$_col")" \
    "$(_grey "-> ${RTYPE[$_key]:-?}" "$_col")" \
    "$_marker"

  [[ -n "$_marker" || "$_depth" -ge "$_MAX_DEPTH" ]] && return
  [[ -z "$_children" ]] && return

  _SEEN_SUB[$_key]=1
  local _vis2="${_vis}:${_key}"
  local -a _arr; read -ra _arr <<< "$_children"
  local _n=${#_arr[@]} _i
  for (( _i=0; _i<_n; _i++ )); do
    if (( _i == _n-1 )); then
      _emit "${_arr[$_i]}" "${_cont}└── " "${_cont}    " $(( _depth+1 )) "$_vis2" "$_col"
    else
      _emit "${_arr[$_i]}" "${_cont}├── " "${_cont}│   " $(( _depth+1 )) "$_vis2" "$_col"
    fi
  done
}

# =============================================================================
# SUMMARY TABLE
# =============================================================================
_print_table() {
  local _col=${1:-0}

  _calls_field() {
    local _raw; _raw=$(_uniq_calls_names "$1"); [[ -z "$_raw" ]] && _raw="----"
    if [[ $_col -eq 0 ]]; then printf '%s' "$_raw"; return; fi
    if [[ "$_raw" == "----" ]]; then _grey "----" 1; return; fi
    local _out="" _w
    for _w in $_raw; do _out+="${_out:+ }$(_color "$_w" 1)"; done
    printf '%s' "$_out"
  }

  printf '\n'
  if [[ $_MULTI -eq 1 ]]; then
    printf '  %-28s  %-22s  %6s  %-40s  %s\n' \
      "function" "file" "called" "calls" "return type"
    printf '  %s  %s  %s  %s  %s\n' \
      "────────────────────────────" "──────────────────────" \
      "──────" "────────────────────────────────────────" "──────────────────────"
  else
    printf '  %-28s  %6s  %-40s  %s\n' \
      "function" "called" "calls" "return type"
    printf '  %s  %s  %s  %s\n' \
      "────────────────────────────" "──────" \
      "────────────────────────────────────────" "──────────────────────"
  fi

  local _k _fn _bn _raw _pf _pd _pb
  for _k in "${VISIBLE_FUNCS[@]}"; do
    _fn=$(_kfunc "$_k")
    _raw=$(_uniq_calls_names "$_k"); [[ -z "$_raw" ]] && _raw="----"
    _pf=$(( 28 - ${#_fn} ));   (( _pf < 0 )) && _pf=0
    _pd=$(( 40 - ${#_raw} ));  (( _pd < 0 )) && _pd=0

    if [[ $_MULTI -eq 1 ]]; then
      _bn=$(_kbase "$_k")
      _pb=$(( 22 - ${#_bn} )); (( _pb < 0 )) && _pb=0
      printf '  %s%*s  %s%*s  %6s  %s%*s  %s\n' \
        "$(_color "$_fn" "$_col")" "$_pf" "" \
        "$(_grey "$_bn"  "$_col")" "$_pb" "" \
        "${FREQ[$_k]:-0}" \
        "$(_calls_field "$_k")" "$_pd" "" \
        "${RTYPE[$_k]:-?}"
    else
      printf '  %s%*s  %6s  %s%*s  %s\n' \
        "$(_color "$_fn" "$_col")" "$_pf" "" \
        "${FREQ[$_k]:-0}" \
        "$(_calls_field "$_k")" "$_pd" "" \
        "${RTYPE[$_k]:-?}"
    fi
  done
  printf '\n'
}

# =============================================================================
# ASCII TREE + TABLE
# =============================================================================
_print_ascii() {
  local _col=${1:-0}
  _SEEN_SUB=()
  printf '\n  %s  (depth=%s)\n\n' "$_TITLE" "$_MAX_DEPTH"
  local _r
  for _r in "${ROOTS[@]}"; do
    _emit "$_r" "" "" 0 "" "$_col"
    printf '\n'
  done
  _print_table "$_col"
}

# =============================================================================
# MERMAID WRITER
# =============================================================================
_write_mermaid() {
  local _out_file=$1
  local _k _ck _f _bn _sid _fn _kf _kb _ks _kn _cf _cb _cs _cn _eid
  declare -A _fmap=() _eseen=()

  {

    if [[ $_MULTI -eq 1 ]]; then
      # build file → keys map
      for _k in "${ALL_FUNCS[@]}"; do
        _f=$(_kfile "$_k"); _fmap[$_f]+=" $_k"
      done
      # one subgraph per file
      for _f in $(printf '%s\n' "${!_fmap[@]}" | sort); do
        _bn="${_f##*/}"; _sid="${_bn//[^A-Za-z0-9_]/_}"
        printf '  subgraph %s["%s"]\n' "$_sid" "$_bn"
        for _k in ${_fmap[$_f]}; do
          _fn=$(_kfunc "$_k")
          printf '    %s_%s["%s %s()"]\n' "$_sid" "$_fn" "${RTYPE[$_k]:-void}" "$_fn"
        done
        printf '  end\n'
      done
    else
      for _k in "${ALL_FUNCS[@]}"; do
        _fn=$(_kfunc "$_k")
        printf '  %s["%s %s()"]\n' "$_fn" "${RTYPE[$_k]:-void}" "$_fn"
      done
    fi

    printf '\n'
    for _k in "${ALL_FUNCS[@]}"; do
      for _ck in ${CALLS[$_k]:-}; do
        _eid="${_k}->${_ck}"
        [[ -n "${_eseen[$_eid]:-}" ]] && continue
        _eseen[$_eid]=1
        if [[ $_MULTI -eq 1 ]]; then
          _kf=$(_kfile "$_k");  _kb="${_kf##*/}"; _ks="${_kb//[^A-Za-z0-9_]/_}"; _kn=$(_kfunc "$_k")
          _cf=$(_kfile "$_ck"); _cb="${_cf##*/}"; _cs="${_cb//[^A-Za-z0-9_]/_}"; _cn=$(_kfunc "$_ck")
          printf '  %s_%s --> %s_%s\n' "$_ks" "$_kn" "$_cs" "$_cn"
        else
          printf '  %s --> %s\n' "$(_kfunc "$_k")" "$(_kfunc "$_ck")"
        fi
      done
    done
  } > "$_out_file"
}

# =============================================================================
# DOT WRITER
# =============================================================================
_write_dot() {
  local _out_file=$1
  local _k _ck _f _bn _fn _ci _eid
  declare -A _fmap=() _eseen=()

  {
    printf 'digraph callgraph {\n'
    printf '    graph [label="%s" labelloc=t fontname="Courier" fontsize=14];\n' "$_TITLE"
    printf '    node  [shape=box fontname="Courier" style=filled fillcolor="#f5f5f5"];\n'
    printf '    edge  [fontname="Courier" fontsize=10];\n'
    printf '    rankdir=LR;\n\n'

    if [[ $_MULTI -eq 1 ]]; then
      for _k in "${ALL_FUNCS[@]}"; do
        _f=$(_kfile "$_k"); _fmap[$_f]+=" $_k"
      done
      _ci=0
      for _f in $(printf '%s\n' "${!_fmap[@]}" | sort); do
        _bn="${_f##*/}"
        printf '    subgraph cluster_%d {\n' "$_ci"
        printf '        label="%s"; style=filled; fillcolor="#eeeeee";\n' "$_bn"
        for _k in ${_fmap[$_f]}; do
          _fn=$(_kfunc "$_k")
          printf '        "%s" [label="%s\\n%s()\\ncalled: %s"];\n' \
            "$_k" "${RTYPE[$_k]:-void}" "$_fn" "${FREQ[$_k]:-0}"
        done
        printf '    }\n\n'
        _ci=$(( _ci + 1 ))
      done
    else
      for _k in "${ALL_FUNCS[@]}"; do
        _fn=$(_kfunc "$_k")
        printf '    "%s" [label="%s\\n%s()\\ncalled: %s"];\n' \
          "$_fn" "${RTYPE[$_k]:-void}" "$_fn" "${FREQ[$_k]:-0}"
      done
    fi

    printf '\n'
    for _k in "${ALL_FUNCS[@]}"; do
      for _ck in ${CALLS[$_k]:-}; do
        _eid="${_k}->${_ck}"
        [[ -n "${_eseen[$_eid]:-}" ]] && continue
        _eseen[$_eid]=1
        if [[ $_MULTI -eq 1 ]]; then
          printf '    "%s" -> "%s";\n' "$_k" "$_ck"
        else
          printf '    "%s" -> "%s";\n' "$(_kfunc "$_k")" "$(_kfunc "$_ck")"
        fi
      done
    done
    printf '}\n'
  } > "$_out_file"
}

# =============================================================================
# TIMING FOOTER
# =============================================================================
# Timestamps (ms integers captured via _ts_ms):
#   _T_START        before perl invocation
#   _T_BACKEND_END  after perl + bash array loading
#   _T_PRINT_START  before terminal render
#   _T_PRINT_END    after  terminal render
#   _T_END          after all --out-* writes
#
# Line counters:
#   _LINES_READ     raw source lines across all input files  (from perl)
#   _LINES_CLI      lines written to terminal                (from wc -l on tmp)
#   _LINES_FILE     lines written to all --out-* files       (accumulated via wc -l)
#
# Timing rows:
#   graph  = perl parse + comment-strip + call-edge analysis + bash array load
#   print  = ASCII tree traversal + summary table render (terminal)
#   file   = all --out-* writes combined (row omitted when no files requested)
#   total  = wall time of the entire run
#
# Line rows:
#   read   = raw source lines consumed
#   write  = cli lines
#            file lines  (file part omitted when no files requested)
# =============================================================================
_LINES_CLI=0
_LINES_FILE=0

_print_timing() {
  local _t_graph=$(( _T_BACKEND_END - _T_START      ))
  local _t_print=$(( _T_PRINT_END   - _T_PRINT_START ))
  local _t_file=$((  _T_END         - _T_PRINT_END   ))
  local _t_total=$(( _T_END         - _T_START       ))
  local _W=8   # right-aligned value column width

  printf '\n'
  printf '  %-8s  %*s ms\n' "mapping"  "$_W" "$_t_graph"
  printf '  %-8s  %*s ms\n' "print"  "$_W" "$_t_print"
  if [[ -n "$_OUT_TXT$_OUT_MMD$_OUT_DOT" ]]; then
    printf '  %-8s  %*s ms\n' "file" "$_W" "$_t_file"
  fi
  printf '  %s\n' "$(printf '%0.s─' {1..22})"
  printf '  %-8s  %*s ms\n' "total"  "$_W" "$_t_total"

  printf '\n'
  printf '  %-8s  %*s lines (c++)\n' "read"   "$_W" "$_LINES_READ"
  printf '  %-8s  %*s lines (cli)\n' "write" "$_W" "$_LINES_CLI"
  if [[ -n "$_OUT_TXT$_OUT_MMD$_OUT_DOT" ]]; then
    printf '            %*s lines (file)\n' "$_W" "$_LINES_FILE"
  fi
  printf '\n'
}

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================
_T_PRINT_START=$(_ts_ms)
_TMP_CLI=$(mktemp)
_print_ascii "$_USE_COLOR" > "$_TMP_CLI"
_LINES_CLI=$(wc -l < "$_TMP_CLI")
_T_PRINT_END=$(_ts_ms)
cat "$_TMP_CLI"
rm -f "$_TMP_CLI"

# =============================================================================
# FILE OUTPUTS
# =============================================================================
if [[ -n "$_OUT_TXT" ]]; then
  _print_ascii 0 > "$_OUT_TXT"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_TXT") ))
  printf '  -> plain text  : %s\n' "$_OUT_TXT"
fi

if [[ -n "$_OUT_MMD" ]]; then
  _write_mermaid "$_OUT_MMD"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_MMD") ))
  printf '  -> Mermaid     : %s\n' "$_OUT_MMD"
fi

if [[ -n "$_OUT_DOT" ]]; then
  _write_dot "$_OUT_DOT"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_DOT") ))
  printf '  -> DOT    : %s  (render: dot -Tsvg -o graph.svg %s)\n' "$_OUT_DOT" "$_OUT_DOT"
fi

_T_END=$(_ts_ms)
_print_timing
