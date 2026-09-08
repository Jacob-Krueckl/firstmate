#!/usr/bin/env bash
# Native Codex TUI callback. Linux only until another structural binding is
# live-verified. --validate THREAD PID [HOME] proves a retained terminal process
# owns the exact CLI rollout, rather than trusting inherited thread variables.
# THREAD PID [HOME] repeats that validation and queues one fixed drain reminder.
# Exit zero from queue is a receipt, never handling acknowledgement. The caller
# owns lifecycle, deduplication, timeout alarms, and durable wake acknowledgements.
set -eu
validate=false
if [ "${1:-}" = --validate ]; then validate=true; shift; fi
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo 'usage: fm-codex-notify.sh [--validate] THREAD PID [HOME]' >&2
  exit 2
fi
python3 - "$@" <<'PY'
import json, os, pathlib, re, stat, sys
thread, pid = sys.argv[1:3]
home = os.path.realpath(sys.argv[3]) if len(sys.argv) == 4 else None

def fail():
    sys.exit('codex callback: no verified retained TUI owns this thread and home')

if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', thread) or not re.fullmatch(r'[1-9][0-9]*', pid):
    fail()
try:
    proc = pathlib.Path('/proc') / pid
    if proc.stat().st_uid != os.getuid() or pathlib.Path(os.readlink(proc / 'exe')).name != 'codex':
        fail()
    fd = os.open(proc / 'fd/0', os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    try:
        if not os.isatty(fd):
            fail()
    finally:
        os.close(fd)
    for entry in (proc / 'fd').iterdir():
        try:
            path = pathlib.Path(os.readlink(entry))
            if not path.name.endswith('-' + thread + '.jsonl') or not path.name.startswith('rollout-'):
                continue
            if not stat.S_ISREG(entry.stat().st_mode):
                continue
            with entry.open() as stream:
                record = json.loads(stream.readline(1048576))
            meta = record.get('payload', {})
            if record.get('type') == 'session_meta' and meta.get('id') == thread and meta.get('source') == 'cli' and meta.get('thread_source', 'user') == 'user' and (home is None or os.path.realpath(meta.get('cwd', '')) == home):
                sys.exit(0)
        except (OSError, ValueError):
            continue
except (OSError, ValueError):
    pass
fail()
PY
if [ "$validate" = true ]; then exit 0; fi
exec timeout 20 codex queue --thread "$1" --message 'FIRSTMATE_CODEX_WAKE: Internal supervision wake. Continue the current fleet task: run bin/fm-wake-drain.sh, handle its durable records, and run its exact acknowledgement command only after handling. The registered Codex watcher owner retains supervision; do not start a foreground checkpoint or duplicate watcher.'
