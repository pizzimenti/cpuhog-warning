#!/usr/bin/env bash
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="/usr/local/bin/cpuhog-warning"
USER_SERVICE_NAME="cpuhog-warning.service"

if [[ $EUID -ne 0 ]]; then
    exec pkexec bash "$SELF" "$@"
fi

run_as_user() {
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        sudo -u "#${PKEXEC_UID}" XDG_RUNTIME_DIR="/run/user/${PKEXEC_UID}" HOME="$HOME" "$@"
    else
        "$@"
    fi
}

if [[ -n "${PKEXEC_UID:-}" ]]; then
    HOME="$(getent passwd "$PKEXEC_UID" | cut -d: -f6)"
    export HOME
fi

install -Dm755 "$ROOT_DIR/cpuhog-warning.sh" "$TARGET"

USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
USER_SERVICE_PATH="$USER_SYSTEMD_DIR/$USER_SERVICE_NAME"

install -d -m755 "$USER_SYSTEMD_DIR"
install -Dm644 "$ROOT_DIR/$USER_SERVICE_NAME" "$USER_SERVICE_PATH"

run_as_user systemctl --user daemon-reload
run_as_user systemctl --user enable --now "$USER_SERVICE_NAME"

printf 'Installed:\n'
printf '  %s\n' "$TARGET"
printf '  %s\n' "$USER_SERVICE_PATH"
printf '\nUser service status:\n'
run_as_user systemctl --user status "$USER_SERVICE_NAME" --no-pager
printf '\nView logs: journalctl --user -u %s -f\n' "$USER_SERVICE_NAME"
