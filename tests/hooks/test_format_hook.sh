#!/usr/bin/env bash
# PostToolUse Write|Edit formatter: prettier may only rewrite files that were
# already prettier-clean in HEAD, the only baseline it can trust.
#
# Before this guard the hook ran `prettier --write` on every edited file, so a
# one-line Edit in a repo that ships prettier but never ran it rewrote the
# whole file (papercuts 2026-09-30, 2026-10-04, 2026-10-14).
#
# Hermetic: runs the real hook command from settings.json against fixture git
# repos whose node_modules/.bin/prettier is a stub. The stub's --check fails on
# input containing UNFORMATTED; its --write appends a STUB-FORMATTED marker.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$REPO_ROOT/system-configs/.claude/settings.json"

for tool in jq git npx; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [[ -n "${CI:-}" ]]; then
      echo "FAIL: $tool is required" >&2
      exit 1
    fi
    echo "SKIP: $tool missing" >&2
    exit 0
  fi
done

HOOK="$(jq -r '.hooks.PostToolUse[] | select(.matcher | split("|") | index("Edit")) | .hooks[].command | select(contains("prettier"))' "$SETTINGS")"
if [[ -z "$HOOK" ]]; then
  echo "FAIL: no PostToolUse Edit hook running prettier in settings.json" >&2
  exit 1
fi

T="$(mktemp -d /tmp/format-hook-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

# A repo with a stub prettier and two committed files: one clean, one not.
REPO="$T/repo"
mkdir -p "$REPO/node_modules/.bin" "$REPO/docs"
cat >"$REPO/node_modules/.bin/prettier" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --check) ! grep -q UNFORMATTED ;;
  --write) printf 'STUB-FORMATTED\n' >>"$2" ;;
esac
STUB
chmod +x "$REPO/node_modules/.bin/prettier"
printf '{"name":"fixture","private":true}\n' >"$REPO/package.json"
printf 'node_modules/\n' >"$REPO/.gitignore"
printf '# clean\n' >"$REPO/clean.md"
printf '# UNFORMATTED\n' >"$REPO/messy.md"
printf '# nested clean\n' >"$REPO/docs/nested.md"
git -C "$REPO" init -q
git -C "$REPO" add .gitignore package.json clean.md messy.md docs/nested.md
# Isolate the fixture commit from the developer's signing and hook setup: a
# failed commit leaves no HEAD and every case below would test the wrong thing.
if ! git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgSign=false \
  -c core.hooksPath=/dev/null commit -qm fixture; then
  echo "FAIL: could not create the fixture commit" >&2
  exit 1
fi

# Outside any git repo: no baseline to compare against.
LOOSE="$T/loose"
mkdir -p "$LOOSE/node_modules/.bin"
cp "$REPO/node_modules/.bin/prettier" "$LOOSE/node_modules/.bin/prettier"
printf '{"name":"loose","private":true}\n' >"$LOOSE/package.json"
printf '# loose\n' >"$LOOSE/loose.md"

run_hook() { # cwd file
  local payload
  payload="$(jq -cn --arg f "$2" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
  (cd "$1" && printf '%s' "$payload" | bash -c "$HOOK") >/dev/null 2>&1
}
formatted() { grep -q STUB-FORMATTED "$1"; }
expect_formatted() {
  run_hook "$1" "$2"
  formatted "$2" && ok || bad "$3: expected prettier --write"
}
expect_untouched() {
  local before
  before="$(cat "$2")"
  run_hook "$1" "$2"
  [[ "$(cat "$2")" == "$before" ]] && ok || bad "$3: expected file left as edited"
}

printf 'edited line\n' >>"$REPO/clean.md"
expect_formatted "$REPO" "$REPO/clean.md" "clean tracked file"

printf 'edited line\n' >>"$REPO/messy.md"
expect_untouched "$REPO" "$REPO/messy.md" "never-formatted tracked file"

printf 'edited line\n' >>"$REPO/docs/nested.md"
expect_formatted "$REPO" "$REPO/docs/nested.md" "clean tracked file in a subdirectory"

# No HEAD version means no baseline: a new file and a moved never-formatted
# file look the same, so neither is rewritten.
printf '# brand new\n' >"$REPO/docs/new.md"
expect_untouched "$REPO" "$REPO/docs/new.md" "new untracked file in a repo"

git -C "$REPO" mv messy.md docs/moved.md
printf 'edited after move\n' >>"$REPO/docs/moved.md"
expect_untouched "$REPO" "$REPO/docs/moved.md" "renamed never-formatted file"

printf 'edited line\n' >>"$LOOSE/loose.md"
expect_untouched "$LOOSE" "$LOOSE/loose.md" "file outside any git repo"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
