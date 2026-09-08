#!/usr/bin/env bash
# Native hook registration owns event identity independently of inherited markers.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-routing)
lab="$TMP_ROOT/native-root"
mkdir -p "$lab/bin" "$lab/.codex"
printf '# Firstmate\n' > "$lab/AGENTS.md"
cp "$ROOT/.codex/hooks.json" "$lab/.codex/hooks.json"
for helper in fm-sessionstart-run fm-arm-pretool-check fm-cd-pretool-check fm-turnend-guard; do
  cat > "$lab/bin/$helper.sh" <<'HELPER'
#!/usr/bin/env bash
cat >/dev/null
"$FM_ROUTING_TEST_ROOT/bin/fm-harness.sh"
HELPER
  chmod +x "$lab/bin/$helper.sh"
done
# Execute the native registration as Codex does: project PWD and JSON stdin.
# This portable test does not claim to prove vendor hook delivery.
while IFS= read -r command; do
  out=$(cd "$lab" && printf '{"cwd":"%s"}\n' "$lab" |
    FM_ROUTING_TEST_ROOT="$ROOT" GROK_AGENT=1 CLAUDECODE=1 CURSOR_AGENT=1 \
    bash -c "$command")
  [ "$out" = codex ] || fail "native Codex hook inherited the wrong host: $out"
done < <(jq -r '.hooks[][] .hooks[].command' "$lab/.codex/hooks.json")
pass "all native Codex hook helpers bind event identity despite foreign markers"
for spec in 'GROK_AGENT=1:grok' 'CLAUDECODE=1:claude' 'CURSOR_AGENT=1:cursor' 'PI_CODING_AGENT=true:pi'; do
  marker=${spec%:*}
  expected=${spec#*:}
  out=$(env -u FM_HOOK_HARNESS -u GROK_AGENT -u CLAUDECODE -u CURSOR_AGENT \
    -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS "$marker" "$ROOT/bin/fm-harness.sh")
  [ "$out" = "$expected" ] || fail "ordinary $expected marker changed: $out"
done
out=$(FM_HOOK_HARNESS=invalid GROK_AGENT=1 env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE -u PI_CODING_AGENT "$ROOT/bin/fm-harness.sh")
[ "$out" = grok ] || fail "unknown hook binding overrode verified detection: $out"
pass "ordinary harness marker precedence and unknown binding fallback remain unchanged"
