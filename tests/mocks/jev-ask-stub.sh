#!/bin/bash
# Test double for the Jev client contract (system-configs/.claude/hooks/jev/jev-ask).
# Mirrors the documented JEV_MOCK semantics: JEV_MOCK=<fixture.json> prints that file and exits 0;
# JEV_MOCK=unavailable (or unset / missing fixture) exits 3. Test-only extra: when JEV_STUB_LOG is set,
# each request (one compact JSON line) is appended to it so tests can count calls and inspect payloads.
if [ -n "${JEV_STUB_LOG:-}" ]; then
  cat >>"${JEV_STUB_LOG}"
  echo >>"${JEV_STUB_LOG}"
else
  cat >/dev/null
fi
case "${JEV_MOCK:-}" in
  unavailable | "") exit 3 ;;
esac
[ -f "${JEV_MOCK}" ] || exit 3
cat "${JEV_MOCK}"
