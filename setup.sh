#!/usr/bin/env bash
# Linux with systemd. Install as root or with sudo.
set -Eeuo pipefail
self=$(realpath -- "${BASH_SOURCE[0]}")
src=$(dirname -- "$self")
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
    local gitdir="$state/repo.git" url="git@github.com:$repo.git"
    if [[ -d $gitdir && $(git --git-dir="$gitdir" remote get-url origin) != "$url" ]]; then
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
        prepare)
            if [[ ! -f $state/github_read ]]; then
                ssh-keygen -q -t ed25519 -N '' -C personal-remote-update -f "$state/github_read"
            fi
            # Published at docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
            echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$state/github_known_hosts"
            ;;
        install)
            if [[ ! -d $gitdir ]]; then
                git init -q --bare "$gitdir"
                git --git-dir="$gitdir" remote add origin "$url"
            fi
            git --git-dir="$gitdir" config core.sshCommand "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$state/github_known_hosts -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -i $state/github_read"
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
    deps=(git:git gh:gh sshd:openssh-server ssh-keyscan:openssh-client python3:python3 flock:util-linux)
elif command -v pacman >/dev/null; then
    deps=(git:git gh:github-cli sshd:openssh ssh-keyscan:openssh python3:python flock:util-linux)
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
export GH_HOST=github.com
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo 'Autoriza GitHub desde tu navegador con el código que muestre gh.'
    gh auth login --hostname github.com --git-protocol https --web
fi
if [[ $# == 1 ]]; then
    repo=$1
    valid_repo "$repo" || die 'Usa PROPIETARIO/REPOSITORIO.'
    gh repo view "$repo" --json nameWithOwner >/dev/null
else
    [[ -f $src/runner.py && -f $src/update.py ]] || die 'Para una instalación independiente, indica PROPIETARIO/REPOSITORIO.'
    cd -- "$src"
    owner=$(gh api user --jq .login)
    repo="$owner/personal-remote-server"
    valid_repo "$repo" || die 'Repositorio inválido.'
    [[ -d .git ]] || git init -q -b main
    [[ $(git branch --show-current) == main ]] || die 'Selecciona la rama main antes de instalar.'
    git config --get user.name >/dev/null || git config --local user.name "$owner"
    git config --get user.email >/dev/null || git config --local user.email "$owner@users.noreply.github.com"
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        git add -- .gitignore README.md runner.py authorize.sh install.sh setup.sh update.py sshd_config personal-remote.service personal-remote-update.service personal-remote-update.timer tests
        git -c user.name="$owner" -c user.email="$owner@users.noreply.github.com" commit -m 'Install and update the personal SSH server'
    fi
    origin=$(git remote get-url origin 2>/dev/null || true)
    expected="https://github.com/$repo.git"
    if [[ -z $origin ]]; then
        gh repo create "$repo" --private
        git remote add origin "$expected"
    elif [[ $origin != "$expected" ]]; then
        die "Origen diferente. Usa bash setup.sh PROPIETARIO/REPOSITORIO para instalar desde un repositorio existente."
    fi
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin main
    git config --local credential.https://github.com.helper '!gh auth git-credential'
fi

"${admin[@]}" bash "$self" --machine configure "$repo" "$account" "$caller"
"${admin[@]}" bash "$self" --machine prepare "$repo"
public=$("${admin[@]}" cat "$state/github_read.pub")
key_material=$(cut -d' ' -f1-2 <<< "$public")
registered=$(gh api --paginate "repos/$repo/keys" --jq '.[] | select(.read_only) | .key')
if ! awk '{print $1, $2}' <<< "$registered" | grep -Fxq "$key_material"; then
    gh api -X POST "repos/$repo/keys" -f title="Personal Remote · $(hostname)" -f key="$public" -F read_only=true --silent
fi
"${admin[@]}" bash "$self" --machine install "$repo"
if ! "${admin[@]}" test -s "$conf/authorized_keys"; then
    echo 'Pega la clave pública RSA de la app para autorizar el teléfono:'
    IFS= read -r phone
    printf '%s\n' "$phone" | "${admin[@]}" bash "$lib/authorize.sh" /dev/stdin
fi
echo "Repositorio: https://github.com/$repo"
systemctl list-timers personal-remote-update.timer --no-pager
