#!/usr/bin/env bash
# Real tmux owner lifecycle with a deterministic transport (live transport is
# verified separately by the opt-in Codex native queue test).
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-watch)
mkdir -p "$TMP_ROOT/code" "$TMP_ROOT/home/state"
cp -a "$ROOT/bin" "$TMP_ROOT/code/bin"
cat > "$TMP_ROOT/code/bin/fm-codex-notify.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --validate ]; then exit 0; fi
[ ! -e "$FM_HOME/state/fail-notify" ] || exit 1
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_HOME/state/receipts"
SH
cat > "$TMP_ROOT/code/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/fm-wake-lib.sh"
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$0" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
trap 'rm -rf "$STATE/.watch.lock"' EXIT
trap 'exit 143' TERM
while :; do
  if [ -e "$STATE/stall" ]; then
    touch "$STATE/stalled"
  else
    touch "$STATE/.last-watcher-beat"
    [ ! -s "$STATE/.wake-queue" ] || break
  fi
  sleep 0.1
done
echo 'signal: deterministic queue'
SH
chmod +x "$TMP_ROOT/code/bin/fm-codex-notify.sh" "$TMP_ROOT/code/bin/fm-watch.sh"
export FM_HOME="$TMP_ROOT/home"
OWNER="$TMP_ROOT/code/bin/fm-codex-watch.sh"
THREAD=01a081bc-dabb-7e81-b7de-0d4fbaa60aa6
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
cleanup_test() { "$OWNER" stop >/dev/null 2>&1 || true; fm_test_cleanup; }
trap cleanup_test EXIT
"$OWNER" start "$THREAD" "$$"
first=$(cat "$FM_HOME/state/.codex-watch-owner")
"$OWNER" start "$THREAD" "$$"
[ "$first" = "$(cat "$FM_HOME/state/.codex-watch-owner")" ] || fail 'duplicate start changed identity'
sleep 11
"$OWNER" status
touch "$FM_HOME/state/stall"
for _ in {1..50}; do [ -e "$FM_HOME/state/stalled" ] && break; sleep 0.1; done
[ -e "$FM_HOME/state/stalled" ] || fail 'watcher did not stall'
touch -t 200001010000 "$FM_HOME/state/.last-watcher-beat"
watcher_pid=$(cat "$FM_HOME/state/.watch.lock/pid")
kill -0 "$watcher_pid" || fail 'stalled watcher exited'
if "$OWNER" status; then fail 'stale live watcher remained healthy'; fi
for _ in {1..150}; do [ -s "$FM_HOME/state/.codex-watch-failure" ] && break; sleep 0.1; done
[ -s "$FM_HOME/state/.codex-watch-failure" ] || fail 'owner kept stalled cycle alive'
"$OWNER" stop
rm -f "$FM_HOME/state/stall" "$FM_HOME/state/stalled"
: > "$FM_HOME/state/.wake-queue"
rm -f "$FM_HOME/state/receipts"
"$OWNER" start "$THREAD" "$$"
touch "$FM_HOME/state/.afk"
sleep 2
if "$OWNER" status; then fail 'away owner without daemon remained healthy'; fi
mkdir -p "$FM_HOME/state/.supervise-daemon.lock"
printf '0\n' > "$FM_HOME/state/.supervise-daemon.lock/pid"
printf 'dead\n' > "$FM_HOME/state/.supervise-daemon.lock/pid-identity"
if "$OWNER" status; then fail 'away owner with failed daemon remained healthy'; fi
printf '1\t1\tsignal\tone\tsignal: one\n' > "$FM_HOME/state/.wake-queue"
sleep 2
[ ! -e "$FM_HOME/state/receipts" ] || fail 'normal owner delivered during away mode'
rm -f "$FM_HOME/state/.afk"
for _ in {1..50}; do [ -s "$FM_HOME/state/receipts" ] && break; sleep 0.1; done
[ "$(wc -l < "$FM_HOME/state/receipts")" = 1 ] || fail 'initial receipt missing'
sleep 11
touch -t 200001010000 "$FM_HOME/state/.last-watcher-beat"
[ ! -e "$FM_HOME/state/.watch.lock" ] || fail 'pending handoff retained watcher'
"$OWNER" status
[ "$(wc -l < "$FM_HOME/state/receipts")" = 1 ] || fail 'pending wake repeated'
IFS=$'\t' read -r _ _ _ crashed_session _ < "$FM_HOME/state/.codex-watch-owner"
tmux kill-session -t "$crashed_session"
sleep 1
[ -s "$FM_HOME/state/.wake-queue" ] || fail 'owner crash acknowledged wake'
"$OWNER" start "$THREAD" "$$"
sleep 2
[ "$(wc -l < "$FM_HOME/state/receipts")" = 1 ] || fail 'restart repeated pending receipt'
: > "$FM_HOME/state/.wake-queue"
sleep 2
printf '2\t2\tsignal\ttwo\tsignal: two\n' > "$FM_HOME/state/.wake-queue"
for _ in {1..50}; do [ "$(wc -l < "$FM_HOME/state/receipts")" = 2 ] && break; sleep 0.1; done
[ "$(wc -l < "$FM_HOME/state/receipts")" = 2 ] || fail 'second cycle did not deliver'
"$OWNER" stop
[ -s "$FM_HOME/state/.wake-queue" ] || fail 'stop acknowledged wake'
"$OWNER" start "$THREAD" "$$"
: > "$FM_HOME/state/.wake-queue"
sleep 2
touch "$FM_HOME/state/fail-notify"
printf '3\t3\tsignal\tthree\tsignal: three\n' > "$FM_HOME/state/.wake-queue"
for _ in {1..50}; do [ -s "$FM_HOME/state/.codex-watch-failure" ] && break; sleep 0.1; done
sleep 1
if "$OWNER" status; then fail 'failed native delivery remained healthy'; fi
if "$OWNER" start "$THREAD" "$$"; then fail 'restart erased failed delivery'; fi
failed_binding=$(cat "$FM_HOME/state/.codex-watch-owner")
"$OWNER" stop
[ "$failed_binding" = "$(cat "$FM_HOME/state/.codex-watch-owner")" ] || fail 'stop lost pending binding'
if "$OWNER" start "$THREAD" "$$"; then fail 'stop bypassed explicit retry'; fi
rm -f "$FM_HOME/state/fail-notify"
printf '0\n' > "$FM_HOME/state/.lock"
if "$OWNER" retry; then fail 'retry accepted changed home owner'; fi
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$OWNER" retry
[ "$(tail -n 1 "$FM_HOME/state/receipts")" = "$(printf '%s\t%s\t%s' "$THREAD" "$$" "$FM_HOME")" ] || fail 'retry changed transport binding'
if "$OWNER" start 01a081bc-dabb-7e81-b7de-0d4fbaa60aa7 "$$"; then fail 'pending delivery rebound to another thread'; fi
"$OWNER" start "$THREAD" "$$"
[ "$(wc -l < "$FM_HOME/state/receipts")" = 3 ] || fail 'explicit retry did not deliver once'
[ ! -e "$FM_HOME/state/.afk" ] || fail 'owner enabled away mode'
printf '0\n' > "$FM_HOME/state/.lock"
sleep 2
if "$OWNER" status; then fail 'changed session lock remained healthy'; fi
pass 'Codex owner singleton, pending preservation, restart, rearm, and parent binding'
