#!/usr/bin/env bash
# Enforce the CLAUDE.md file-organization rule: temporary artefacts belong in
# .tmp/, never in the repo root or source directories.
#
# The rule predates this test by a long way. Until now it was enforced by
# whoever happened to notice a stray report in a diff, which is the definition
# of a manual check worth automating.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

exec python3 scripts/check-file-org.py
