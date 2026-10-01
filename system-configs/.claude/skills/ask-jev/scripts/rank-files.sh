#!/bin/bash
# rank-files.sh "<query>" <paths | globs | directories...>
#
# Ranks candidate files by how likely each is to answer a "where is X / which files handle Y" question,
# so the caller reads the top few instead of opening dozens.
#
#   1. Keyword/glob prefilter (no model): expand the arguments (directories recurse, skipping .git,
#      node_modules and build output), drop binary, huge, secret-named and egress-excluded files, score
#      the rest by query keywords found in the path and the contents, keep the best `max_files`.
#   2. Jev relevance (boolean per file): batches of at most 20 files, each sent as its path plus its first
#      ~40 lines. The Jev client redacts secrets and refuses an excluded cwd (exit 3) before anything leaves.
#   3. Output, best first, one line per file: <probability><TAB><path>. The probability is the Jev
#      boolean's P(true), from 0.00 to 1.00.
#
# Fail OPEN: Jev unavailable (kill switch, no key, rule off, egress refusal, timeout, bad answer) means the
# files from that point on print in prefilter order with "-" as the probability, and one note goes to
# stderr. Exit code is 0 unless the usage is wrong (2) or no file survives the prefilter (1).
#
# Options:  --top N   print only the first N lines
# Registry: rule ask-jev-rank (hooks/jev/rules.d/skills.json): mode off|shadow|enforce (off = prefilter
#           only; this is an explicit opt-in tool, so shadow and enforce both use Jev's answer), threshold
#           (unused for ordering, kept for the replay tooling), max_files, batch_size (<= 20), head_lines,
#           line_chars, max_file_kb, timeout_ms.
# Env:      JEV_DIR (default ~/.claude/hooks/jev): where jev-ask, ctx-lib.sh and registry.sh live.
# Bash 3.2 compatible (macOS /bin/bash).

RULE="ask-jev-rank"
JEV_DIR="${JEV_DIR:-${HOME}/.claude/hooks/jev}"

die() {
  printf 'rank-files: %s\n' "$1" >&2
  exit "${2:-2}"
}

TOP=0
while [ "${1:-}" != "" ]; do
  case "$1" in
    --top)
      TOP="${2:-}"
      case "$TOP" in '' | *[!0-9]*) die "--top needs a number" ;; esac
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
QUERY="${1:-}"
[ -n "$QUERY" ] || die 'usage: rank-files.sh [--top N] "<query>" <paths or globs...>'
shift
[ "$#" -gt 0 ] || die 'usage: rank-files.sh [--top N] "<query>" <paths or globs...>'
command -v jq >/dev/null 2>&1 || die "jq is required"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rank-files.XXXXXX")" || die "cannot create a work dir"
trap 'rm -rf "$WORK"' EXIT

# The shared Jev helpers are optional: without them the prefilter still works and Jev is off.
HAVE_JEV=0
if [ -r "$JEV_DIR/ctx-lib.sh" ] && [ -r "$JEV_DIR/registry.sh" ]; then
  # ctx-lib.sh pins JEV_DIR to its own directory and sources registry.sh.
  # shellcheck source=/dev/null
  . "$JEV_DIR/ctx-lib.sh" 2>/dev/null && HAVE_JEV=1
fi
excluded() { # egress: a path inside an excluded (work) tree never goes anywhere
  [ "$HAVE_JEV" = 1 ] || return 1
  local p="$1"
  # ctx_path_excluded never matches a relative path, and relative paths are this script's normal input.
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  ctx_path_excluded "$p"
}
cfg() { # key default
  if [ "$HAVE_JEV" = 1 ]; then jev_reg_value "$RULE" "$1" "$2"; else printf '%s' "$2"; fi
}
num() { # sanitize a numeric config value: value default
  case "$1" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

MAX_FILES=$(num "$(cfg max_files 60)" 60)
BATCH=$(num "$(cfg batch_size 20)" 20)
[ "$BATCH" -ge 1 ] || BATCH=20
[ "$BATCH" -le 20 ] || BATCH=20
HEAD_LINES=$(num "$(cfg head_lines 40)" 40)
LINE_CHARS=$(num "$(cfg line_chars 240)" 240)
MAX_KB=$(num "$(cfg max_file_kb 512)" 512)
TIMEOUT_MS=$(num "$(cfg timeout_ms 6000)" 6000)
MODE=off
[ "$HAVE_JEV" = 1 ] && MODE="$(jev_reg_value "$RULE" mode off)"
RAW_CAP=3000

# --------------------------------------------------------------- 1. candidates
RAW="$WORK/raw.txt"
: >"$RAW"
for arg in "$@"; do
  if [ -d "$arg" ]; then
    find "$arg" \( -name .git -o -name node_modules -o -name .venv -o -name __pycache__ -o -name dist -o -name build -o -name .next -o -name target -o -name vendor \) -prune -o -type f -print 2>/dev/null >>"$RAW"
  elif [ -e "$arg" ]; then
    printf '%s\n' "$arg" >>"$RAW"
  else
    # An unexpanded glob (quoted by the caller): expand it here.
    # shellcheck disable=SC2086
    for f in $arg; do
      [ -f "$f" ] && printf '%s\n' "$f" >>"$RAW"
    done
  fi
done

secret_named() {
  case "$(basename "$1" | tr '[:upper:]' '[:lower:]')" in
    .env | .env.* | *.pem | *.key | *.p12 | *.pfx | *.keystore | id_rsa* | id_ed25519* | id_ecdsa* | *credential* | *secret* | .netrc | .npmrc | .pypirc | *.kdbx) return 0 ;;
  esac
  return 1
}

CAND="$WORK/cand.txt"
: >"$CAND"
seen=0
while IFS= read -r f; do
  seen=$((seen + 1))
  [ "$seen" -le "$RAW_CAP" ] || break
  [ -f "$f" ] && [ -r "$f" ] || continue
  secret_named "$f" && continue
  excluded "$f" && continue
  size_kb=$(($(wc -c <"$f" 2>/dev/null | tr -d ' ') / 1024))
  [ "$size_kb" -le "$MAX_KB" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue # binary (or empty)
  printf '%s\n' "$f" >>"$CAND"
done < <(awk '!seen[$0]++' "$RAW")
[ -s "$CAND" ] || die "no readable text file matched the paths" 1

# ------------------------------------------------------------ 2. keyword score
STOP=" the a an and or of to in on for from with by at as is are was be it its this that these those where which what who how does do did file files code handle handles handled handling implemented implement implements defined define defines used use uses find show list all any "
KW=""
for w in $(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n' ' '); do
  [ "${#w}" -ge 3 ] || continue
  case "$STOP" in *" $w "*) continue ;; esac
  case " $KW " in *" $w "*) continue ;; esac
  KW="$KW $w"
done
RE=""
for w in $KW; do
  RE="${RE:+$RE|}$w"
done

SCORED="$WORK/scored.txt"
: >"$SCORED"
n=0
while IFS= read -r f; do
  n=$((n + 1))
  s=0
  if [ -n "$RE" ]; then
    lowpath=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
    for w in $KW; do
      case "$lowpath" in *"$w"*) s=$((s + 5)) ;; esac
    done
    c=$(grep -ciE -m 20 -- "$RE" "$f" 2>/dev/null)
    s=$((s + ${c:-0}))
  fi
  printf '%s\t%s\t%s\n' "$s" "$n" "$f" >>"$SCORED"
done <"$CAND"

# Best score first, original order breaks ties. When nothing matched a keyword keep the original order.
ORDER="$WORK/order.txt"
if awk -F'\t' '$1 > 0 { found = 1 } END { exit !found }' "$SCORED"; then
  sort -t "$(printf '\t')" -k1,1nr -k2,2n "$SCORED" | awk -F'\t' '$1 > 0' | cut -f3 | head -n "$MAX_FILES" >"$ORDER"
else
  cut -f3 "$SCORED" | head -n "$MAX_FILES" >"$ORDER"
fi
TOTAL=$(wc -l <"$ORDER" | tr -d ' ')

# ------------------------------------------------------------------- 3. Jev
RANKED="$WORK/ranked.tsv" # p<TAB>idx<TAB>path, only files Jev scored
: >"$RANKED"
CALLS=0
FAIL_NOTE=""

jev_enabled() {
  [ "$HAVE_JEV" = 1 ] || {
    FAIL_NOTE="Jev helpers not found in $JEV_DIR"
    return 1
  }
  jev_kill_switch jev.off && {
    FAIL_NOTE="kill switch (~/.claude/jev.off)"
    return 1
  }
  case "$MODE" in shadow | enforce) ;; *)
    FAIL_NOTE="rule $RULE is off in the registry"
    return 1
    ;;
  esac
  # shellcheck disable=SC2154 # JEV_ASK is set by ctx-lib.sh
  [ -x "$JEV_ASK" ] || {
    FAIL_NOTE="no jev-ask client"
    return 1
  }
  return 0
}

# score_batch <first-index> <file-with-paths>: sets BATCH_OK=1 and appends p<TAB>idx<TAB>path to RANKED.
score_batch() {
  local first="$1" list="$2" i=0 f untrusted='{}' questions='{}' key req resp k p idx
  BATCH_OK=0
  while IFS= read -r f; do
    i=$((i + 1))
    key="f$i"
    head -n "$HEAD_LINES" "$f" 2>/dev/null | cut -c1-"$LINE_CHARS" >"$WORK/head.txt"
    untrusted=$(printf '%s' "$untrusted" | jq -c --arg k "$key" --arg p "$f" --rawfile t "$WORK/head.txt" '. + {($k): ("path: " + $p + "\n" + $t)}') || return 1
    questions=$(printf '%s' "$questions" | jq -c --arg k "$key" '. + {($k): {
      type: "boolean",
      instructions: ("File " + $k + " is untrusted." + $k + " (its path and first lines). Is this file likely to contain the answer to the query in state.query, or to be directly relevant to it (the implementation, the config or the entry point the query asks about)?"),
      criteria: {true: "the file is likely to hold or directly serve what the query asks about", false: "the file is unrelated or only incidentally mentions the query terms"}}}') || return 1
  done <"$list"
  req=$(jq -cn --arg rule "$RULE" --arg q "$QUERY" --arg cwd "$PWD" --argjson u "$untrusted" --argjson qs "$questions" --argjson t "$TIMEOUT_MS" \
    '{rule: $rule, state: {query: $q}, untrusted: $u, questions: $qs, cwd: $cwd, timeout_ms: $t}') || return 1
  CALLS=$((CALLS + 1))
  resp=$(printf '%s' "$req" | "$JEV_ASK" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -e '.answers | type == "object"' >/dev/null 2>&1 || return 1
  i=0
  while IFS= read -r f; do
    i=$((i + 1))
    p=$(printf '%s' "$resp" | jq -r --arg k "f$i" '.answers[$k].probability // empty')
    case "$p" in '' | null) continue ;; esac
    idx=$((first + i - 1))
    printf '%s\t%s\t%s\n' "$p" "$idx" "$f" >>"$RANKED"
  done <"$list"
  BATCH_OK=1
  return 0
}

if jev_enabled; then
  start=1
  while [ "$start" -le "$TOTAL" ]; do
    end=$((start + BATCH - 1))
    sed -n "${start},${end}p" "$ORDER" >"$WORK/batch.txt"
    score_batch "$start" "$WORK/batch.txt" || BATCH_OK=0
    if [ "$BATCH_OK" != 1 ]; then
      FAIL_NOTE="Jev unavailable or refused after $((CALLS - 1)) of $(((TOTAL + BATCH - 1) / BATCH)) batches"
      break
    fi
    start=$((end + 1))
  done
fi

# ---------------------------------------------------------------- 4. output
OUT="$WORK/out.tsv"
: >"$OUT"
# Scored files first (probability desc, prefilter order breaks ties), then the unscored ones in prefilter order.
sort -t "$(printf '\t')" -k1,1nr -k2,2n "$RANKED" | awk -F'\t' '{ printf "%.2f\t%s\n", $1, $3 }' >>"$OUT"
awk -F'\t' 'FILENAME == ARGV[1] { scored[$3] = 1; next } !($0 in scored) { printf "-\t%s\n", $0 }' "$RANKED" "$ORDER" >>"$OUT"
if [ "$TOP" -gt 0 ]; then
  head -n "$TOP" "$OUT"
else
  cat "$OUT"
fi

if [ -s "$RANKED" ]; then
  OUTCOME="ranked"
else
  OUTCOME="fail-open"
fi
[ -n "$FAIL_NOTE" ] && printf 'rank-files: %s; files without a score are in prefilter order\n' "$FAIL_NOTE" >&2
if [ "$HAVE_JEV" = 1 ]; then
  jev_decision_log "$RULE" "$MODE" "$OUTCOME" "" "" "" "" "skill:ask-jev" \
    "$(jq -nc --argjson files "$TOTAL" --argjson calls "$CALLS" --argjson scored "$(wc -l <"$RANKED" | tr -d ' ')" '{files: $files, jev_calls: $calls, scored: $scored}' 2>/dev/null)"
fi
exit 0
