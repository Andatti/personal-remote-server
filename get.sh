#!/usr/bin/env bash
# Parse the piped script before reconnecting input to the terminal.
install_personal_remote() (
    set -Eeuo pipefail
    if [[ ${1:-} == --help ]]; then
        echo 'Usage: bash get.sh [--user ACCOUNT] [OWNER/REPOSITORY]'
        return
    fi
    if [[ ! -t 0 ]]; then
        exec </dev/tty
    fi
    umask 077
    installer=$(mktemp)
    trap 'rm -f -- "$installer"' EXIT
    curl --fail --silent --show-error --location --retry 2 \
        https://raw.githubusercontent.com/Andatti/personal-remote-server/main/setup.sh \
        --output "$installer"
    bash "$installer" "$@"
)
install_personal_remote "$@"
