#!/bin/bash
# Shared helpers for the Jev context/cost hooks (Phase 3, use cases A1-A8).
# Sourced by the a*-*.sh hook scripts; never executed on its own.
#
# Contract (see ~/.tmp/plans/2026-09-30-jev-client-contract.md):
#   - Jev is reached ONLY through ./jev-ask (stdin JSON -> stdout JSON, exit 3 = unavailable).
#   - Every hook here is a QUALITY hook: any failure, timeout, missing key, kill switch or
#     unreadable config means "do nothing, print nothing, exit 0". Output is only ever
#     emitted as one complete JSON decision.
#   - A rule that is not registered in rules.d/*.json (or jev-rules.json) is OFF.
#   - Registry reader (the SAME semantics as client.mjs rulesRegistry() and jev-gate-lib.sh
#     jev_rules_json): rules.d/*.json in lexical order, then jev-rules.json LAST, so the user's
#     jev-rules.json overrides rules.d. Each file is {"exempt_agents":[...], "rules":{"<id>":{...}}}
#     (a flat {"<id>":{...}} is tolerated); entries merge key by key, later files win.
#   - Big payloads go through files (--rawfile/--slurpfile), never --arg: a hook input can be
#     megabytes and a single argv entry is capped (128KB on Linux).

JEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JEV_CLAUDE_DIR="${HOME}/.claude"
JEV_ASK="${JEV_DIR}/jev-ask"
# Legacy hook-verdict log, kept as an ALIAS for one release; decisions.jsonl (registry.sh) is the log to read.
JEV_SHADOW_LOG="${JEV_CLAUDE_DIR}/jev-shadow.jsonl"
JEV_CACHE_DIR="${JEV_CLAUDE_DIR}/jev-cache"
JEV_STATE_DIR="${JEV_CACHE_DIR}/state"

# The ONE registry reader, decision log and kill-switch rules (registry.sh).
# shellcheck source=registry.sh
. "${JEV_DIR}/registry.sh" || return 1

# ---------------------------------------------------------------- bootstrap

# ctx_session_kind: fleet | bgjob | interactive (same env signals settings.json already uses).
ctx_session_kind() {
  if [ -n "${BARECLAUDE_AGENT_SLUG:-}" ]; then
    echo fleet
  elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    echo bgjob
  else
    echo interactive
  fi
}

# ctx_bootstrap <rule>
# Reads the hook JSON from stdin into $WORK/in.json and resolves the rule's registry entry.
# Returns 1 when the hook must silently do nothing. Sets: WORK INPUT_FILE RULE RULE_JSON
# RULE_MODE RULE_THRESHOLD.
ctx_bootstrap() {
  ctx_prepare || return 1
  ctx_rule_load "$1" || return 1
  return 0
}

# ctx_prepare: stdin -> $WORK/in.json; returns 1 when jq is missing, the input is empty or the
# kill switch ~/.claude/jev.off exists. Scripts that serve several rules call this once, then
# ctx_rule_load per rule.
ctx_prepare() {
  command -v jq >/dev/null 2>&1 || return 1
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-ctx.XXXXXX" 2>/dev/null)" || return 1
  trap 'rm -rf "$WORK"' EXIT
  INPUT_FILE="${WORK}/in.json"
  cat >"$INPUT_FILE" 2>/dev/null
  [ -s "$INPUT_FILE" ] || return 1
  # The kill switch is a regular file; `mkdir ~/.claude/jev.off` must not disable the hooks. (gate.off is
  # the decision gates' master switch and does not touch these quality hooks: see registry.sh.)
  jev_kill_switch jev.off && return 1
  return 0
}

# ctx_rule_load <rule>: sets RULE/RULE_JSON/RULE_MODE/RULE_THRESHOLD; returns 1 if off,
# unregistered or out of scope for this kind of session.
ctx_rule_load() {
  RULE="$1"
  local kind
  # One reader (registry.sh jev_reg_json): questions layer, rules.d/*.json, then jev-rules.json LAST.
  RULE_JSON="$(jev_reg_rule "$1")" || return 1
  [ -n "$RULE_JSON" ] || return 1
  kind="$(ctx_session_kind)"
  # Flatten once to key<TAB>value lines so ctx_cfg is a pure-bash lookup (no jq spawn per read).
  RULE_KV="$(printf '%s' "$RULE_JSON" | jq -r --arg k "$kind" '
    "__inscope\t\(if ((.scope // ["interactive","bgjob","fleet"]) | index($k)) != null then 1 else 0 end)",
    (to_entries[] | "\(.key)\t\(.value | if type == "array" then join(",") else tostring end)")' 2>/dev/null)" || return 1
  RULE_MODE="$(ctx_cfg mode off)"
  [ "$RULE_MODE" = "shadow" ] || [ "$RULE_MODE" = "enforce" ] || return 1
  [ "$(ctx_cfg __inscope 0)" = "1" ] || return 1
  RULE_THRESHOLD="$(ctx_cfg threshold 0.5)"
  return 0
}

# ctx_cfg <key> <default>: a scalar from the loaded rule entry (pure bash lookup in RULE_KV).
ctx_cfg() {
  local k v
  while IFS=$'\t' read -r k v; do
    if [ "$k" = "$1" ] && [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<<"$RULE_KV"
  printf '%s' "$2"
}

# ---------------------------------------------------------------- input access

# ctx_in <jq filter>: raw value from the hook input ("" when absent/null).
ctx_in() {
  jq -r "$1 // empty" "$INPUT_FILE" 2>/dev/null
}

# ctx_task <transcript_path>: the latest real user prompt (<=1500 chars), "" when unknown.
# Skips tool-result turns, meta turns, compact summaries; collapses slash-command wrappers
# to "/name args"; strips <system-reminder> blocks.
ctx_task() {
  [ -n "${1:-}" ] && [ -r "$1" ] || return 0
  tail -c 3000000 "$1" 2>/dev/null | jq -R -n -r '
    [ inputs | fromjson?
      | select(.type == "user" and ((.isMeta // false) | not) and ((.isCompactSummary // false) | not))
      | .message.content as $c
      | (if ($c | type) == "string" then $c
         else ([$c[]? | select(.type == "text") | .text] | join("\n")) end)
      | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "")
      | if test("<command-name>") then
          ((try capture("<command-name>(?<n>[^<]*)</command-name>").n catch "")
           + " " + (try capture("<command-args>(?<a>[^<]*)</command-args>").a catch ""))
        else . end
      | select(test("^\\s*<(local-command|bash-|task-notification)") | not)
      | gsub("^\\s+|\\s+$"; "")
      | select(length > 0)
    ] | (last // "") | .[0:1500]' 2>/dev/null
}

# ---------------------------------------------------------------- Jev + logging

# ctx_jev <request-file>: calls jev-ask; on success writes the reply to $WORK/jev-out.json.
# Returns 0 only for a well-formed reply; anything else (exit 3, bad JSON) is "unavailable".
ctx_jev() {
  local rc
  [ -x "$JEV_ASK" ] || return 3
  "$JEV_ASK" <"$1" >"${WORK}/jev-out.json" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || return 3
  jq -e '.answers | type == "object"' "${WORK}/jev-out.json" >/dev/null 2>&1 || return 3
  return 0
}

# ctx_log <event> <detail-json-file>: one hook-verdict line in the shared shadow log.
# NEVER logs prompt/file content: callers pass counts, ranges, names and probabilities only.
ctx_log() {
  local row ans="" model="" lat=""
  (
    umask 077
    mkdir -p "$JEV_CLAUDE_DIR" 2>/dev/null
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rule "$RULE" --arg mode "$RULE_MODE" \
      --arg ev "$1" --arg cwd "$(ctx_in .cwd)" --slurpfile d "$2" \
      '{ts:$ts, rule:$rule, kind:"hook_verdict", mode:$mode, event:$ev, cwd:$cwd, detail:$d[0]}' \
      >>"$JEV_SHADOW_LOG" 2>/dev/null
  )
  # The decision line carries the Jev reply of this hook run when there was one (answers, model, latency).
  if [ -s "${WORK:-/nonexistent}/jev-out.json" ]; then
    row="$(jq -r '[(.answers | tojson), (.model // "-"), ((.latency_ms // "-") | tostring)] | @tsv' "${WORK}/jev-out.json" 2>/dev/null)" || row=""
    if [ -n "$row" ]; then
      IFS=$'\t' read -r ans model lat <<<"$row"
      [ "$model" = "-" ] && model=""
      [ "$lat" = "-" ] && lat=""
    fi
  fi
  jev_decision_log "$RULE" "$RULE_MODE" "$1" "" "$ans" "$model" "$lat" "hook:ctx" \
    "$(jq -cn --slurpfile d "$2" '{detail:$d[0]}' 2>/dev/null)"
  return 0
}

# ctx_realpath <abs path>: best-effort physical path (symlinks resolved) even when the leaf does not
# exist: the deepest existing ancestor is resolved with `cd -P`, a symlink leaf is followed (<= 8 hops).
ctx_realpath() {
  local p="$1" tail="" d hop=0 t
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ -L "$p" ] && [ "$hop" -lt 8 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    hop=$((hop + 1))
  done
  d="${p%/}"
  [ -n "$d" ] || d="/"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do
    tail="/$(basename "$d")$tail"
    d="$(dirname "$d")"
  done
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  [ "$d" = "/" ] && d=""
  printf '%s%s' "$d" "$tail"
}

# ctx_path_excluded <path>: 0 when <path> is under an `exclude_paths` entry of jev-config.json
# (work / Visa repos: D's egress ruling). The client already refuses by cwd; this closes the gap
# where a session started elsewhere Reads/Greps into an excluded tree.
# SAME semantics as client.mjs excludedPrefixes(): each entry is a directory prefix anchored at "/" or
# at $HOME ("~/work"; a bare "work" means ~/work), matched case-insensitively on a path-segment
# boundary. Both sides are compared raw AND physical (symlinks resolved; $HOME too). A trailing "/",
# "/*" or "/**" is ignored; non-string entries are ignored. A relative <path> never matches. An
# unreadable config counts as "excluded" (fail closed on egress). No jev-config.json (Phase 0 not
# deployed) -> nothing is excluded here.
ctx_path_excluded() {
  local cfg="${JEV_DIR}/jev-config.json" p="${1:-}" real home_real q qr x
  local -a paths=() prefixes=()
  [ -n "$p" ] && [ -f "$cfg" ] || return 1
  jq -e . "$cfg" >/dev/null 2>&1 || return 0
  case "$p" in /*) ;; *) return 1 ;; esac
  real="$(ctx_realpath "$p")" || real="$p"
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_real="$HOME"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    prefixes+=("$q")
    qr="$(ctx_realpath "$q")" && [ -n "$qr" ] && prefixes+=("$qr")
  done < <(jq -r --arg h1 "$HOME" --arg h2 "${home_real:-$HOME}" '
    def trimslash: sub("(/\\*{0,2})+$"; "");
    ([$h1, $h2] | unique) as $homes
    | (.exclude_paths // [])[] | select(type == "string") | gsub("^\\s+|\\s+$"; "") | trimslash | select(length > 0)
    | if startswith("~") then (sub("^~/?"; "") | . as $rel | $homes[] | if $rel == "" then . else . + "/" + $rel end)
      elif startswith("/") then .
      else (. as $rel | $homes[] | . + "/" + $rel) end' "$cfg" 2>/dev/null)
  for x in "$p" "${real:-$p}"; do
    x="$(printf '%s' "${x%/}" | tr '[:upper:]' '[:lower:]')"
    paths+=("$x")
  done
  for x in "${paths[@]}"; do
    for q in "${prefixes[@]}"; do
      q="$(printf '%s' "${q%/}" | tr '[:upper:]' '[:lower:]')"
      [ -n "$q" ] || continue
      case "$x" in "$q" | "$q"/*) return 0 ;; esac
    done
  done
  return 1
}

# ctx_target_excluded [path]: 0 when the egress target is in an excluded tree. A relative [path] is
# resolved against the hook input's .cwd, an empty [path] means the cwd itself (a Grep/Glob without
# a path searches the cwd). Used by every hook that digests repo content.
ctx_target_excluded() {
  local p="${1:-}" cwd
  cwd="$(ctx_in .cwd)"
  [ -n "$cwd" ] || cwd="$PWD"
  case "$p" in
    "") p="$cwd" ;;
    /*) ;;
    *) p="${cwd%/}/$p" ;;
  esac
  ctx_path_excluded "$p"
}

# ctx_cmd_touches_excluded <command>: 0 when a Bash command could produce output from an excluded (work) tree
# even though the session cwd is outside it (`git -C ~/Visa/app test`, `cd ../work && make`, `~/Visa/x/run.sh`).
# Every path-like word of the command is checked (quotes stripped; ~, $HOME and ${HOME} expanded; relative
# words resolved against the hook input's .cwd; a bare word counts when it names something in the cwd). A word
# with any other $VARIABLE cannot be resolved (the hook never sees the agent's shell variables), so it counts as
# touching ($PWD and special parameters like $? excepted; ${NAME} is read as $NAME and ${NAME:-x} fails closed),
# and so does a command with more than 16 candidate words (fail closed on egress). Residual: a script outside the tree that itself reads an
# excluded tree at run time cannot be seen from the command text.
ctx_cmd_touches_excluded() {
  local cmd="${1:-}" cwd tok p n=0
  cwd="$(ctx_in .cwd)"
  [ -n "$cwd" ] || cwd="$PWD"
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      -*) tok="${tok#"${tok%%[!-]*}"}" ;; # --dir=... arrives split on "=": drop leading dashes only
    esac
    [ -n "$tok" ] || continue
    # shellcheck disable=SC2088 # literal "~" in the command text, expanded here on purpose
    case "$tok" in
      "~") tok="$HOME" ;;
      "~/"*) tok="$HOME/${tok#\~/}" ;;
      '$HOME') tok="$HOME" ;;
      '$HOME/'*) tok="$HOME/${tok#\$HOME/}" ;;
      '${HOME}') tok="$HOME" ;;
      '${HOME}/'*) tok="$HOME/${tok#\$\{HOME\}/}" ;;
    esac
    case "$tok" in
      '$PWD') tok="$cwd" ;;
      '$PWD/'*) tok="${cwd%/}/${tok#\$PWD/}" ;;
    esac
    case "$tok" in
      '$' | '$'['?#!@*$-']* | '$'[0-9]*) continue ;; # $( ... ), $?, $1: special parameters, never a path
      *'$'*) return 0 ;;                  # any other unresolved variable may name an excluded tree
    esac
    case "$tok" in
      '\') continue ;;  # a line continuation
      *\\*) return 0 ;; # a shell escape (w\ork) hides the real spelling: ambiguous provenance, no egress
    esac
    case "$tok" in
      /*) p="$tok" ;;
      */* | .*) p="${cwd%/}/$tok" ;;
      *) [ -e "${cwd%/}/$tok" ] || continue; p="${cwd%/}/$tok" ;;
    esac
    n=$((n + 1))
    [ "$n" -le 16 ] || return 0
    ctx_path_excluded "$p" && return 0
  done < <(printf '%s' "$cmd" | tr -d "\"'" | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/$\1/g; s/\$\{/$_/g' |
    tr '[:space:];&|()<>=`{}' '\n' | sed '/^$/d' | sort -u | head -80)
  return 1
}

# ctx_hash: sha256 prefix of stdin (sha256sum on Linux; openssl before shasum on macOS because
# shasum is a perl script that costs ~100ms to start).
ctx_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-16
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-16
  else
    cksum | tr ' ' '-'
  fi
}

# ctx_cache_path <file>: the content-addressed path ~/.claude/jev-cache/<hash>.txt (nothing written).
ctx_cache_path() {
  local h
  h="$(ctx_hash <"$1")"
  [ -n "$h" ] || return 1
  printf '%s' "${JEV_CACHE_DIR}/${h}.txt"
}

# ctx_cache_commit <file> <dest>: write the full text to <dest> (private, 0600), only called once a
# trim is certain so untrimmed outputs never touch the disk. Also prunes cache and per-session
# state older than 14 days (cheap; the dir is small).
ctx_cache_commit() {
  (
    umask 077
    mkdir -p "$JEV_CACHE_DIR" "$JEV_STATE_DIR"
  ) 2>/dev/null || return 1
  [ -f "$2" ] || (umask 077 && cp "$1" "$2") 2>/dev/null || return 1
  find "$JEV_CACHE_DIR" -type f \( -name '*.txt' -o -name '*.mem' -o -name '*.a4' -o -name '*.a9' -o -name '*.first' \) -mtime +14 -delete 2>/dev/null
  return 0
}

# ctx_emit <event> <extra-json-file>: emits {"hookSpecificOutput":{"hookEventName":<event>} + extra}.
ctx_emit() {
  jq -c --arg ev "$1" '{hookSpecificOutput: ({hookEventName: $ev} + .)}' "$2"
}

# ---------------------------------------------------------------- text helpers

# ctx_frontmatter "<key> <key>..." <file>...: ONE awk pass over many files. Prints one line per
# file: path<TAB>value<TAB>value... (tabs/newlines inside values become spaces). Handles quoted
# scalars and folded/literal blocks (">-", "|"), joining continuation lines with spaces.
ctx_frontmatter() {
  local keys="$1"
  shift
  awk -v keys="$keys" '
    function flush(   i, v, out) {
      if (fname == "") return
      out = fname
      for (i = 1; i <= n; i++) {
        v = V[K[i]]
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
        gsub(/\t/, " ", v)
        out = out "\t" v
      }
      print out
    }
    BEGIN { n = split(keys, K, " ") }
    FNR == 1 {
      flush()
      fname = FILENAME; cur = ""; state = ($0 == "---") ? 1 : 0
      for (i = 1; i <= n; i++) V[K[i]] = ""
      next
    }
    state != 1 { next }
    $0 == "---" { state = 2; next }
    {
      if (cur != "") {
        if ($0 ~ /^[ \t]+/ || $0 == "") { t = $0; sub(/^[ \t]+/, "", t); V[cur] = V[cur] " " t; next }
        cur = ""
      }
      for (i = 1; i <= n; i++) {
        k = K[i]
        if (index($0, k ":") == 1) {
          v = substr($0, length(k) + 2)
          sub(/^[ \t]+/, "", v)
          if (v ~ /^[>|][-+]?$/) { cur = k; V[k] = "" } else V[k] = v
          break
        }
      }
    }
    END { flush() }' "$@" 2>/dev/null
}

# ctx_memory_candidates <memory-index> <outfile>: [{id:"m<i>", title, file, text}] from the
# "- [Title](file.md) — hook" lines of MEMORY.md. `text` (<=260 chars) is what Jev sees.
ctx_memory_candidates() {
  jq -R -n '
    [ inputs | select(test("^- \\[")) | try capture("^- \\[(?<title>[^\\]]*)\\]\\((?<file>[^)]*)\\)\\s*(?<hook>.*)$") ]
    | to_entries
    | map(.value + {id: "m\(.key)"}
          | . + {text: (.title + " " + (.hook | sub("^[—–-]+\\s*"; "— ")) | .[0:260])})' "$1" >"$2" 2>/dev/null
}

# ctx_rule_candidates <outfile> <markdown-file>...: [{id:"r<i>", src, title, text, full}] - one per
# "#"/"##" section. `text` (<=300 chars) is what Jev sees; `full` (<=700 chars) is what gets injected.
ctx_rule_candidates() {
  local out="$1" f
  shift
  : >"${WORK}/rules.ndjson"
  for f in "$@"; do
    [ -f "$f" ] || continue
    jq -R -n --arg src "$(basename "$(dirname "$f")")/$(basename "$f")" '
      reduce inputs as $l ([];
        if ($l | test("^##? ")) then . + [{src: $src, title: ($l | sub("^#+ +"; "")), body: []}]
        elif ($l | length) > 0 and length > 0 then (.[-1].body += [$l])
        else . end)
      | map(select(.body | length > 0) | {src, title, full: ((.title + "\n" + (.body | join("\n"))) | .[0:700]),
                                           text: ((.title + " — " + (.body[0:3] | join(" "))) | .[0:300])})
      | .[]' "$f" >>"${WORK}/rules.ndjson" 2>/dev/null
  done
  jq -s 'to_entries | map(.value + {id: "r\(.key)"})' "${WORK}/rules.ndjson" >"$out" 2>/dev/null
}

# ctx_prefilter <cands.json> <task-file> <cap> <outfile>: when there are more than <cap> candidates,
# keep the <cap> with the most task-keyword overlap (regex fast path before Jev); else pass through.
ctx_prefilter() {
  jq --rawfile task "$2" --argjson cap "$3" '
    if length <= $cap then . else
      ($task | ascii_downcase | [scan("[a-z0-9_.-]{4,}")] | unique) as $kw
      | map(. + {score: (.text | ascii_downcase | . as $t | [$kw[] | select(. as $k | $t | contains($k))] | length)})
      | sort_by(-.score) | .[0:$cap] | map(del(.score)) end' "$1" >"$4" 2>/dev/null
}

# ctx_memory_index: path to the MEMORY.md index for this cwd (project-keyed), else the home
# project's, else "". Memory dirs live at ~/.claude/projects/<cwd-slug>/memory/.
ctx_memory_index() {
  local cwd slug home_slug p
  cwd="$(ctx_in .cwd)"
  [ -n "$cwd" ] || cwd="$PWD"
  slug="$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
  home_slug="$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')"
  for p in "${JEV_CLAUDE_DIR}/projects/${slug}/memory/MEMORY.md" "${JEV_CLAUDE_DIR}/projects/${home_slug}/memory/MEMORY.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 0
}

# ctx_bounded <seconds> <outfile> <cmd...>: run a command, kill it after N seconds. Returns its rc
# (143 on timeout). macOS has no timeout(1), so poll.
ctx_bounded() {
  local secs="$1" out="$2" pid ticks=0 max rc
  shift 2
  max=$((secs * 10))
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 143
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

# ---------------------------------------------------------------- chunk / trim engine
#
# Shared by A1 (Read), A2 (Grep/Glob) and A3 (Bash): split text into chunks, ask Jev one boolean
# per chunk ("does it hold what the task needs?"), keep the best chunks verbatim under a line
# budget, replace every gap with a marker, and cite the on-disk copy of the full text.

# ctx_extract <tool>: locate the text-bearing field of tool_response.
# Writes $WORK/carrier.json ({path, kind}) and $WORK/text.txt (array carriers joined by \n).
ctx_extract() {
  jq -c --arg tool "$1" '
    (.tool_response // .tool_output) as $r
    | if $tool == "Read" and (($r.file.content? // null) | type) == "string" then {path: ["file", "content"], kind: "string"}
      elif $tool == "Bash" and (($r.stdout? // null) | type) == "string" then {path: ["stdout"], kind: "string"}
      elif $tool == "Grep" and (($r.content? // null) | type) == "string" then {path: ["content"], kind: "string"}
      elif ($tool == "Grep" or $tool == "Glob") and (($r.filenames? // null) | type) == "array" then {path: ["filenames"], kind: "array"}
      else empty end' "$INPUT_FILE" >"${WORK}/carrier.json" 2>/dev/null || return 1
  [ -s "${WORK}/carrier.json" ] || return 1
  jq -j --slurpfile c "${WORK}/carrier.json" '
    (.tool_response // .tool_output) | getpath($c[0].path)
    | if type == "array" then map(tostring) | join("\n") else . end' "$INPUT_FILE" >"${WORK}/text.txt" 2>/dev/null || return 1
  return 0
}

# ctx_line_count <file>: number of lines (a trailing newline does not add one).
ctx_line_count() {
  awk 'END { print NR }' "$1"
}

# ctx_chunk <chunk_lines> <kind: text|log|hits> <task>: writes $WORK/chunks.json
#   {n, cs, chunks:[{i, s, e, digest}]}. Chunk size grows so there are never more than 24
#   chunks (keeps the Jev state well under the 32k-token cap). The digest is what Jev sees:
#   first 6 lines + up to 6 "interesting" lines (task keyword hits, or error-looking lines for logs).
ctx_chunk() {
  printf '%s' "$3" >"${WORK}/task.txt"
  jq -n --rawfile text "${WORK}/text.txt" --rawfile task "${WORK}/task.txt" \
    --argjson cs "$1" --arg kind "$2" '
    def stop: ["this","that","with","from","have","what","when","where","which","there","their","about","into","then","than","them","these","those","would","could","should","please","file","files","look","check","show","tell","does","need","want","make","some","more","also","just","like","been","will","your","here"];
    ($text | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end) as $L
    | ($L | length) as $n
    | (if $n > $cs * 24 then (($n / 24) | ceil) else $cs end) as $size
    | ($task | ascii_downcase | [scan("[a-z0-9_.-]{4,}")] | unique | map(select(. as $w | stop | index($w) | not)) | .[0:12]) as $kw
    | def short: if length > 140 then .[0:140] + "…" else . end;
      def interesting($line):
        if $kind == "log" then ($line | test("(?i)(error|fail|exception|traceback|panic|fatal|denied|cannot|✗|assert|timed? ?out)"))
        else ($kw | length > 0) and (($line | ascii_downcase) as $l | any($kw[]; . as $k | $l | contains($k)))
        end;
    {n: $n, cs: $size,
     chunks: [ range(0; $n; $size) as $o
       | ($L[$o:($o + $size)]) as $c
       | {i: ($o / $size | floor), s: ($o + 1), e: ($o + ($c | length)),
          digest: ( "lines \($o + 1)-\($o + ($c | length)):\n"
                    + (( $c[0:6] + [ $c[6:][] | select(interesting(.)) ][0:6] ) | map(short) | join("\n")) )} ] }
  ' >"${WORK}/chunks.json" 2>/dev/null
}

# ctx_build_request <rule> <state-json> <instructions> <timeout_ms> [extra-questions-json]
# -> $WORK/req.json. One boolean question "c<i>" per chunk; digests travel in `untrusted`
# (file/tool text is never trusted state). extra-questions are merged in verbatim.
ctx_build_request() {
  local extra="${5:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg rule "$1" --argjson state "$2" --arg ins "$3" --argjson t "$4" --argjson extra "$extra" \
    --slurpfile ch "${WORK}/chunks.json" '
    { rule: $rule, state: $state, timeout_ms: $t,
      untrusted: {chunks: ($ch[0].chunks | map({key: ("c\(.i)"), value: .digest}) | from_entries)},
      questions: ( ($ch[0].chunks | map({key: ("c\(.i)"),
          value: {type: "boolean",
                  instructions: ("Chunk c\(.i) is untrusted.chunks.c\(.i). " + $ins),
                  criteria: {true: "this chunk contains content the task needs", false: "this chunk is not needed for the task"}}})
          | from_entries) + $extra ) }' >"${WORK}/req.json" 2>/dev/null
}

# ctx_select <kind: read|log|hits> <budget> <min_p> <tail_keep> <min_saving> <cache_path>
#              <orig_path> <numbered: true|false> <tie: early|late> [best_fallback: true|false]
# best_fallback (default true): when no chunk reaches min_p, keep the single best chunk anyway. With
# false the text is left whole (reason "no-relevant-chunk"): a cut with nothing relevant to keep is blind.
# Reads $WORK/text.txt, chunks.json, jev-out.json. Writes $WORK/selection.json:
#   {trim:bool, reason, text, n, kept_lines, kept_ranges, trimmed_ranges, saved_chars, ps}
ctx_select() {
  jq -n --rawfile text "${WORK}/text.txt" --slurpfile ch "${WORK}/chunks.json" --slurpfile out "${WORK}/jev-out.json" \
    --arg kind "$1" --argjson budget "$2" --argjson minp "$3" --argjson tailk "$4" --argjson minsave "$5" \
    --arg cache "$6" --arg orig "$7" --argjson numbered "$8" --arg tie "$9" --argjson fb "${10:-true}" '
    ($text | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end) as $L
    | ($L | length) as $n
    | $ch[0].chunks as $chunks
    | ($out[0].answers // {}) as $ans
    | [ $chunks[] | . + {p: ($ans["c\(.i)"].probability // null)} ] as $sc
    | ($sc | map(select(.p != null)) | length) as $answered
    | if $answered == 0 then {trim: false, reason: "no chunk answers"} else
      # forced tail (logs): last tailk lines are always kept
      (if $tailk > 0 and $n > $tailk then [[($n - $tailk + 1), $n]] else [] end) as $forced
      | (($forced | map(.[1] - .[0] + 1) | add) // 0) as $forced_lines
      | ( $sc | map(select(.p != null))
          | sort_by([-.p, (if $tie == "late" then -.i else .i end)]) ) as $ranked
      | (reduce $ranked[] as $c ({kept: [], lines: $forced_lines};
            ($c.e - $c.s + 1) as $len
            | if ($c.p >= $minp) and (.lines + $len <= $budget)
              then {kept: (.kept + [$c]), lines: (.lines + $len)} else . end)) as $sel
      # always keep at least the single best chunk (unless best_fallback is off and none was relevant)
      | ($ranked | any(.p >= $minp)) as $relevant
      | if ($fb | not) and ($relevant | not) then {trim: false, reason: "no-relevant-chunk", n: $n} else
      (if ($sel.kept | length) == 0 and ($ranked | length) > 0
         then {kept: [$ranked[0]], lines: ($forced_lines + ($ranked[0].e - $ranked[0].s + 1))} else $sel end) as $sel2
      # merge kept ranges
      | ( ( [ $sel2.kept[] | [.s, .e] ] + $forced ) | sort_by(.[0])
          | reduce .[] as $r ([];
              if length > 0 and $r[0] <= (.[-1][1] + 1)
              then (.[:-1] + [[.[-1][0], ([.[-1][1], $r[1]] | max)]])
              else . + [$r] end) ) as $kept
      | ($kept | map(.[1] - .[0] + 1) | add // 0) as $kept_lines
      | if ($n - $kept_lines) < ($n * $minsave) then {trim: false, reason: "saving below min_saving", n: $n, kept_lines: $kept_lines}
        else
          # gaps between kept ranges
          ( ([[0, 0]] + $kept + [[($n + 1), ($n + 1)]]) as $b
            | [ range(0; ($b | length) - 1) as $k
                | [($b[$k][1] + 1), ($b[$k + 1][0] - 1)] | select(.[0] <= .[1]) ] ) as $gaps
          | def mark($g):
              ($g[1] - $g[0] + 1) as $c
              | if $kind == "read" then "[lines \($g[0])–\($g[1]) trimmed: re-read with offset=\($g[0]) limit=\($c)]"
                elif $kind == "log" then "[lines \($g[0])–\($g[1]) trimmed (\($c) lines): full output at \($cache) — Read it with offset=\($g[0]) limit=\($c)]"
                else "[hits \($g[0])–\($g[1]) trimmed (\($c) omitted): full list at \($cache)]" end;
            def body($r): [ range($r[0]; $r[1] + 1) as $k | (if $numbered then "\($k)\t\($L[$k - 1])" else $L[$k - 1] end) ];
            ( ([ $kept[] | {s: .[0], t: "k", r: .} ] + [ $gaps[] | {s: .[0], t: "g", r: .} ]) | sort_by(.s)
              | map(if .t == "k" then body(.r)[] else mark(.r) end) ) as $body
            | ( if $kind == "read"
                then "[jev-trim: showing \($kept_lines) of \($n) lines of \($orig) (original line numbers shown). Full file text also saved at \($cache)]"
                elif $kind == "log"
                then "[jev-trim: showing \($kept_lines) of \($n) output lines. Full output saved at \($cache)]"
                else "[jev-trim: showing \($kept_lines) of \($n) hits, ranked by relevance. Full list saved at \($cache)]" end ) as $head
            | (([$head] + $body) | join("\n")) as $new
            | {trim: true, reason: "ok", text: $new, n: $n, kept_lines: $kept_lines, kept_ranges: $kept, trimmed_ranges: $gaps,
               saved_chars: (($text | length) - ($new | length)),
               ps: ($sc | map({key: ("c\(.i)"), value: .p}) | from_entries)}
        end
      end
    end' >"${WORK}/selection.json" 2>/dev/null
}

# ctx_apply_trim <tool> <selection-file>: print the PostToolUse JSON that replaces tool_response's
# text field with the trimmed text. Read also gets numLines refreshed.
ctx_apply_trim() {
  jq -c --slurpfile sel "$2" --slurpfile c "${WORK}/carrier.json" --arg tool "$1" '
    (.tool_response // .tool_output) as $r
    | ($sel[0].text) as $t
    | ($c[0].path) as $p
    | ( if $c[0].kind == "array" then ($t | split("\n")) else $t end ) as $v
    | ($r | setpath($p; $v)) as $u
    | ( if $tool == "Read" and ($u.file.numLines? != null) then ($u | .file.numLines = ($t | split("\n") | length)) else $u end ) as $u2
    | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $u2}}' "$INPUT_FILE" 2>/dev/null
}

# ctx_trim_flow <tool> <kind> <chunk_lines> <task> <state-json> <instructions> <numbered> <tie> <orig> [extra-questions]
# The whole A1/A2/A3 pipeline after the caller's deterministic gates. Honors shadow vs enforce.
# Prints the hook output (enforce only). Returns silently when Jev is unavailable.
ctx_trim_flow() {
  local tool="$1" kind="$2" cl="$3" task="$4" state="$5" ins="$6" numbered="$7" tie="$8" orig="$9" extra="${10:-}"
  local n budget floor ceil frac tailk minsave cache="(not saved: shadow mode)" digest_kind dec=would-trim
  [ -n "$extra" ] || extra='{}'
  n="$(ctx_line_count "${WORK}/text.txt")"
  # Hard ceiling: jq passes over a giant payload would eat the hook timeout. Fail open instead.
  [ "$n" -le "$(ctx_cfg max_lines 20000)" ] || return 0
  digest_kind=text
  [ "$kind" = "log" ] && digest_kind=log
  ctx_chunk "$cl" "$digest_kind" "$task" || return 0
  ctx_build_request "$RULE" "$state" "$ins" 1500 "$extra" || return 0
  ctx_jev "${WORK}/req.json" || return 0

  floor="$(ctx_cfg budget_floor 200)"
  ceil="$(ctx_cfg budget_ceiling 600)"
  frac="$(ctx_cfg budget_frac 0.35)"
  tailk="$(ctx_cfg tail_lines 0)"
  minsave="$(ctx_cfg min_saving 0.2)"
  budget="$(jq -n --argjson n "$n" --argjson f "$floor" --argjson c "$ceil" --argjson fr "$frac" \
    '[([($n * $fr) | floor, $f] | max), $c] | min')"

  # Caller-supplied veto questions (e.g. A1 will_edit) are answered in the same call.
  if jq -e '.answers.will_edit.probability // 0 | . >= '"$(ctx_cfg will_edit_p 0.5)" "${WORK}/jev-out.json" >/dev/null 2>&1; then
    printf '{"decision":"keep-full","why":"will_edit","lines":%s}' "$n" >"${WORK}/detail.json"
    ctx_log "skip" "${WORK}/detail.json"
    return 0
  fi

  [ "$RULE_MODE" = "enforce" ] && { cache="$(ctx_cache_path "${WORK}/text.txt")" || return 0; }
  ctx_select "$kind" "$budget" "$RULE_THRESHOLD" "$tailk" "$minsave" "$cache" "$orig" "$numbered" "$tie" "$(ctx_cfg best_fallback true)" || return 0
  jq -e '.trim == true' "${WORK}/selection.json" >/dev/null 2>&1 || {
    jq -c '{decision:"keep-full", why:(.reason // "none"), lines:(.n // null)}' "${WORK}/selection.json" >"${WORK}/detail.json" 2>/dev/null
    ctx_log "skip" "${WORK}/detail.json"
    return 0
  }
  if [ "$RULE_MODE" = "enforce" ]; then
    # The markers cite the saved copy: if it cannot be written, leave the output untouched.
    ctx_cache_commit "${WORK}/text.txt" "$cache" || return 0
    dec=trimmed
  fi
  jq -c --arg tool "$tool" --arg cache "$cache" --arg dec "$dec" \
    '{decision:$dec, tool:$tool, lines:.n, kept_lines:.kept_lines, kept_ranges:.kept_ranges, trimmed_ranges:.trimmed_ranges, saved_chars:.saved_chars, p:.ps, cache:$cache}' \
    "${WORK}/selection.json" >"${WORK}/detail.json" 2>/dev/null
  ctx_log "trim" "${WORK}/detail.json"
  [ "$RULE_MODE" = "enforce" ] || return 0
  ctx_apply_trim "$tool" "${WORK}/selection.json"
}
