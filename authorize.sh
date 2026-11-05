#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 1 ]] || { echo 'Uso: sudo bash server/authorize.sh telefono.pub' >&2; exit 1; }
python3 - "$1" 3<&0 <<'PY'
import base64, pathlib, struct, sys
source = open(3) if sys.argv[1] == "/dev/stdin" else open(sys.argv[1])
with source:
    line = source.read().strip()
parts = line.split()
if len(parts) < 2 or parts[0] != 'ssh-rsa' or '\n' in line:
    raise SystemExit('Se requiere una única clave pública RSA OpenSSH')
b = base64.b64decode(parts[1], validate=True)
fields = []
while b:
    if len(b) < 4: raise SystemExit('Clave inválida')
    n = struct.unpack('>I', b[:4])[0]
    if n > len(b) - 4: raise SystemExit('Clave inválida')
    fields.append(b[4:4+n]); b = b[4+n:]
if len(fields) != 3 or fields[0] != b'ssh-rsa' or int.from_bytes(fields[2], 'big').bit_length() < 3072:
    raise SystemExit('Se requiere RSA de al menos 3072 bits')
p = pathlib.Path('/etc/personal-remote/authorized_keys')
entry = 'restrict,pty ssh-rsa ' + parts[1] + ' personal-android'
lines = p.read_text().splitlines()
if entry not in lines:
    with p.open('a') as f: f.write(entry + '\n')
p.chmod(0o600)
print('Teléfono autorizado. No hace falta reiniciar el servidor.')
PY
