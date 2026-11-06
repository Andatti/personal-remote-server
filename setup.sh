#!/usr/bin/env bash
# Linux with systemd. Install as root or with sudo.
set -Eeuo pipefail
self=$(realpath -- "${BASH_SOURCE[0]}")
state=/var/lib/personal-remote-update
conf=/etc/personal-remote
lib=/usr/local/lib/personal-remote
die(){ echo "$*" >&2; exit 1; }
valid_repo(){ [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${1#*/} != . && ${1#*/} != .. ]]; }
usage(){ echo "Uso: bash setup.sh [--user CUENTA] [PROPIETARIO/REPOSITORIO]"; }

machine(){
    [[ $EUID == 0 ]] || die 'La preparación de la máquina requiere sudo.'
    local phase=$1 repo=$2
    valid_repo "$repo" || die 'Repositorio inválido.'
    umask 077
    install -d -o root -g root -m 700 "$state" "$conf"
    exec 9>"$state/setup.lock"
    flock -x 9
    local gitdir="$state/repo.git" url="https://github.com/$repo.git"
    if [[ -d $gitdir ]]; then
        local origin
        origin=$(git --git-dir="$gitdir" remote get-url origin)
        [[ $origin == "$url" || $origin == "git@github.com:$repo.git" ]] ||
            die 'Este equipo ya está asociado a otro repositorio.'
    fi
    case "$phase" in
        configure)
            local account=$3 home scripts saved="$lib/scripts-dir"
            install -d -m 755 "$lib"
            if [[ -z $account && -f $saved ]]; then
                scripts=$(cat "$saved")
                [[ -d $scripts ]] || die "Falta la carpeta configurada: $scripts"
            else
                if [[ -z $account && -f $lib/runner.py && -d /home/maetti/.personalScripts ]]; then account=maetti; fi
                account=${account:-${4:?}}
                home=$(getent passwd "$account" | cut -d: -f6)
                [[ $home == /* && -d $home ]] || die "La cuenta $account necesita un directorio personal existente."
                scripts="${home%/}/.personalScripts"
                [[ -d $scripts ]] || install -d -m 700 -o "$(id -u -- "$account")" -g "$(id -g -- "$account")" "$scripts"
                local tmp
                tmp=$(mktemp "$lib/.scripts-dir.XXXXXXXX")
                printf '%s\n' "$scripts" > "$tmp"
                chmod 644 "$tmp"
                mv -fT "$tmp" "$saved"
            fi
            echo "Carpeta de scripts: $scripts"
            ;;
        install)
            if [[ ! -d $gitdir ]]; then
                git init -q --bare "$gitdir"
                git --git-dir="$gitdir" remote add origin "$url"
            fi
            git --git-dir="$gitdir" remote set-url origin "$url"
            git --git-dir="$gitdir" config credential.helper ""
            git --git-dir="$gitdir" config --unset-all core.sshCommand || [[ $? == 5 ]]
            install -d -m 755 "$lib"
            [[ -f $conf/ssh_host_rsa_key ]] || ssh-keygen -q -t rsa -b 3072 -N '' -f "$conf/ssh_host_rsa_key"
            if [[ ! -f $conf/ssh_host_rsa_key.pub ]]; then ssh-keygen -y -f "$conf/ssh_host_rsa_key" > "$conf/ssh_host_rsa_key.pub"; fi
            [[ -f $conf/authorized_keys ]] || install -m 600 /dev/null "$conf/authorized_keys"
            if grep -q '^restrict ssh-rsa ' "$conf/authorized_keys"; then
                sed -i 's/^restrict ssh-rsa /restrict,pty ssh-rsa /' "$conf/authorized_keys"
            fi
            if [[ -f $lib/update.py ]]; then
                /usr/bin/python3 -I "$lib/update.py"
            else
                git --git-dir="$gitdir" fetch --no-tags origin refs/heads/main
                local boot
                boot=$(mktemp "$state/bootstrap.XXXXXXXX")
                trap 'rm -f -- "${boot:-}"' RETURN
                git --git-dir="$gitdir" show FETCH_HEAD:update.py > "$boot"
                /usr/bin/python3 -I "$boot" --bootstrap
            fi
            systemctl enable personal-remote.service
            systemctl enable --now personal-remote-update.timer
            systemctl is-active personal-remote.service personal-remote-update.timer
            ssh-keygen -lf "$conf/ssh_host_rsa_key.pub" -E sha256
            ;;
        *) die 'Fase desconocida.';;
    esac
}

if [[ ${1:-} == --machine ]]; then shift; machine "$@"; exit; fi
if [[ ${1:-} == --help ]]; then usage; exit; fi
account=
if [[ ${1:-} == --user ]]; then account=${2:?Falta la cuenta local}; shift 2; fi
[[ $# -le 1 ]] || { usage; exit 2; }
[[ -d /run/systemd/system ]] || die 'Se requiere systemd activo.'
if [[ -n $account ]]; then id -- "$account" >/dev/null || die 'Cuenta local desconocida.'; fi
admin=()
if (( EUID != 0 )); then admin=(sudo); sudo -v; fi
caller=${SUDO_USER:-$(id -un)}
export PATH="$PATH:/usr/sbin:/sbin"
if command -v apt-get >/dev/null; then
    deps=(git:git sshd:openssh-server ssh-keyscan:openssh-client python3:python3 flock:util-linux)
elif command -v pacman >/dev/null; then
    deps=(git:git sshd:openssh ssh-keyscan:openssh python3:python flock:util-linux)
else
    die 'Gestores soportados: apt (Debian/Ubuntu) y pacman (Arch/CachyOS).'
fi
packages=()
for pair in "${deps[@]}"; do
    command -v "${pair%:*}" >/dev/null || packages+=("${pair#*:}")
done
if (( ${#packages[@]} )); then
    if command -v apt-get >/dev/null; then
        "${admin[@]}" apt-get update
        "${admin[@]}" apt-get install "${packages[@]}"
    else
        "${admin[@]}" pacman -S --needed "${packages[@]}"
    fi
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die 'Se requiere Python 3.9 o posterior.'
repo=${1:-Andatti/personal-remote-server}
valid_repo "$repo" || die 'Usa PROPIETARIO/REPOSITORIO.'
export GIT_TERMINAL_PROMPT=0
git -c credential.helper= ls-remote --exit-code "https://github.com/$repo.git" refs/heads/main >/dev/null

"${admin[@]}" bash "$self" --machine configure "$repo" "$account" "$caller"
"${admin[@]}" bash "$self" --machine install "$repo"
if ! "${admin[@]}" test -s "$conf/authorized_keys"; then
    echo 'Pega la clave pública RSA de la app para autorizar el teléfono:'
    IFS= read -r phone
    printf '%s\n' "$phone" | "${admin[@]}" bash "$lib/authorize.sh" /dev/stdin
fi
echo "Repositorio: https://github.com/$repo"
systemctl list-timers personal-remote-update.timer --no-pager
