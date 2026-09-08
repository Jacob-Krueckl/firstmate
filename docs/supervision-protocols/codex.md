Mode: Codex retained TUI callback (Linux and tmux).

When this session owns supervision and away mode is not active:
1. Drain with `bin/fm-wake-drain.sh`, handle the records, then execute its exact acknowledgement command.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Start the retained owner with explicit `FM_HOME` and `bin/fm-codex-watch.sh start THREAD PID`, using this interactive session's UUID and the PID holding this home's session lock.
   The helper verifies the live TUI's open rollout and creates an identity-bound tmux process owner.
4. Verify `bin/fm-codex-watch.sh status` before ending the turn.
5. On `FIRSTMATE_CODEX_WAKE`, drain and handle the durable queue and acknowledge only after handling.
   The owner waits for that acknowledgement before its next notification.
6. On owner failure, inspect its diagnostic and follow the recovery contract in `bin/fm-codex-watch.sh --help` before restoring the same binding.
7. Never run a duplicate arm, background shell watcher, or foreground checkpoint while the owner is healthy.

Native `codex queue` wakes an idle retained interactive TUI; a successfully queued message to an exited `codex exec` session does not establish wake delivery.
The owner lifecycle and callback validation are defined by `bin/fm-codex-watch.sh` and `bin/fm-codex-notify.sh`.
On a platform without the validated transport, a foreground `bin/fm-watch-checkpoint.sh` remains a bounded diagnostic or attended fallback, not continuous supervision after the turn ends.
