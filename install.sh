#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Ejecuta con sudo.' >&2; exit 1; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v sshd >/dev/null
command -v python3 >/dev/null
install -d -o root -g root -m 700 /etc/personal-remote
install -d -o root -g root -m 755 /usr/local/lib/personal-remote
install -o root -g root -m 644 runner.py /usr/local/lib/personal-remote/runner.py
install -o root -g root -m 600 sshd_config /etc/personal-remote/sshd_config
install -o root -g root -m 644 personal-remote.service /etc/systemd/system/personal-remote.service
if [[ ! -f /etc/personal-remote/ssh_host_rsa_key ]]; then
    ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/personal-remote/ssh_host_rsa_key
fi
if [[ ! -f /etc/personal-remote/authorized_keys ]]; then
    install -o root -g root -m 600 /dev/null /etc/personal-remote/authorized_keys
fi
bash ./setup.sh --machine configure local/offline "${1:-}" "${SUDO_USER:-$(id -un)}"
[[ -d /run/sshd ]] || install -d -m 755 /run/sshd
# Upgrade existing app keys: allow PTY while retaining other restrictions.
python3 - <<'MIGRATE'
from pathlib import Path
p = Path('/etc/personal-remote/authorized_keys')
s = p.read_text()
lines = [line.replace('restrict ssh-rsa ', 'restrict,pty ssh-rsa ', 1)
         if line.startswith('restrict ssh-rsa ') else line for line in s.splitlines()]
p.write_text('\n'.join(lines) + ('\n' if lines else ''))
p.chmod(0o600)
MIGRATE
/usr/sbin/sshd -t -f /etc/personal-remote/sshd_config
systemctl daemon-reload
systemctl enable personal-remote.service
systemctl restart personal-remote.service
systemctl is-active personal-remote.service
printf '\nHuella para la app Android:\n'
ssh-keygen -lf /etc/personal-remote/ssh_host_rsa_key.pub -E sha256
