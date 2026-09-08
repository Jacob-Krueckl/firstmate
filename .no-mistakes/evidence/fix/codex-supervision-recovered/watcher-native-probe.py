import fcntl, json, os, pathlib, pty, re, select, signal, struct, subprocess, sys, tempfile, termios, time
root = pathlib.Path(sys.argv[1])
version = subprocess.check_output(['codex', '--version'], text=True).strip()
home = pathlib.Path(os.environ.get('CODEX_HOME', str(pathlib.Path.home()/'.codex')))
lab = tempfile.mkdtemp(prefix='fm-codex-idle-live-')
subprocess.run(['git', 'init', '-q', lab], check=True)
import shutil
shutil.copytree(root/'bin', pathlib.Path(lab, 'bin'))
pathlib.Path(lab, 'state').mkdir()
pathlib.Path(lab, 'AGENTS.md').write_text('This is an isolated supervision test home. On FIRSTMATE_CODEX_WAKE run bin/fm-wake-drain.sh, handle signal records by reporting their text, and execute the exact acknowledgement command it prints. Do not start watchers yourself.\n')
os.environ['FM_HOME'] = lab
os.environ['FM_POLL'] = '0.2'
os.environ['FM_ARM_ATTACH_POLL'] = '0.2'
pid, terminal = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
    os.execvp('codex', ['codex', '--no-alt-screen', '-C', lab, 'Reply exactly FM_IDLE_INITIAL. Do not run tools.'])
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
    await_completion('FM_IDLE_INITIAL')
    subprocess.run([str(root/'bin/fm-codex-notify.sh'), '--validate', thread, str(pid), lab], check=True)
    bad = subprocess.run([str(root/'bin/fm-codex-notify.sh'), '--validate', thread, str(pid), lab+'/wrong'], capture_output=True)
    if bad.returncode == 0:
        raise RuntimeError('wrong home passed callback validation')
    pathlib.Path(lab, 'state/.lock').write_text(str(pid)+'\n')
    owner = str(root/'bin/fm-codex-watch.sh')
    subprocess.run([owner, 'start', thread, str(pid)], check=True)
    for seq in (1, 2):
        deadline = time.monotonic()+30
        while not pathlib.Path(lab, 'state/.watch.lock/pid').exists():
            pump()
            if time.monotonic()>deadline: raise RuntimeError('watcher did not rearm')
        pathlib.Path(lab, 'state/.wake-queue').write_text(f'{seq}\t{int(time.time())}\tsignal\tprobe\tsignal: native cycle {seq} handled\n')
        deadline = time.monotonic()+90
        while pathlib.Path(lab, 'state/.wake-queue').stat().st_size:
            pump()
            if time.monotonic()>deadline: raise RuntimeError('native callback did not drain/ack')
        print(f'native cycle {seq}: watcher delivered callback; TUI drained and acknowledged durable row', flush=True)
    deadline = time.monotonic()+30
    while not pathlib.Path(lab, 'state/.watch.lock/pid').exists():
        pump()
        if time.monotonic()>deadline: raise RuntimeError('final rearm missing')
    subprocess.run([owner, 'status'], check=True)

finally:
    subprocess.run([str(root/'bin/fm-codex-watch.sh'), 'stop'])
    pathlib.Path(lab, 'terminal.log').write_text(transcript)
    # Only the exact child created here is closed, never an existing session.
    os.kill(pid, signal.SIGTERM)
    os.waitpid(pid, 0)
    os.close(terminal)
    print('live evidence: '+lab)