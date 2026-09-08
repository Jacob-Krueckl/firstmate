#!/usr/bin/env bash
# Negative controls use real processes. Positive binding and delivery require
# the real TUI in fm-codex-continuity-live-e2e.test.sh.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NOTIFY="$ROOT/bin/fm-codex-notify.sh"
thread=11111111-1111-1111-1111-111111111111
for mode in validate notify; do
  args=()
  [ "$mode" != validate ] || args+=(--validate)
  code=0
  "$NOTIFY" "${args[@]}" "$thread" "$$" >/dev/null 2>&1 || code=$?
  [ "$code" -ne 0 ] || fail "ordinary shell accepted as Codex ($mode)"
  code=0
  "$NOTIFY" "${args[@]}" invalid "$$" >/dev/null 2>&1 || code=$?
  [ "$code" -ne 0 ] || fail "malformed thread accepted ($mode)"
  code=0
  "$NOTIFY" "${args[@]}" "$thread" invalid >/dev/null 2>&1 || code=$?
  [ "$code" -ne 0 ] || fail "malformed process accepted ($mode)"
done
pass 'callback refuses non-Codex live process and malformed thread/process before queueing'
