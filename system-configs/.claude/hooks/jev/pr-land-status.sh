#!/bin/bash
# pr-land-status.sh — the ONE definition of "this PR is done": GitHub would let D click Merge.
# Shared by the pr-landing-gate Stop hook and the /land skill so they can never disagree.
#
#   pr-land-status.sh <pr-url>                       one JSON verdict on stdout
#   pr-land-status.sh <pr-url> --wait <secs>         re-poll every 30s while the verdict is "pending"
#   pr-land-status.sh <pr-url> --bounded-out "<why>" record that /land gave up on the CURRENT head
#
# Verdicts: ready | merged | closed | pending | blocked | error. Exit 0 for ready/merged/closed,
# 1 for pending/blocked, 2 for error (gh missing, unauthenticated, network) — callers fail open on 2.
#
# Not ready when ANY of: draft; conflicts (DIRTY) or behind base (BEHIND); a check still running or
# failed (checks are read directly: repos without required checks report red CI as UNSTABLE, which
# GitHub lets you merge); an unresolved review thread; CHANGES_REQUESTED; a review bot that is active
# on this repo has not answered the current head yet (bounded by review_grace_min); or BLOCKED for a
# reason none of those explain (e.g. a required human approval: needs_human).
#
# Config (rules.d/rules-events.json "pr-landing-gate"): review_bots, review_grace_min.
# Test seams: PR_LAND_GH (gh binary), PR_LAND_NOW (epoch seconds).
# shellcheck shell=bash
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rules-events-lib.sh
. "$HERE/rules-events-lib.sh" 2>/dev/null || true

GH="${PR_LAND_GH:-gh}"
BOUNDED_DIR="${RE_STATE_DIR:-$HOME/.claude/jev/state}/landing-bounded"

err() { jq -nc --arg u "${URL:-}" --arg d "$1" '{url:$u, verdict:"error", detail:$d}'; exit 2; }

URL="${1:-}"
[ -n "$URL" ] || {
  echo "usage: pr-land-status.sh <pr-url> [--wait <secs> | --bounded-out <reason>]" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo '{"verdict":"error","detail":"jq missing"}'
  exit 2
}
if ! printf '%s' "$URL" | grep -qE '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$'; then err "not a GitHub PR URL"; fi
OWNER=$(printf '%s' "$URL" | cut -d/ -f4)
NAME=$(printf '%s' "$URL" | cut -d/ -f5)
NUM=$(printf '%s' "$URL" | cut -d/ -f7)
KEY=$(printf '%s' "$URL" | tr -c 'A-Za-z0-9' '_')

cfg() { if command -v re_cfg >/dev/null 2>&1; then re_cfg pr-landing-gate "$1" "$2"; else printf '%s' "$2"; fi; }
BOTS=$(cfg review_bots '["coderabbitai","chatgpt-codex-connector"]')
printf '%s' "$BOTS" | jq -e 'type == "array"' >/dev/null 2>&1 || BOTS='["coderabbitai","chatgpt-codex-connector"]'
GRACE=$(cfg review_grace_min 15)
case "$GRACE" in '' | *[!0-9]*) GRACE=15 ;; esac

# shellcheck disable=SC2016 # GraphQL variables, not shell
QUERY='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){
  pullRequest(number:$num){state isDraft mergeable mergeStateStatus reviewDecision headRefOid
    commits(last:1){nodes{commit{oid committedDate statusCheckRollup{state contexts(first:100){nodes{
      __typename ... on CheckRun{name status conclusion} ... on StatusContext{context state}}}}}}}
    reviewThreads(first:100){nodes{isResolved}}
    reviews(last:50){nodes{author{login} commit{oid} submittedAt}}
    comments(last:50){nodes{author{login} createdAt body}}}
  pullRequests(last:10,states:[OPEN,MERGED]){nodes{
    reviews(last:20){nodes{author{login}}} comments(last:20){nodes{author{login}}}}}}}'

status_once() {
  local raw now
  raw=$("$GH" api graphql -f query="$QUERY" -F o="$OWNER" -F n="$NAME" -F num="$NUM" 2>&1) || err "gh api failed: ${raw:0:200}"
  printf '%s' "$raw" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1 || err "no PR data: ${raw:0:200}"
  now="${PR_LAND_NOW:-$(date +%s)}"
  printf '%s' "$raw" | jq -c --arg url "$URL" --argjson bots "$BOTS" --argjson grace "$GRACE" --argjson now "$now" '
    .data.repository as $r | $r.pullRequest as $p
    | ($p.commits.nodes[0].commit) as $head
    | ([$head.statusCheckRollup.contexts.nodes[]?
        | if .__typename == "CheckRun" then {name, run: (.status != "COMPLETED"),
              bad: ((.conclusion // "") | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","STALE"))}
          else {name: .context, run: (.state | IN("PENDING","EXPECTED")), bad: (.state | IN("FAILURE","ERROR"))} end]) as $checks
    # The rollup state aggregates every context, including any past the first 100 listed above.
    | ($head.statusCheckRollup.state // "") as $rollup
    | ([$p.reviewThreads.nodes[] | select(.isResolved | not)] | length) as $threads
    | ([$r.pullRequests.nodes[] | (.reviews.nodes[], .comments.nodes[]) | .author.login // empty]
       + [$p.reviews.nodes[], $p.comments.nodes[] | .author.login // empty] | unique) as $seen
    | ($head.committedDate | fromdateiso8601) as $headt
    | ([$bots[] as $b | select($seen | index($b))
        | select(([$p.reviews.nodes[] | select(.author.login == $b and .commit.oid == $p.headRefOid)] | length) == 0
             and ([$p.comments.nodes[] | select(.author.login == $b and ((.createdAt | fromdateiso8601) >= $headt))
                   # a "review running" status comment is not an answer (Codex posts one when it starts)
                   | select((.body // "") | test("\"status\":\"running\"|🔄|review in progress|currently processing"; "i") | not)] | length) == 0)
        | $b]) as $silent
    | (($now - $headt) < ($grace * 60)) as $in_grace
    | ([ if $p.isDraft then {kind:"draft", fix:"gh pr ready"} else empty end,
         if $p.mergeStateStatus == "DIRTY" or $p.mergeable == "CONFLICTING" then {kind:"conflicts", fix:"/rebase, then /push"} else empty end,
         if $p.mergeStateStatus == "BEHIND" then {kind:"behind-base", fix:"/rebase, then /push"} else empty end,
         ($checks | map(select(.bad)) | if length > 0 then {kind:"failing-checks", detail:(map(.name) | join(", ")), fix:"/fix-ci"}
            elif ($rollup | IN("FAILURE","ERROR")) then {kind:"failing-checks", detail:"rollup \($rollup) (a check past the first 100)", fix:"/fix-ci"}
            else empty end),
         if $threads > 0 then {kind:"unresolved-threads", detail:"\($threads) unresolved", fix:"/resolve-comments"} else empty end,
         if $p.reviewDecision == "CHANGES_REQUESTED" then {kind:"changes-requested", fix:"/resolve-comments"} else empty end
       ]) as $blockers
    | ([ ($checks | map(select(.run)) | if length > 0 then {kind:"checks-running", detail:(map(.name) | join(", "))}
            elif ($rollup | IN("PENDING","EXPECTED")) then {kind:"checks-running", detail:"rollup \($rollup)"}
            else empty end),
         # Right after a push CI may not have registered yet: no checks is not the same as green.
         if ($checks | length) == 0 and $in_grace then {kind:"checks-not-started"} else empty end,
         if $p.mergeStateStatus == "UNKNOWN" then {kind:"mergeability-computing"} else empty end,
         if ($silent | length) > 0 and $in_grace then {kind:"awaiting-review", detail:($silent | join(", "))} else empty end
       ]) as $pending
    | {url:$url, state:$p.state, head:$p.headRefOid, mergeStateStatus:$p.mergeStateStatus,
       unresolved_threads:$threads, blockers:$blockers, pending:$pending,
       notes:(if ($silent | length) > 0 and ($in_grace | not) then ["no review from \($silent | join(", ")) on this head after \($grace) min; not waiting longer"] else [] end)}
    | .verdict = (if $p.state == "MERGED" then "merged" elif $p.state == "CLOSED" then "closed"
                  elif ($blockers | length) > 0 then "blocked"
                  elif ($pending | length) > 0 then "pending"
                  elif $p.mergeStateStatus == "BLOCKED" then "blocked"
                  else "ready" end)
    | if .verdict == "blocked" and ($blockers | length) == 0 then
        .blockers = [{kind:"blocked-other", detail:"GitHub reports BLOCKED with checks green and threads resolved: likely a required human approval", fix:"needs D"}]
        | .needs_human = true else . end'
}

if [ "${2:-}" = "--bounded-out" ]; then
  out=$(status_once)
  [ $? -eq 2 ] && {
    printf '%s\n' "$out"
    exit 2
  }
  mkdir -p "$BOUNDED_DIR" || err "cannot write $BOUNDED_DIR"
  # Write then rename, so the Stop hook never reads a partial record.
  tmp="$BOUNDED_DIR/.$KEY.json.$$"
  printf '%s' "$out" | jq -c --arg why "${3:-unspecified}" --arg ts "$(date -u +%FT%TZ)" \
    '{url, head, reason:$why, ts:$ts, blockers}' >"$tmp" && mv -f "$tmp" "$BOUNDED_DIR/$KEY.json" || {
    rm -f "$tmp"
    err "cannot record bounded-out in $BOUNDED_DIR"
  }
  jq -c '. + {recorded:"bounded-out"}' "$BOUNDED_DIR/$KEY.json"
  exit 1
fi

deadline=0
if [ "${2:-}" = "--wait" ]; then
  case "${3:-}" in '' | *[!0-9]*) deadline=0 ;; *) deadline=$(($(date +%s) + $3)) ;; esac
fi
while :; do
  out=$(status_once)
  rc=$?
  [ "$rc" -eq 2 ] && {
    printf '%s\n' "$out"
    exit 2
  }
  v=$(printf '%s' "$out" | jq -r .verdict)
  if [ "$v" != pending ] || [ "$(date +%s)" -ge "$deadline" ]; then break; fi
  sleep 30
done
printf '%s\n' "$out"
case "$v" in ready | merged | closed) exit 0 ;; *) exit 1 ;; esac
