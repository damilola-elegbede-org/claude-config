#!/bin/bash
# Test double for the Jev client contract (system-configs/.claude/hooks/jev/jev-ask).
# Mirrors the documented JEV_MOCK semantics: JEV_MOCK=<fixture.json> prints that file and exits 0;
# JEV_MOCK=unavailable (or unset / missing fixture) exits 3. Test-only extra: when JEV_STUB_LOG is set,
# each request (one compact JSON line) is appended to it so tests can count calls and inspect payloads.
#
# Like the real client's validate() (client.mjs), a malformed request exits 2 BEFORE the mock answer is
# returned: rule id ^[\w.:/-]{1,80}$, state an object without an "untrusted" key, questions a non-empty
# object whose entries have type boolean|choice|score and a non-empty instructions string. Without this a
# hook could send a request the real client rejects and every test would still pass.
REQ=$(cat)
if [ -n "${JEV_STUB_LOG:-}" ]; then
  printf '%s\n' "$REQ" >>"${JEV_STUB_LOG}"
fi
printf '%s' "$REQ" | jq -e '
  (.rule | type == "string" and test("^[A-Za-z0-9_.:/-]{1,80}$"))
  and (.state | type == "object" and (has("untrusted") | not))
  and (.questions | type == "object" and length > 0
       and all(.[]; type == "object" and (.type | IN("boolean", "choice", "score"))
                    and (.instructions | type == "string" and length > 0)))
  and ((.timeout_ms // 1000) | type == "number" and . >= 50 and . <= 60000)' >/dev/null 2>&1 || {
  echo "jev-ask-stub: bad input" >&2
  exit 2
}
case "${JEV_MOCK:-}" in
  unavailable | "") exit 3 ;;
esac
[ -f "${JEV_MOCK}" ] || exit 3
cat "${JEV_MOCK}"
