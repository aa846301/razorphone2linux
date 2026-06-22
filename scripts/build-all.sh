#!/bin/bash
# Canonical WSL build orchestrator for Razer Phone 2.
#
# Usage:
#   bash scripts/build-all.sh all       # kernel + rootfs + boot
#   bash scripts/build-all.sh validate-boot # kernel/DTB + boot, no rootfs refresh
#   bash scripts/build-all.sh kernel
#   bash scripts/build-all.sh rootfs
#   bash scripts/build-all.sh refresh-rootfs
#   bash scripts/build-all.sh boot
#
# Run from the Windows repo path mounted in WSL, or from anywhere with
# WIN_REPO=/mnt/c/repo/razorphone2linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIN_REPO="${WIN_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAZER_WORKDIR="${RAZER_WORKDIR:-$HOME/razorphone2linux}"
RAZER_IMAGE_PROFILE="${RAZER_IMAGE_PROFILE:-printer}"
RAZER_UBUNTU_MIRROR="${RAZER_UBUNTU_MIRROR:-https://ports.ubuntu.com/ubuntu-ports}"
MODE="${1:-all}"
SUDO_READY=0

if [ ! -d "$WIN_REPO/scripts" ]; then
    echo "ERROR: WIN_REPO does not point at the project repo: $WIN_REPO"
    exit 1
fi

prepare_sudo() {
    if [ "$EUID" -eq 0 ]; then
        return
    fi

    if sudo -n true 2>/dev/null; then
        SUDO_READY=1
        return
    fi

    if [ -n "${WSL_SUDO_PASSWORD:-}" ]; then
        if ! printf '%s\n' "$WSL_SUDO_PASSWORD" | sudo -S -v; then
            echo "ERROR: WSL_SUDO_PASSWORD did not authorize sudo."
            exit 1
        fi
        SUDO_READY=1
        return
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        echo "Rootfs work requires sudo. Authorize it now, before the long build starts."
        sudo -v
        SUDO_READY=1
        return
    fi

    cat >&2 <<'EOF'
ERROR: this build mode requires rootfs access, but non-interactive sudo is not ready.
From Windows/Codex Desktop use:
  powershell -ExecutionPolicy Bypass -File scripts/build-all-wsl.ps1 validate
The wrapper builds the kernel as the normal WSL user and runs only the rootfs
phase through `wsl -u root`, so it cannot stall on a sudo password prompt.
EOF
    exit 1
}

run_rootfs() {
    if [ "$EUID" -eq 0 ]; then
        bash "$WIN_REPO/scripts/03-build-rootfs.sh"
    else
        sudo -n \
            RAZER_WORKDIR="$RAZER_WORKDIR" \
            RAZER_IMAGE_PROFILE="$RAZER_IMAGE_PROFILE" \
            RAZER_UBUNTU_MIRROR="$RAZER_UBUNTU_MIRROR" \
            RAZER_MSS_DIAG_MANUAL="${RAZER_MSS_DIAG_MANUAL:-0}" \
            bash "$WIN_REPO/scripts/03-build-rootfs.sh"
    fi
}

run_refresh_rootfs() {
    if [ "$EUID" -eq 0 ]; then
        bash "$WIN_REPO/scripts/03-refresh-rootfs.sh"
    else
        sudo -n \
            RAZER_WORKDIR="$RAZER_WORKDIR" \
            RAZER_IMAGE_PROFILE="$RAZER_IMAGE_PROFILE" \
            RAZER_UBUNTU_MIRROR="$RAZER_UBUNTU_MIRROR" \
            RAZER_MSS_DIAG_MANUAL="${RAZER_MSS_DIAG_MANUAL:-0}" \
            bash "$WIN_REPO/scripts/03-refresh-rootfs.sh"
    fi
}

case "$MODE" in
    all|rootfs|refresh-rootfs|validate)
        prepare_sudo
        ;;
esac

case "$MODE" in
    all)
        bash "$WIN_REPO/scripts/02-build-kernel.sh"
        run_rootfs
        bash "$WIN_REPO/scripts/04-make-boot-image.sh"
        ;;
    kernel)
        bash "$WIN_REPO/scripts/02-build-kernel.sh"
        ;;
    rootfs)
        run_rootfs
        ;;
    refresh-rootfs)
        run_refresh_rootfs
        ;;
    validate)
        bash "$WIN_REPO/scripts/02-build-kernel.sh"
        run_refresh_rootfs
        bash "$WIN_REPO/scripts/04-make-boot-image.sh"
        ;;
    validate-boot)
        bash "$WIN_REPO/scripts/02-build-kernel.sh"
        bash "$WIN_REPO/scripts/04-make-boot-image.sh"
        ;;
    boot)
        bash "$WIN_REPO/scripts/04-make-boot-image.sh"
        ;;
    *)
        echo "Usage: bash scripts/build-all.sh [all|kernel|rootfs|refresh-rootfs|validate|validate-boot|boot]"
        exit 2
        ;;
esac
