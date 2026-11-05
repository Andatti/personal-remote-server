#!/usr/bin/python3
"""SSH protocol: legacy JSON runs, interactive scripts and an authorized root console."""
import base64
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile

def scripts_directory():
    try:
        return Path(Path(__file__).with_name('scripts-dir').read_text().rstrip('\n'))
    except FileNotFoundError:
        # Installations predating per-host configuration.
        return Path('/home/maetti/.personalScripts')


SCRIPTS = scripts_directory()
LOCK = '/run/personal-remote.lock'
TIMEOUT = 300
OUTPUT_LIMIT = 256 * 1024


def script_path(name):
    if not name or name in ('.', '..') or '/' in name or '\\' in name or '\x00' in name:
        raise ValueError('Nombre de script inválido')
    p = SCRIPTS / name
    st = p.lstat()
    if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o111:
        raise ValueError('El script debe ser un archivo ejecutable, sin enlaces simbólicos')
    if st.st_mode & 0o022:
        raise ValueError('El script no puede permitir escritura a grupo u otros')
    return p


def dispatch(command):
    if command == 'list':
        names = []
        for p in sorted(SCRIPTS.iterdir()):
            try:
                script_path(p.name)
                names.append(p.name)
            except (ValueError, OSError):
                pass
        return {'ok': True, 'scripts': names, 'uid': os.geteuid(), 'protocol': 2}
    if not command.startswith('run ') or len(command) > 2048:
        raise ValueError('Comando no admitido')
    name = base64.b64decode(command[4:], altchars=b'-_', validate=True).decode('utf-8')
    path = script_path(name)
    with open(LOCK, 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Ya hay un script ejecutándose')
        # Drain continuously, retaining a bounded output buffer.
        import selectors
        import time
        proc = subprocess.Popen([str(path)], cwd=SCRIPTS, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
            env={'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root',
                 'LANG': 'C.UTF-8', 'USER': 'root', 'LOGNAME': 'root'})
        data = bytearray()
        truncated = False
        timed_out = False
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + TIMEOUT
        try:
            while selector.get_map():
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        break
                    remaining = OUTPUT_LIMIT - len(data)
                    data.extend(chunk[:remaining])
                    truncated |= len(chunk) > remaining
            if not timed_out:
                try:
                    proc.wait(timeout=max(0.01, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    timed_out = True
        finally:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            selector.close()
            proc.stdout.close()
        return {'ok': True, 'script': name, 'exit_code': proc.returncode,
                'timed_out': timed_out, 'truncated': truncated,
                'output': data.decode('utf-8', errors='replace')}


def interactive(command):
    if not os.isatty(0):
        raise ValueError('Se requiere una terminal PTY. Actualiza el servidor y la clave autorizada.')
    os.chdir(SCRIPTS)
    if command == 'console':
        os.execv('/bin/bash', ['bash', '-i'])
    if not command.startswith('interactive ') or len(command) > 2048:
        raise ValueError('Comando interactivo inválido')
    name = base64.b64decode(command[12:], altchars=b'-_', validate=True).decode('utf-8')
    path = script_path(name)
    # SSH owns the PTY, signals and session lifetime; preserve stdin/stdout/stderr.
    os.execv(str(path), [str(path)])


def main():
    try:
        command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
        if command == 'console' or command.startswith('interactive '):
            interactive(command)
        result = dispatch(command)
    except Exception as exc:
        result = {'ok': False, 'error': str(exc)}
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
