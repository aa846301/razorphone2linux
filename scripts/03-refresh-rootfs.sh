#!/bin/bash
# ==========================================================================
# Razer Phone 2 (aura) - Existing Rootfs Refresher
# ==========================================================================
# Validation-phase updater for an existing rootfs.img. This intentionally does
# not run debootstrap, apt, pip, or git clone.
#
# Use this when changing kernel modules, firmware blobs, DTS-adjacent runtime
# config, or USB gadget config. Use 03-build-rootfs.sh only when the base
# Ubuntu package set changes.
# ==========================================================================

set -euo pipefail

if [ -n "${RAZER_WORKDIR:-}" ]; then
    WORKDIR="$RAZER_WORKDIR"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    WORKDIR="$(eval echo "~$SUDO_USER")/razorphone2linux"
else
    WORKDIR="$HOME/razorphone2linux"
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/config/build.env"
IMAGE_PROFILE="${RAZER_IMAGE_PROFILE:-base}"
case "$IMAGE_PROFILE" in
    base) ;;
    *) echo "ERROR: RAZER_IMAGE_PROFILE must be base."; exit 2 ;;
esac
USERSPACE_PROFILE="${RAZER_USERSPACE_PROFILE:-none}"
case "$USERSPACE_PROFILE" in
    none|ha|3dprinter) ;;
    *) echo "ERROR: RAZER_USERSPACE_PROFILE must be none, ha, or 3dprinter."; exit 2 ;;
esac
OUTPUT_DIR="$WORKDIR/output/$IMAGE_PROFILE"
WIN_OUTPUT_DIR="$PROJECT_DIR/output/$IMAGE_PROFILE"
ROOTFS_IMG="${ROOTFS_IMG:-$OUTPUT_DIR/rootfs.img}"
WIN_ROOTFS_IMG="$WIN_OUTPUT_DIR/rootfs.img"
SPARSE_IMG="$OUTPUT_DIR/rootfs-sparse.img"
MOUNT_DIR="$WORKDIR/rootfs/refresh-mnt-$IMAGE_PROFILE"
FIRMWARE_DIR="${FIRMWARE_DIR:-$PROJECT_DIR/firmware}"
ROOTFS_PACKAGES_DIR="${ROOTFS_PACKAGES_DIR:-$PROJECT_DIR/rootfs-packages/arm64}"
ROOTFS_BINARIES_DIR="${ROOTFS_BINARIES_DIR:-$PROJECT_DIR/rootfs-binaries/arm64}"
KERNEL_RELEASE_FILE="$OUTPUT_DIR/kernel.release"
ROOTFS_RELEASE_FILE="$OUTPUT_DIR/rootfs.kernel-release"
KERNEL_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/kernel.modules-fingerprint"
ROOTFS_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/rootfs.modules-fingerprint"

mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR"

cleanup_mounts() {
    if mountpoint -q "$MOUNT_DIR/dev/pts"; then umount "$MOUNT_DIR/dev/pts" || true; fi
    if mountpoint -q "$MOUNT_DIR/proc"; then umount "$MOUNT_DIR/proc" || true; fi
    if mountpoint -q "$MOUNT_DIR/sys"; then umount "$MOUNT_DIR/sys" || true; fi
    if mountpoint -q "$MOUNT_DIR/dev"; then umount "$MOUNT_DIR/dev" || true; fi
    if mountpoint -q "$MOUNT_DIR"; then umount "$MOUNT_DIR" || true; fi
}

copy_tree() {
    local src="$1"
    local dst="$2"

    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src"/ "$dst"/
    else
        rm -rf "$dst"
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

echo "========================================"
echo " Razer Phone 2 - Rootfs Refresh"
echo "========================================"
echo "Rootfs image: $ROOTFS_IMG"
echo "Image profile: $IMAGE_PROFILE"
echo "Userspace:     $USERSPACE_PROFILE"
echo "Workdir:      $WORKDIR"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

trap cleanup_mounts EXIT

"$PROJECT_DIR/scripts/register-binfmt.sh"
mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR" "$MOUNT_DIR"

if [ ! -f "$ROOTFS_IMG" ]; then
    if [ -f "$WIN_ROOTFS_IMG" ]; then
        echo "  Native WSL rootfs missing; copying from $WIN_ROOTFS_IMG"
        cp -f "$WIN_ROOTFS_IMG" "$ROOTFS_IMG"
    else
        echo "ERROR: rootfs.img not found at $ROOTFS_IMG or $WIN_ROOTFS_IMG"
        echo "Run scripts/03-build-rootfs.sh once to create the base image."
        exit 1
    fi
fi

if [ -f "$OUTPUT_DIR/userspace.profile" ]; then
    EXISTING_USERSPACE_PROFILE=$(tr -d '\r\n' < "$OUTPUT_DIR/userspace.profile")
    if [ "$EXISTING_USERSPACE_PROFILE" != "$USERSPACE_PROFILE" ]; then
        echo "ERROR: existing rootfs profile is '$EXISTING_USERSPACE_PROFILE' but refresh requested '$USERSPACE_PROFILE'."
        echo "Run scripts/03-build-rootfs.sh, or build-all.sh all, when changing userspace profiles."
        exit 1
    fi
else
    echo "$USERSPACE_PROFILE" > "$OUTPUT_DIR/userspace.profile"
fi

cleanup_mounts
mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"

install -D -m 0755 /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/qemu-aarch64-static"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/usb-gadget-setup.sh" \
    "$MOUNT_DIR/usr/local/bin/usb-gadget-setup.sh"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/apply-runtime-config.sh" \
    "$MOUNT_DIR/tmp/apply-runtime-config.sh"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-wifi-ready.sh" \
    "$MOUNT_DIR/usr/local/sbin/razer-wifi-ready"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-root.conf" \
    "$MOUNT_DIR/etc/initramfs-tools/conf.d/razer-root"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-root-local-top" \
    "$MOUNT_DIR/etc/initramfs-tools/scripts/local-top/razer-root"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-gpu-firmware" \
    "$MOUNT_DIR/etc/initramfs-tools/hooks/razer-gpu-firmware"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-quiet-console.service" \
    "$MOUNT_DIR/etc/systemd/system/razer-quiet-console.service"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-charge-limits.sh" \
    "$MOUNT_DIR/usr/local/sbin/razer-charge-limits"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-charge-limits.service" \
    "$MOUNT_DIR/etc/systemd/system/razer-charge-limits.service"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-idle-blank.sh" \
    "$MOUNT_DIR/usr/local/sbin/razer-panel-idle-blank"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-idle-blank.service" \
    "$MOUNT_DIR/etc/systemd/system/razer-panel-idle-blank.service"
mkdir -p "$MOUNT_DIR/etc/systemd/system/basic.target.wants"
ln -sf ../razer-quiet-console.service \
    "$MOUNT_DIR/etc/systemd/system/basic.target.wants/razer-quiet-console.service"
mkdir -p "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf ../razer-charge-limits.service \
    "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/razer-charge-limits.service"
ln -sf ../razer-panel-idle-blank.service \
    "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/razer-panel-idle-blank.service"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-colortest.py" \
    "$MOUNT_DIR/usr/local/sbin/razer-panel-colortest"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-colortest.service" \
    "$MOUNT_DIR/etc/systemd/system/razer-panel-colortest.service"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-autocolortest.service" \
    "$MOUNT_DIR/etc/systemd/system/razer-panel-autocolortest.service"
mkdir -p "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf ../razer-panel-autocolortest.service \
    "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/razer-panel-autocolortest.service"
if [ -f "$PROJECT_DIR/config/device.env" ]; then
    install -D -m 0600 \
        "$PROJECT_DIR/config/device.env" \
        "$MOUNT_DIR/etc/razerphone2linux/device.env"
fi

echo "[1/5] Syncing firmware blobs and repo-controlled packages..."
if [ ! -f "$FIRMWARE_DIR/qcom/sdm845/Razer/aura/mba.mbn" ] && [ "${RAZER_ALLOW_MISSING_FIRMWARE:-0}" != "1" ]; then
    echo "ERROR: $FIRMWARE_DIR/qcom/sdm845/Razer/aura/mba.mbn is missing."
    echo "firmware/ is gitignored; copy it from an existing checkout first, or"
    echo "set RAZER_ALLOW_MISSING_FIRMWARE=1 to refresh a no-WiFi image."
    exit 1
fi
if [ -d "$FIRMWARE_DIR" ] && [ "$(ls -A "$FIRMWARE_DIR" 2>/dev/null)" ]; then
    mkdir -p "$MOUNT_DIR/usr/lib/firmware"
    cp -a "$FIRMWARE_DIR"/. "$MOUNT_DIR/usr/lib/firmware/"
else
    echo "  NOTE: $FIRMWARE_DIR is empty; firmware sync skipped."
fi

echo "  Installing repo-controlled ARM64 rootfs packages..."
if [ -f "$ROOTFS_PACKAGES_DIR/tqftpserv_1.0-5_arm64.deb" ]; then
    dpkg-deb -x "$ROOTFS_PACKAGES_DIR/tqftpserv_1.0-5_arm64.deb" "$MOUNT_DIR"
else
    echo "  WARNING: tqftpserv package missing from $ROOTFS_PACKAGES_DIR"
fi

echo "  Installing repo-controlled ARM64 binaries..."
if [ -f "$ROOTFS_BINARIES_DIR/tqftpserv" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/tqftpserv" \
        "$MOUNT_DIR/usr/bin/tqftpserv"
else
    echo "  WARNING: patched tqftpserv missing from $ROOTFS_BINARIES_DIR"
fi

if [ -f "$ROOTFS_BINARIES_DIR/rmtfs-razer-test" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/rmtfs-razer-test" \
        "$MOUNT_DIR/usr/local/bin/rmtfs-razer-test"
else
    echo "  WARNING: rmtfs-razer-test missing from $ROOTFS_BINARIES_DIR"
fi

if [ -f "$ROOTFS_BINARIES_DIR/pd-mapper" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/pd-mapper" \
        "$MOUNT_DIR/usr/local/bin/pd-mapper"
else
    echo "  WARNING: userspace pd-mapper missing from $ROOTFS_BINARIES_DIR"
fi

echo "[2/5] Applying runtime config overlay..."
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
mount --bind /sys "$MOUNT_DIR/sys"
chroot "$MOUNT_DIR" /usr/bin/env \
    RAZER_MSS_DIAG_MANUAL="${RAZER_MSS_DIAG_MANUAL:-0}" \
    /tmp/apply-runtime-config.sh

echo "[3/5] Syncing kernel modules..."
if [ -f "$KERNEL_RELEASE_FILE" ]; then
    KERNEL_VERSION=$(tr -d '\r\n' < "$KERNEL_RELEASE_FILE")
    MODULE_SRC="$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_VERSION"

    if [ -d "$MODULE_SRC" ]; then
        copy_tree "$MODULE_SRC" "$MOUNT_DIR/lib/modules/$KERNEL_VERSION"
        chroot "$MOUNT_DIR" depmod -a "$KERNEL_VERSION"
        if ! chroot "$MOUNT_DIR" test -x /usr/sbin/update-initramfs; then
            echo "ERROR: update-initramfs is missing in the rootfs."
            echo "Run scripts/03-build-rootfs.sh once to rebuild the base image with initramfs-tools."
            exit 1
        fi
        mkdir -p "$MOUNT_DIR/boot"
        if [ -f "$OUTPUT_DIR/config-$KERNEL_VERSION" ]; then
            cp -f "$OUTPUT_DIR/config-$KERNEL_VERSION" "$MOUNT_DIR/boot/config-$KERNEL_VERSION"
        elif [ -f "$OUTPUT_DIR/kernel.config" ]; then
            cp -f "$OUTPUT_DIR/kernel.config" "$MOUNT_DIR/boot/config-$KERNEL_VERSION"
        fi
        if chroot "$MOUNT_DIR" test -f "/boot/initrd.img-$KERNEL_VERSION"; then
            chroot "$MOUNT_DIR" update-initramfs -u -k "$KERNEL_VERSION"
        else
            chroot "$MOUNT_DIR" update-initramfs -c -k "$KERNEL_VERSION"
        fi
        INITRD_SRC="$MOUNT_DIR/boot/initrd.img-$KERNEL_VERSION"
        if [ ! -s "$INITRD_SRC" ]; then
            echo "ERROR: initramfs was not generated at /boot/initrd.img-$KERNEL_VERSION"
            exit 1
        fi
        cp -f "$INITRD_SRC" "$OUTPUT_DIR/initrd.img-$KERNEL_VERSION"
        cp -f "$INITRD_SRC" "$OUTPUT_DIR/initrd.img"
        echo "$KERNEL_VERSION" > "$ROOTFS_RELEASE_FILE"
        if [ ! -s "$KERNEL_MODULES_FINGERPRINT_FILE" ]; then
            echo "ERROR: kernel module fingerprint is missing: $KERNEL_MODULES_FINGERPRINT_FILE"
            exit 1
        fi
        install -D -m 0644 "$KERNEL_MODULES_FINGERPRINT_FILE" \
            "$MOUNT_DIR/etc/razerphone2linux/kernel.modules-fingerprint"
        cp -f "$KERNEL_MODULES_FINGERPRINT_FILE" "$ROOTFS_MODULES_FINGERPRINT_FILE"
        echo "  Installed modules for $KERNEL_VERSION"
        echo "  Generated initramfs-tools initrd for $KERNEL_VERSION"
    else
        echo "ERROR: modules for kernel release '$KERNEL_VERSION' are missing:"
        echo "  $MODULE_SRC"
        exit 1
    fi
else
    echo "  No kernel.release found; leaving existing modules unchanged."
fi

echo "[4/5] Cleaning temporary files..."
chroot "$MOUNT_DIR" bash -c "
    rm -f /tmp/apply-runtime-config.sh
    rm -rf /tmp/* /var/tmp/*
    rm -rf /home/klipper/.cache/pip
    rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
    find /var/log -type f -exec truncate -s 0 {} +
" || true

cleanup_mounts

echo "[5/5] Compacting and regenerating sparse image..."
if command -v e2fsck >/dev/null 2>&1; then
    # e2fsck exits 1/2 when it corrected something; only >2 is a real error.
    e2fsck -fy "$ROOTFS_IMG" || {
        rc=$?
        [ "$rc" -le 2 ] || { echo "ERROR: e2fsck failed with $rc"; exit 1; }
    }
fi
if command -v zerofree >/dev/null 2>&1; then
    zerofree "$ROOTFS_IMG"
else
    echo "  WARNING: zerofree is not installed; rootfs-sparse.img may include stale ext4 free blocks."
fi
img2simg "$ROOTFS_IMG" "$SPARSE_IMG"

cp -f "$ROOTFS_IMG" "$WIN_ROOTFS_IMG"
cp -f "$SPARSE_IMG" "$WIN_OUTPUT_DIR/rootfs-sparse.img"
if [ -f "$ROOTFS_RELEASE_FILE" ]; then
    cp -f "$ROOTFS_RELEASE_FILE" "$WIN_OUTPUT_DIR/rootfs.kernel-release"
fi
if [ -f "$ROOTFS_MODULES_FINGERPRINT_FILE" ]; then
    cp -f "$ROOTFS_MODULES_FINGERPRINT_FILE" "$WIN_OUTPUT_DIR/rootfs.modules-fingerprint"
fi
cp -f "$OUTPUT_DIR/userspace.profile" "$WIN_OUTPUT_DIR/userspace.profile"
if [ -n "${KERNEL_VERSION:-}" ] && [ -f "$OUTPUT_DIR/initrd.img-$KERNEL_VERSION" ]; then
    cp -f "$OUTPUT_DIR/initrd.img-$KERNEL_VERSION" "$WIN_OUTPUT_DIR/initrd.img-$KERNEL_VERSION"
    cp -f "$OUTPUT_DIR/initrd.img" "$WIN_OUTPUT_DIR/initrd.img"
fi
if [ -f "$KERNEL_RELEASE_FILE" ]; then
    cp -f "$KERNEL_RELEASE_FILE" "$WIN_OUTPUT_DIR/kernel.release"
fi

echo ""
echo "Rootfs refresh complete:"
echo "  Raw image:    $WIN_ROOTFS_IMG"
echo "  Sparse image: $WIN_OUTPUT_DIR/rootfs-sparse.img"
