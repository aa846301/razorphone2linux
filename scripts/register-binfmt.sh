#!/bin/bash
# Register aarch64 binfmt_misc for qemu in WSL.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: register-binfmt.sh must run as root"
    exit 1
fi

HOST_ARCH="$(uname -m)"
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true

case "$HOST_ARCH" in
    aarch64|arm64)
        # Native ARM64 hosts run the target rootfs directly. Registering an
        # aarch64 binfmt handler here can hijack host binaries, including the
        # GitHub Actions Node runtime used by post-job cleanup.
        if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
            echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || true
        fi
        echo "BINFMT_NATIVE_ARM64"
        exit 0
        ;;
esac

if [ ! -x /usr/bin/qemu-aarch64-static ]; then
    echo "ERROR: /usr/bin/qemu-aarch64-static not found"
    echo "Install qemu-user-static first."
    exit 1
fi

if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    printf '%s' ':qemu-aarch64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:CF' \
        > /proc/sys/fs/binfmt_misc/register
fi

cat /proc/sys/fs/binfmt_misc/qemu-aarch64
echo "BINFMT_OK"
