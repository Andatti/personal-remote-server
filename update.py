#!/usr/bin/python3
"""Deploy the configured repository's fast-forward main, with a recoverable file transaction."""
import argparse
import fcntl
import json
import os
import pwd
import subprocess
import sys
import tempfile
import time
from pathlib import Path

STATE = Path('/var/lib/personal-remote-update')
CONFIG = Path('/etc/personal-remote')
LIB = Path('/usr/local/lib/personal-remote')
UNITS = Path('/etc/systemd/system')
SERVICE = 'personal-remote.service'
TIMER = 'personal-remote-update.timer'
FILES = {
    'runner.py': (LIB / 'runner.py', 0o644),
    'sshd_config': (CONFIG / 'sshd_config', 0o600),
    'authorize.sh': (LIB / 'authorize.sh', 0o700),
    'update.py': (LIB / 'update.py', 0o700),
    SERVICE: (UNITS / SERVICE, 0o644),
    'personal-remote-update.service': (UNITS / 'personal-remote-update.service', 0o644),
    TIMER: (UNITS / TIMER, 0o644),
}


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, timeout=90).stdout


def git(*args):
    return run('git', '--git-dir', STATE / 'repo.git', *args)


def write(path, data, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        try:
            os.fchmod(tmp.fileno(), mode)
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
            os.replace(tmp.name, path)
        finally:
            Path(tmp.name).unlink(missing_ok=True)


def stage(commit, dest):
    for name in FILES:
        entry = git('ls-tree', commit, '--', name).decode().split()
        if len(entry) != 4 or entry[0] not in ('100644', '100755') or entry[1] != 'blob' or entry[3] != name:
            raise ValueError(f'Archivo obligatorio inválido: {name}')
        if int(git('cat-file', '-s', entry[2])) > 1024 * 1024:
            raise ValueError(f'Archivo demasiado grande: {name}')
        (dest / name).write_bytes(git('cat-file', 'blob', entry[2]))
    for name in ('runner.py', 'update.py'):
        compile((dest / name).read_bytes(), name, 'exec')
    run('bash', '-n', dest / 'authorize.sh')
    run('/usr/sbin/sshd', '-t', '-f', dest / 'sshd_config')
    run('systemd-analyze', 'verify', *(dest / name for name in (SERVICE, 'personal-remote-update.service', TIMER)))


def check_runner():
    try:
        scripts = Path((LIB / 'scripts-dir').read_text().rstrip('\n'))
    except FileNotFoundError:
        scripts = Path('/home/maetti/.personalScripts')
    account = pwd.getpwuid(scripts.stat().st_uid)
    reply = subprocess.run(
        ['/usr/bin/python3', '-I', LIB / 'runner.py'], check=True, capture_output=True,
        timeout=10, user=account.pw_uid, group=account.pw_gid, extra_groups=[], cwd='/',
        env={'SSH_ORIGINAL_COMMAND': 'list', 'PATH': '/usr/bin', 'LANG': 'C.UTF-8'})
    result = json.loads(reply.stdout)
    if result.get('ok') is not True or not isinstance(result.get('scripts'), list) or result.get('protocol', 0) < 2:
        raise RuntimeError('El ejecutor no responde al protocolo de la app')


def healthy():
    run('systemctl', 'is-active', '--quiet', SERVICE)
    config = run('/usr/sbin/sshd', '-T', '-f', CONFIG / 'sshd_config').decode().splitlines()
    port = next(line.split()[1] for line in config if line.lower().startswith('port '))
    expected = (CONFIG / 'ssh_host_rsa_key.pub').read_text().split()[:2]
    for _ in range(5):
        probe = subprocess.run(['ssh-keyscan', '-4', '-T', '2', '-p', port, '-t', 'rsa', '127.0.0.1'],
                               capture_output=True, timeout=5, text=True)
        if any(line.split()[1:3] == expected for line in probe.stdout.splitlines()):
            check_runner()
            return
        time.sleep(0.4)
    raise RuntimeError('El puerto SSH no presenta la clave esperada')


def active(unit):
    return subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0


def rollback(pending):
    record = json.loads((pending / 'record').read_text())
    print('Restaurando la instalación anterior.', flush=True)
    for name in record['changed']:
        path, mode = FILES[name]
        prior = pending / name
        if prior.exists():
            write(path, prior.read_bytes(), mode)
        else:
            path.unlink(missing_ok=True)
    run('systemctl', 'daemon-reload')
    if record['running']:
        if SERVICE in record['changed'] or 'sshd_config' in record['changed'] or not active(SERVICE):
            run('systemctl', 'restart', SERVICE)
        healthy()
    elif active(SERVICE):
        run('systemctl', 'stop', SERVICE)
    if record['timer_running']:
        run('systemctl', 'restart', TIMER)
    previous = record['previous']
    if previous:
        git('update-ref', 'refs/personal-remote/deployed', previous)
        write(STATE / 'installed', (previous+'\n').encode(), 0o600)
    else:
        git('update-ref', '-d', 'refs/personal-remote/deployed')
        (STATE / 'installed').unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(dir=STATE) as tmp:
        pending.rename(Path(tmp) / 'restored')


def deploy(commit):
    pending = STATE / 'pending'
    if pending.exists():
        rollback(pending)
    version = STATE / 'installed'
    old = version.read_text().strip() if version.exists() else ''
    if old == commit:
        print(f'Al día: {commit[:12]}')
        return
    if old:
        git('merge-base', '--is-ancestor', old, commit)
    with tempfile.TemporaryDirectory(dir=STATE) as tmp:
        candidate = Path(tmp)
        stage(commit, candidate)
        changed = [name for name, (path, _) in FILES.items()
                   if not path.is_file() or path.read_bytes() != (candidate / name).read_bytes()]
        backup = candidate / 'backup'
        backup.mkdir()
        for name in changed:
            path = FILES[name][0]
            if path.is_file():
                (backup / name).write_bytes(path.read_bytes())
        record = dict(previous=old, changed=changed, running=active(SERVICE), timer_running=active(TIMER))
        (backup / 'record').write_text(json.dumps(record))
        backup.rename(pending)
        try:
            for name in changed:
                path, mode = FILES[name]
                write(path, (candidate / name).read_bytes(), mode)
            if any(name.endswith(('.service', '.timer')) for name in changed):
                run('systemctl', 'daemon-reload')
            if not record['running'] or SERVICE in changed:
                run('systemctl', 'restart', SERVICE)
            elif 'sshd_config' in changed:
                run('systemctl', 'kill', '--kill-who=main', '--signal=HUP', SERVICE)
            healthy()
            if TIMER in changed and record['timer_running']:
                run('systemctl', 'restart', TIMER)
            git('update-ref', 'refs/personal-remote/deployed', commit)
            write(version, (commit+'\n').encode(), 0o600)
        except BaseException:
            rollback(pending)
            raise
        pending.rename(candidate / 'committed')
    print(f'Instalado {commit[:12]}. Archivos actualizados: {", ".join(changed) or "ninguno"}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bootstrap', action='store_true')
    args = parser.parse_args()
    if os.geteuid():
        sys.exit('Se requiere root')
    if not Path('/run/sshd').exists():
        run('install', '-d', '-m', '0755', '/run/sshd')
    os.umask(0o077)
    with (STATE / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (STATE / 'pending').exists():
            rollback(STATE / 'pending')
        if not args.bootstrap:
            git('fetch', '--no-tags', 'origin', 'refs/heads/main')
        commit = git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').decode().strip()
        deploy(commit)


if __name__ == '__main__':
    main()
