#!/usr/bin/env bash
# Normal Codex supervision owner, retained interactive TUI only.
# Usage: FM_HOME=/canonical/home fm-codex-watch.sh start THREAD PID
#        FM_HOME=/canonical/home fm-codex-watch.sh status|stop|retry
# The explicit PID must own state/.lock and the transport validates its TUI.
# A dedicated exact tmux session owns run and its watcher child. No away flag
# is created. Pending notification is retained until its durable queue cutoff
# disappears through the primary's normal acknowledgement. Receipt is not ack.
# start is idempotent for an identical live binding; mismatches fail closed.
# A dead owner can be restarted with start; an ambiguous terminal is preserved.
# status exits nonzero for stopped/failed ownership. stop closes only the
# recorded identity-matched terminal. run is an internal authenticated entry.
# state/.codex-watch-owner is one TSV: thread, PID, kernel identity, session,
# token. .codex-watch-ready repeats the token; .codex-watch-beat must be less
# than 15 seconds old. .codex-watch-pending is the notified maximum sequence;
# it survives restart, and after 900 seconds .codex-watch-overdue reports delay.
# .codex-watch-failure refuses automatic restart when delivery is failed or
# indeterminate. retry deliberately resubmits one native reminder, preserving
# queue rows. .codex-watch-cycle contains the latest arm output.
# While .afk exists the owner cancels its arm child and yields to away mode.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] || { echo 'codex watcher: FM_HOME must be explicit' >&2; exit 2; }
FM_HOME=$(cd "$FM_HOME" && pwd -P) || exit 2
export FM_HOME
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
RECORD="$STATE/.codex-watch-owner"
LOCK="$STATE/.codex-watch-control"
PENDING="$STATE/.codex-watch-pending"
FAILURE="$STATE/.codex-watch-failure"
child=
fail() { printf 'codex watcher: FAILED - %s\n' "$*" >&2; return 1; }
read_record() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS=$'\t' read -r thread parent identity session token < "$RECORD" || return 1
  [[ "$thread" =~ ^[a-f0-9-]{36}$ && "$parent" =~ ^[0-9]+$ && "$session" =~ ^fm-codex-watch-[0-9-]+$ && "$token" =~ ^[0-9-]+$ ]] || return 1
  [ -n "$identity" ]
}
parent_alive() {
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$parent" ] &&
    [ "$(fm_pid_identity "$parent" 2>/dev/null)" = "$identity" ]
}
terminal_matches() {
  [ "$(tmux display-message -p -t "$session" '#{session_name}' 2>/dev/null)" = "$session" ] &&
  [ "$(tmux show-options -qv -t "$session" @fm_codex_watch_token 2>/dev/null)" = "$token" ]
}
terminal_alive() {
  terminal_matches &&
    [ "$(tmux display-message -p -t "$session" '#{pane_dead}' 2>/dev/null)" = 0 ]
}
active_cycle_healthy() {
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}" "$FM_HOME" ||
    [ "$(fm_path_age "$STATE/.codex-watch-arm-start")" -lt 10 ]
}
healthy() {
  [ ! -e "$STATE/.afk" ] && parent_alive && terminal_alive &&
    [ "$(cat "$STATE/.codex-watch-ready" 2>/dev/null)" = "$token" ] &&
    [ "$(fm_path_age "$STATE/.codex-watch-beat")" -lt 15 ] &&
    [ ! -s "$FAILURE" ] || return 1
  if [ -s "$PENDING" ]; then
    local pending_cutoff
    read -r pending_cutoff < "$PENDING"
    [[ "$pending_cutoff" =~ ^[0-9]+$ ]] && return 0
    return 1
  fi
  active_cycle_healthy
}
control_lock() {
  local attempt
  for attempt in {1..100}; do
    [ "$attempt" -gt 0 ] || return 1
    fm_lock_try_acquire "$LOCK" && return 0; sleep 0.05; done
  fail 'control lock unavailable'
}
cleanup() {
  trap "" HUP INT TERM
  if [ -n "$child" ]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
}
snapshot_tree() {
  local pid=$1 ident descendant
  ident=$(fm_pid_identity "$pid" 2>/dev/null) || return 0
  owned_pids+=("$pid")
  owned_identities+=("$ident")
  while read -r descendant; do
    [ -n "$descendant" ] || continue
    snapshot_tree "$descendant"
  done < <(ps -eo pid=,ppid= | awk -v parent="$pid" '$2 == parent {print $1}')
}
stop_terminal() {
  local pane pane_identity i attempt alive
  local -a owned_pids=() owned_identities=()
  pane=$(tmux display-message -p -t "$session" '#{pane_pid}') || return 1
  snapshot_tree "$pane"
  pane_identity=$(fm_pid_identity "$pane" 2>/dev/null) || pane_identity=
  terminal_matches || return 1
  if [ -n "$pane_identity" ] && [ "${owned_identities[0]:-}" = "$pane_identity" ]; then
    kill -TERM "$pane" 2>/dev/null || true
  fi
  for attempt in {1..200}; do
    alive=0
    for ((i=${#owned_pids[@]}-1; i>=0; i--)); do
      if [ "$(fm_pid_identity "${owned_pids[i]}" 2>/dev/null)" = "${owned_identities[i]}" ]; then
        alive=1
        if [ "$attempt" -eq 100 ]; then
          kill -TERM "${owned_pids[i]}" 2>/dev/null || true
        fi
      fi
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
  done
  [ "$alive" -eq 0 ] || { fail 'owned processes did not stop; preserving terminal'; return 1; }
  if tmux has-session -t "$session" 2>/dev/null; then
    terminal_matches && tmux kill-session -t "$session"
  fi
  return 0
}
queue_cutoff() { awk -F '\t' '$2+0 > n { n=$2+0 } END { print n+0 }' "$STATE/.wake-queue" 2>/dev/null; }
pending_remains() {
  local cutoff=$1
  awk -F '\t' -v n="$cutoff" '$2+0 <= n && NF >= 5 { found=1 } END { exit !found }' "$STATE/.wake-queue" 2>/dev/null
}
run_owner() {
  if ! read_record || [ "$token" != "${1:-}" ] || ! terminal_alive || ! parent_alive; then
    fail 'invalid owner binding'; return 1
  fi
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  printf '%s\n' "$token" > "$STATE/.codex-watch-ready"
  local cutoff arm_rc age away_interrupted unhealthy_since now
  while parent_alive; do
    touch "$STATE/.codex-watch-beat"
    if [ -e "$STATE/.afk" ]; then sleep 1; continue; fi
    if [ -s "$PENDING" ]; then
      read -r cutoff < "$PENDING"
      [[ "$cutoff" =~ ^[0-9]+$ ]] || { fail 'malformed pending cutoff'; return 1; }
      if pending_remains "$cutoff"; then
        age=$(fm_path_age "$PENDING")
        if [ "$age" -gt 900 ]; then
          printf 'native wake remains unacknowledged after %ss; inspect the primary and durable queue\n' "$age" > "$STATE/.codex-watch-overdue"
        fi
        sleep 1; continue
      fi
      rm -f "$PENDING" "$STATE/.codex-watch-overdue"
    fi
    touch "$STATE/.codex-watch-arm-start"
    "$SCRIPT_DIR/fm-watch-arm.sh" > "$STATE/.codex-watch-cycle" 2>&1 &
    child=$!
    away_interrupted=0
    arm_rc=0
    unhealthy_since=0
    while kill -0 "$child" 2>/dev/null; do
      parent_alive || return 1
      if [ -e "$STATE/.afk" ]; then
        cleanup
        child=
        away_interrupted=1
        break
      fi
      if active_cycle_healthy; then
        unhealthy_since=0
      else
        now=$(date +%s)
        [ "$unhealthy_since" -ne 0 ] || unhealthy_since=$now
        if [ "$((now - unhealthy_since))" -ge 10 ]; then
          arm_rc=1
          cleanup
          break
        fi
      fi
      touch "$STATE/.codex-watch-beat"
      sleep 1
    done
    [ "$away_interrupted" -eq 0 ] || continue
    wait "$child" || arm_rc=$?
    child=
    parent_alive || return 1
    [ ! -e "$STATE/.afk" ] || continue
    cutoff=$(queue_cutoff)
    if [ "$arm_rc" -ne 0 ]; then
      printf 'watcher cycle failed; inspect .codex-watch-cycle\n' > "$FAILURE"
      fm_wake_append check codex-owner-failure 'check: Codex watcher owner cycle failed; inspect state/.codex-watch-failure and restart supervision' || return 1
      "$SCRIPT_DIR/fm-codex-notify.sh" "$thread" "$parent" "$FM_HOME" || true
      return 1
    fi
    [ "${cutoff:-0}" != 0 ] || continue
    # Publish before transport: interruption may lose a notification but never
    # silently duplicates it. start preserves this indeterminate receipt for
    # operator inspection; stop/start alone never creates a queue storm.
    printf 'delivery outcome indeterminate; inspect primary before explicit retry\n' > "$FAILURE"
    printf '%s\n' "$cutoff" > "$PENDING"
    if ! "$SCRIPT_DIR/fm-codex-notify.sh" "$thread" "$parent" "$FM_HOME"; then
      printf 'native queue delivery failed; durable wakes remain pending\n' > "$FAILURE"
      fm_wake_append check codex-owner-failure 'check: Codex native wake delivery failed; inspect state/.codex-watch-failure and use explicit retry' || true
      return 1
    fi
    rm -f "$FAILURE"
  done
  fail 'primary exited or session lock changed'
}
case "${1:-help}" in
  run) run_owner "${2:-}"; exit $? ;;
  help|-h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  start|status|stop|retry) ;;
  *) fail 'unknown command'; exit 2 ;;
esac
control_lock || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
case "$1" in
  retry)
    read_record && parent_alive && [ -s "$PENDING" ] || { fail 'no bound pending delivery'; exit 1; }
    "$SCRIPT_DIR/fm-codex-notify.sh" "$thread" "$parent" "$FM_HOME" || exit 1
    touch "$PENDING"
    rm -f "$FAILURE" "$STATE/.codex-watch-overdue"
    echo 'codex watcher: pending notification explicitly retried; start owner if stopped'
    ;;
  status)
    if read_record && healthy; then echo "codex watcher: running thread=$thread session=$session"; [ ! -f "$STATE/.codex-watch-overdue" ] || cat "$STATE/.codex-watch-overdue"; else fail 'owner absent or unhealthy'; [ ! -f "$FAILURE" ] || cat "$FAILURE" >&2; exit 1; fi
    ;;
  stop)
    if [ ! -e "$RECORD" ]; then echo 'codex watcher: stopped'; exit 0; fi
    read_record || { fail 'malformed owner record'; exit 1; }
    if tmux has-session -t "$session" 2>/dev/null; then
      terminal_matches || { fail 'ambiguous terminal identity; preserving'; exit 1; }
      stop_terminal || exit 1
    fi
    [ -s "$PENDING" ] || rm -f "$RECORD"
    rm -f "$STATE/.codex-watch-ready"
    echo 'codex watcher: stopped (durable pending wakes preserved)'
    ;;
  start)
    want_thread=${2:-}; want_parent=${3:-}
    if [ -s "$FAILURE" ] && [ -s "$PENDING" ]; then
      fail 'delivery failed; inspect failure and use retry before start'; exit 1
    fi
    "$SCRIPT_DIR/fm-codex-notify.sh" --validate "$want_thread" "$want_parent" "$FM_HOME" || exit 1
    if [ -e "$RECORD" ]; then
      read_record || { fail 'malformed owner record'; exit 1; }
      if [ -s "$PENDING" ]; then
        if [ "$thread" != "$want_thread" ] || [ "$parent" != "$want_parent" ] || ! parent_alive; then
          fail 'pending delivery belongs to another binding'; exit 1
        fi
      fi
      if healthy; then
        [ "$thread" = "$want_thread" ] && [ "$parent" = "$want_parent" ] || { fail 'another binding owns supervision'; exit 1; }
        echo "codex watcher: attached thread=$thread session=$session"; exit 0
      fi
      if tmux has-session -t "$session" 2>/dev/null; then
        fail 'unhealthy terminal remains; inspect and stop before restart'; exit 1
      fi
    fi
    thread=$want_thread; parent=$want_parent
    identity=$(fm_pid_identity "$parent") || exit 1
    parent_alive || { fail 'primary does not own home session lock'; exit 1; }
    token="$$-$RANDOM-$(date +%s)"
    session="fm-codex-watch-$token"
    printf '%s\t%s\t%s\t%s\t%s\n' "$thread" "$parent" "$identity" "$session" "$token" > "$RECORD" || exit 1
    rm -f "$FAILURE" "$STATE/.codex-watch-ready" "$STATE/.codex-watch-arm-start"
    owner_env=(env)
    environment_names=(CODEX_HOME PATH HOME FM_CONFIG_OVERRIDE FM_POLL FM_GUARD_GRACE FM_WATCHER_STALE_GRACE FM_ARM_CONFIRM_TIMEOUT FM_ARM_ATTACH_POLL FM_CHECK_INTERVAL FM_CHECK_TIMEOUT FM_HEARTBEAT FM_HEARTBEAT_MAX FM_SIGNAL_GRACE FM_BUSY_TURN_MAX_SECS FM_HOME_SUMMARY_INTERVAL FM_PAUSE_RESURFACE_SECS FM_SECONDMATE_WAKE_STALL_SECS FM_STALE_ESCALATE_SECS FM_TURNEND_CHURN_ABSORB_SECS FM_WEDGE_DEMAND_INSPECT_COUNT FM_EVENT_CAP_FAIL_MAX FM_WATCH_CYCLE_LOG_MAX_BYTES FM_WATCH_CYCLE_LOG_KEEP_LINES)
    for name in "${environment_names[@]}"; do
      owner_env+=(-u "$name")
    done
    for name in "${environment_names[@]}"; do
      [ "${!name+x}" != x ] || owner_env+=("$name=${!name}")
    done
    printf -v command '%q ' "${owner_env[@]}" "FM_HOME=$FM_HOME" "$SCRIPT_DIR/fm-codex-watch.sh" run "$token"
    command="exec $command"
    # Launch held behind a tmux wait channel until the exact token is installed.
    launch=$(printf 'tmux wait-for %q; %s' "$token" "$command")
    tmux new-session -d -s "$session" "$launch" || exit 1
    tmux set-option -t "$session" @fm_codex_watch_token "$token" || exit 1
    tmux wait-for -S "$token" || exit 1
    for _ in {1..100}; do
      if healthy; then echo "codex watcher: started thread=$thread session=$session"; exit 0; fi
      sleep 0.1
    done
    fail 'owner failed readiness; inspect recorded endpoint'; exit 1
    ;;
esac
