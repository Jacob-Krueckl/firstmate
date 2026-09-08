#!/usr/bin/env bash
# Opt-in native hook routing proof in an isolated, agent-authored scratch root.
# Grants trust only to the scratch project and its reviewed hooks for this
# invocation. Does not change sandbox or approval defaults.
set -eu
if [ "${FM_CODEX_HOOK_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_CODEX_HOOK_LIVE_E2E=1 to run the Codex native hook routing regression'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v codex >/dev/null || { echo 'not ok - codex absent' >&2; exit 1; }
python3 - "$ROOT" <<'PY'
import fcntl, json, os, pathlib, pty, re, select, shlex, shutil, signal, struct, subprocess, sys, tempfile, termios, time
root = pathlib.Path(sys.argv[1])
version = subprocess.check_output(['codex', '--version'], text=True).strip()
home = pathlib.Path(os.environ.get('CODEX_HOME', str(pathlib.Path.home()/'.codex')))
lab = tempfile.mkdtemp(prefix='fm-codex-hook-live-')
pathlib.Path(lab, 'bin').mkdir()
pathlib.Path(lab, '.codex').mkdir()
pathlib.Path(lab, 'AGENTS.md').write_text('Execute only the requested harmless probe. Do not modify files.\n')
shutil.copyfile(root/'.codex/hooks.json', pathlib.Path(lab, '.codex/hooks.json'))
subprocess.run(['git', 'init', '-q', lab], check=True)
for helper in ('fm-sessionstart-run', 'fm-arm-pretool-check', 'fm-cd-pretool-check', 'fm-turnend-guard'):
    script = pathlib.Path(lab, 'bin', helper+'.sh')
    script.write_text('#!/usr/bin/env bash\ncat >/dev/null\nverdict=$('+shlex.quote(str(root/'bin/fm-harness.sh'))+')\nprintf \'%s\\t%s\\n\' '+shlex.quote(helper)+' "$verdict" >> '+shlex.quote(str(pathlib.Path(lab, 'events.tsv')))+'\n')
    script.chmod(0o755)
pid, terminal = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
    os.environ['GROK_AGENT'] = '1'
    os.chdir(lab)
    os.execvp('codex', ['codex', '--dangerously-bypass-hook-trust', '--no-alt-screen', 'Run one shell command: printf HOOK_TOOL_PROBE. Then reply exactly FM_HOOK_COMPLETE. Do not modify files.'])
transcript = ''
trusted = False
rollout = None
thread = None

def pump():
    global transcript, trusted
    if select.select([terminal], [], [], 0.2)[0]:
        chunk = os.read(terminal, 65536).decode(errors='replace')
        transcript += chunk
        pathlib.Path(lab, 'terminal.log').write_text(transcript)
        if '\x1b]10;?' in chunk:
            os.write(terminal, b'\x1b]10;rgb:ffff/ffff/ffff\x1b\\')
        if '\x1b]11;?' in chunk:
            os.write(terminal, b'\x1b]11;rgb:0000/0000/0000\x1b\\')
        if '\x1b[6n' in chunk:
            os.write(terminal, b'\x1b[1;1R')
    screen = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', transcript)
    if not trusted and 'trust' in screen and 'Press enter to continue' in screen:
        time.sleep(0.5)
        os.write(terminal, b'\r')
        trusted = True

def completed(marker):
    if rollout is None:
        return False
    for line in rollout.read_text().splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue  # The live writer may not have finished this record yet.
        payload = record.get('payload', {})
        if record.get('type') == 'event_msg' and payload.get('type') == 'task_complete' and payload.get('last_agent_message') == marker:
            return True
    return False

def await_completion(marker):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        pump()
        if completed(marker):
            return
    raise RuntimeError('no completed idle turn for ' + marker)

try:
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and rollout is None:
        pump()
        for candidate in (home/'sessions').glob('*/*/*/rollout-*.jsonl'):
            if candidate.stat().st_mtime < time.time()-180:
                continue
            try:
                with candidate.open() as stream:
                    record = json.loads(stream.readline())
            except (json.JSONDecodeError, FileNotFoundError):
                continue  # The rollout can exist before its first record lands.
            meta = record.get('payload', {})
            if record.get('type') == 'session_meta' and meta.get('cwd') == lab and meta.get('source') == 'cli':
                rollout, thread = candidate, meta['id']
                break
    if rollout is None:
        raise RuntimeError('no scratch TUI rollout appeared')
    await_completion('FM_HOOK_COMPLETE')
    expected = {name+'\tcodex' for name in ('fm-sessionstart-run', 'fm-arm-pretool-check', 'fm-cd-pretool-check', 'fm-turnend-guard')}
    deadline = time.monotonic()+10
    while time.monotonic() < deadline:
        pump()
        events = pathlib.Path(lab, 'events.tsv')
        actual = set(events.read_text().splitlines()) if events.exists() else set()
        if expected <= actual:
            print('ok - '+version+' native SessionStart, PreToolUse and Stop bind Codex despite GROK_AGENT=1')
            break
    else:
        raise RuntimeError('missing native hook evidence: '+repr(expected-actual))
finally:
    pathlib.Path(lab, 'terminal.log').write_text(transcript)
    # Only the exact child created here is closed, never an existing session.
    os.kill(pid, signal.SIGTERM)
    os.waitpid(pid, 0)
    os.close(terminal)
    print('live evidence: '+lab)
PY
