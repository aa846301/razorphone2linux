#!/bin/bash
# ==========================================================================
# Razer Phone 2 (aura) - Boot Image Creator
# ==========================================================================
# Creates an Android-compatible boot.img for the Razer Phone 2 using
# the compiled mainline Linux kernel and device tree blob.
#
# Usage:
#   bash 04-make-boot-image.sh
#   RAZER_BOOT_DISPLAY_MODE=console bash 04-make-boot-image.sh
#
# Prerequisites:
#   - Run 02-build-kernel.sh first (kernel + DTB needed)
#   - Run 03-build-rootfs.sh first (rootfs sparse image needed)
# ==========================================================================

set -euo pipefail

WORKDIR="${RAZER_WORKDIR:-$HOME/razorphone2linux}"
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
BOOT_IMG="$OUTPUT_DIR/boot.img"
WIN_OUTPUT_DIR="$PROJECT_DIR/output/$IMAGE_PROFILE"
PROJECT_MKBOOTIMG="$PROJECT_DIR/tools/mkbootimg.py"
LOCAL_MKBOOTIMG="$WORKDIR/mkbootimg-tool/mkbootimg.py"
KERNEL_RELEASE_FILE="$OUTPUT_DIR/kernel.release"
ROOTFS_RELEASE_FILE="$OUTPUT_DIR/rootfs.kernel-release"
KERNEL_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/kernel.modules-fingerprint"
ROOTFS_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/rootfs.modules-fingerprint"
ROOTFS_USERSPACE_FILE="$OUTPUT_DIR/userspace.profile"
KERNEL_FLAVOR_FILE="$OUTPUT_DIR/kernel.flavor"
DISPLAY_MODE="${RAZER_BOOT_DISPLAY_MODE:-normal}"

mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR"

# "helix" was the historical name of the normal mode (HelixScreen era).
[ "$DISPLAY_MODE" = "helix" ] && DISPLAY_MODE=normal
case "$DISPLAY_MODE" in
    normal|console) ;;
    *)
        echo "ERROR: RAZER_BOOT_DISPLAY_MODE must be 'normal' or 'console'."
        exit 2
        ;;
esac

echo "========================================"
echo " Razer Phone 2 - Boot Image Creator"
echo "========================================"
echo "Display mode: $DISPLAY_MODE"
echo "Image profile: $IMAGE_PROFILE"
echo "Userspace profile: $USERSPACE_PROFILE"

if [ -f "$PROJECT_MKBOOTIMG" ]; then
    MKBOOTIMG_CMD=(python3 "$PROJECT_MKBOOTIMG")
elif [ -f "$LOCAL_MKBOOTIMG" ]; then
    MKBOOTIMG_CMD=(python3 "$LOCAL_MKBOOTIMG")
elif command -v mkbootimg &>/dev/null; then
    MKBOOTIMG_CMD=(mkbootimg)
else
    echo "ERROR: mkbootimg tool not found. Expected $PROJECT_MKBOOTIMG, $LOCAL_MKBOOTIMG, or mkbootimg in PATH."
    exit 1
fi

if [ ! -s "$KERNEL_MODULES_FINGERPRINT_FILE" ] ||
        [ ! -s "$ROOTFS_MODULES_FINGERPRINT_FILE" ]; then
    echo "ERROR: kernel or rootfs module fingerprint is missing."
    echo "Run the kernel and rootfs build phases before packaging boot.img."
    exit 1
fi

KERNEL_MODULES_FINGERPRINT=$(tr -d '\r\n' < "$KERNEL_MODULES_FINGERPRINT_FILE")
ROOTFS_MODULES_FINGERPRINT=$(tr -d '\r\n' < "$ROOTFS_MODULES_FINGERPRINT_FILE")
if [ "$KERNEL_MODULES_FINGERPRINT" != "$ROOTFS_MODULES_FINGERPRINT" ]; then
    if [ "${RAZER_ALLOW_KERNEL_MISMATCH:-0}" = "1" ]; then
        echo "WARNING: boot and rootfs module fingerprints differ (override active)."
    else
        echo "ERROR: boot kernel and rootfs use different module binaries."
        echo "Refresh rootfs after rebuilding the kernel, even when kernel.release is unchanged."
        exit 1
    fi
fi

# -------------------------------------------------------
# Verify prerequisites
# -------------------------------------------------------
if [ ! -f "$OUTPUT_DIR/Image.gz" ]; then
    echo "ERROR: Kernel image not found at $OUTPUT_DIR/Image.gz"
    echo "Please run 02-build-kernel.sh first."
    exit 1
fi

if [ ! -f "$OUTPUT_DIR/sdm845-razer-aura.dtb" ]; then
    echo "ERROR: Device tree blob not found at $OUTPUT_DIR/sdm845-razer-aura.dtb"
    echo "Please run 02-build-kernel.sh first."
    exit 1
fi

if [ ! -f "$KERNEL_RELEASE_FILE" ]; then
    echo "ERROR: $KERNEL_RELEASE_FILE not found."
    echo "Run 02-build-kernel.sh first so boot/rootfs use the same kernel release."
    exit 1
fi

KERNEL_RELEASE=$(tr -d '\r\n' < "$KERNEL_RELEASE_FILE")
if [ ! -d "$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE" ]; then
    echo "ERROR: modules for kernel release '$KERNEL_RELEASE' are missing."
    echo "Expected: $OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE"
    exit 1
fi

if [ ! -f "$OUTPUT_DIR/rootfs-sparse.img" ] || [ ! -f "$ROOTFS_RELEASE_FILE" ]; then
    echo "ERROR: rootfs-sparse.img or rootfs.kernel-release is missing."
    echo "Run 03-build-rootfs.sh after 02-build-kernel.sh before packaging boot.img."
    exit 1
fi

ROOTFS_RELEASE=$(tr -d '\r\n' < "$ROOTFS_RELEASE_FILE")
if [ "$ROOTFS_RELEASE" != "$KERNEL_RELEASE" ]; then
    if [ "${RAZER_ALLOW_KERNEL_MISMATCH:-0}" = "1" ]; then
        # Legitimate for dual-kernel rootfs images (both module trees are
        # kept on disk so an older kernel remains a boot-only rollback).
        echo "WARNING: rootfs last refreshed for '$ROOTFS_RELEASE', boot kernel is '$KERNEL_RELEASE' (override active)."
    else
        echo "ERROR: rootfs modules were built for '$ROOTFS_RELEASE' but boot kernel is '$KERNEL_RELEASE'."
        echo "Rebuild in order: 02-build-kernel.sh -> 03-build-rootfs.sh -> 04-make-boot-image.sh"
        echo "Set RAZER_ALLOW_KERNEL_MISMATCH=1 only for dual-kernel rootfs images."
        exit 1
    fi
fi

if [ -f "$ROOTFS_USERSPACE_FILE" ]; then
    ROOTFS_USERSPACE=$(tr -d '\r\n' < "$ROOTFS_USERSPACE_FILE")
    if [ "$ROOTFS_USERSPACE" != "$USERSPACE_PROFILE" ]; then
        echo "ERROR: rootfs userspace profile is '$ROOTFS_USERSPACE' but boot packaging requested '$USERSPACE_PROFILE'."
        echo "Rebuild or refresh rootfs with matching RAZER_USERSPACE_PROFILE."
        exit 1
    fi
fi

# -------------------------------------------------------
# Step 1: Create combined Image.gz-dtb
# -------------------------------------------------------
echo "[1/4] Creating combined kernel + DTB image..."
cat "$OUTPUT_DIR/Image.gz" "$OUTPUT_DIR/sdm845-razer-aura.dtb" \
    > "$OUTPUT_DIR/Image.gz-dtb"
echo "  Created Image.gz-dtb ($(du -h "$OUTPUT_DIR/Image.gz-dtb" | cut -f1))"

# -------------------------------------------------------
# Step 2: Use Ubuntu initramfs-tools initrd from the rootfs
# -------------------------------------------------------
echo "[2/4] Validating Ubuntu initramfs-tools initrd..."

INITRD_VERSIONED="$OUTPUT_DIR/initrd.img-$KERNEL_RELEASE"
RAMDISK="$OUTPUT_DIR/initrd.img"

if [ ! -f "$INITRD_VERSIONED" ]; then
    echo "ERROR: expected initramfs-tools initrd missing:"
    echo "  $INITRD_VERSIONED"
    echo "Run scripts/03-refresh-rootfs.sh after scripts/02-build-kernel.sh."
    exit 1
fi

cp -f "$INITRD_VERSIONED" "$RAMDISK"

if [ ! -s "$RAMDISK" ]; then
    echo "ERROR: initrd is empty: $RAMDISK"
    exit 1
fi

if command -v lsinitramfs >/dev/null 2>&1; then
    INITRD_LIST="$OUTPUT_DIR/initrd-files.txt"
    lsinitramfs "$RAMDISK" > "$INITRD_LIST"
    grep -qx 'init' "$INITRD_LIST" || {
        echo "ERROR: initrd does not contain /init."
        exit 1
    }
    if grep -q 'initramfs/init-boot.sh' "$INITRD_LIST"; then
        echo "ERROR: normal boot initrd unexpectedly contains the legacy custom initramfs."
        exit 1
    fi
    if ! grep -Eq '(^usr/lib/udev/|^lib/systemd/systemd-udevd$|^usr/lib/systemd/systemd-udevd$|^sbin/udevd$)' "$INITRD_LIST"; then
        echo "ERROR: initrd does not appear to contain udev; by-partlabel root discovery may fail."
        exit 1
    fi
else
    echo "WARNING: lsinitramfs not available; initrd content validation skipped."
fi

echo "  Using initrd: $RAMDISK ($(du -h "$RAMDISK" | cut -f1))"

# -------------------------------------------------------
# Step 3: Create boot.img
# -------------------------------------------------------
echo "[3/4] Creating boot.img..."

# Kernel command line for mainline Linux on Razer Phone 2.
# Root selection is handled inside initramfs-tools via
# /etc/initramfs-tools/conf.d/razer-root and
# /etc/initramfs-tools/scripts/local-top/razer-root. This avoids fighting
# Android bootloaders that append their stock root=/dev/dm-* argument.
# The initramfs root value must be a bootloader-compatible /dev path such as
# /dev/disk/by-partlabel/userdata; do not pass PARTLABEL=userdata to the
# kernel's early VFS root parser.
# Keep the final ttyMSM0 console for the SDM845 display race workaround.
# module_blacklist=ipa: kernel-level guard — loading IPA on this rootfs
# hard-resets the SoC ~30s later even with a healthy modem stack
# (2026-07-03). WiFi works fully without it; see razer-wifi-ready.sh.
CMDLINE_COMMON="earlycon=msm_geni_serial,0xA84000 console=ttyMSM0,115200n8 clk_ignore_unused pd_ignore_unused fw_devlink=permissive rootfstype=ext4 rw loglevel=7 pcie_aspm=off module_blacklist=ipa init=/usr/lib/systemd/systemd"
case "$DISPLAY_MODE" in
    normal)
        # Normal boot (UI endgame: Home Assistant dashboard).
        # Boot-log policy: kernel + initramfs messages stay visible on the
        # panel (console=tty0 last, loglevel=6, no quiet). Once rootfs is up,
        # razer-quiet-console.service (gated on razer_quiet_console below)
        # drops the console loglevel so the screen goes quiet; systemd status
        # lines are suppressed throughout since rootfs output is not needed.
        CMDLINE="$CMDLINE_COMMON vt.global_cursor_default=0 razer_fb_clear=0 console=tty0 loglevel=6 systemd.show_status=false rd.systemd.show_status=false razer_quiet_console"
        if [ "$USERSPACE_PROFILE" = "none" ]; then
            CMDLINE="$CMDLINE razer_panel_idle_blank"
        fi
        ;;
    console)
        # Screen-debug boots must keep tty0 last so initramfs-tools and
        # systemd status messages are visible on the phone panel instead of
        # disappearing into the UART console.
        CMDLINE="$CMDLINE_COMMON vt.global_cursor_default=1 razer_fb_clear=0 console=tty0"
        ;;
esac

if [ -n "${RAZER_EXTRA_CMDLINE:-}" ]; then
    CMDLINE="$CMDLINE $RAZER_EXTRA_CMDLINE"
fi

"${MKBOOTIMG_CMD[@]}" \
    --kernel "$OUTPUT_DIR/Image.gz-dtb" \
    --ramdisk "$RAMDISK" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --header_version 1 \
    --cmdline "$CMDLINE" \
    --os_version 14.0.0 \
    --os_patch_level 2024-01 \
    -o "$BOOT_IMG"

echo "  Created boot.img ($(du -h "$BOOT_IMG" | cut -f1))"

# -------------------------------------------------------
# Step 4: Create disabled-verification vbmeta
# -------------------------------------------------------
echo "[4/4] Creating vbmeta with verification disabled..."

# Create a minimal vbmeta that disables AVB verification
# This allows booting unsigned images
python3 -c "
import struct

# AVB vbmeta header layout (see external/avb/libavb/avb_vbmeta_image.h):
#   Offset 0:    magic 'AVB0' (4 bytes)
#   Offset 4:    required_libavb_version_major (4 bytes, big-endian)
#   Offset 8:    required_libavb_version_minor (4 bytes, big-endian)
#   Offset 12:   authentication_data_block_size (8 bytes)
#   Offset 20:   auxiliary_data_block_size (8 bytes)
#   Offset 28:   algorithm_type (4 bytes) = 0 (none)
#   Offset 32-119: hash/signature offsets (zeroed = no auth)
#   Offset 120:  flags (4 bytes, big-endian)
#      bit 0 = AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED
#      bit 1 = AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED

data = bytearray(4096)
# Magic
data[0:4] = b'AVB0'
# Major version = 1
struct.pack_into('>I', data, 4, 1)
# Minor version = 1
struct.pack_into('>I', data, 8, 1)
# Flags = 3 (disable both hashtree and verification)
struct.pack_into('>I', data, 120, 3)

with open('$OUTPUT_DIR/vbmeta_disabled.img', 'wb') as f:
    f.write(bytes(data))
print('  Created vbmeta_disabled.img')
" 2>/dev/null || {
    # Fallback: create empty vbmeta with avbtool if available
    echo "  WARNING: Could not create vbmeta. Create manually or use stock vbmeta with --disable-verity."
}

mkdir -p "$WIN_OUTPUT_DIR"
cp -f "$BOOT_IMG" "$WIN_OUTPUT_DIR/boot.img"
cp -f "$RAMDISK" "$WIN_OUTPUT_DIR/$(basename "$RAMDISK")"
cp -f "$INITRD_VERSIONED" "$WIN_OUTPUT_DIR/$(basename "$INITRD_VERSIONED")"
cp -f "$KERNEL_RELEASE_FILE" "$WIN_OUTPUT_DIR/kernel.release"
cp -f "$ROOTFS_RELEASE_FILE" "$WIN_OUTPUT_DIR/rootfs.kernel-release"
cp -f "$KERNEL_MODULES_FINGERPRINT_FILE" "$WIN_OUTPUT_DIR/kernel.modules-fingerprint"
cp -f "$ROOTFS_MODULES_FINGERPRINT_FILE" "$WIN_OUTPUT_DIR/rootfs.modules-fingerprint"
if [ -f "$ROOTFS_USERSPACE_FILE" ]; then
    cp -f "$ROOTFS_USERSPACE_FILE" "$WIN_OUTPUT_DIR/userspace.profile"
fi
if [ -f "$OUTPUT_DIR/vbmeta_disabled.img" ]; then
    cp -f "$OUTPUT_DIR/vbmeta_disabled.img" "$WIN_OUTPUT_DIR/vbmeta_disabled.img"
fi

echo ""
echo "========================================"
echo " Boot image creation complete!"
echo "========================================"
echo ""
echo "Output files:"
echo "  $BOOT_IMG"
echo "  $OUTPUT_DIR/rootfs-sparse.img"
echo "  $OUTPUT_DIR/vbmeta_disabled.img (one-time AVB setup helper; do not reflash if already installed)"
echo ""
echo "========================================"
echo " FLASHING INSTRUCTIONS"
echo "========================================"
echo ""
echo "1. Enable Developer Options on Razer Phone 2"
echo "   Settings > About Phone > Tap Build Number 7 times"
echo ""
echo "2. Enable OEM Unlocking"
echo "   Settings > Developer Options > Enable OEM unlocking"
echo ""
echo "3. Reboot to bootloader"
echo "   adb reboot bootloader"
echo ""
echo "4. Unlock bootloader (WARNING: This will wipe all data!)"
echo "   fastboot oem unlock"
echo ""
echo "5. Flash boot image to both slots and flash rootfs"
echo '   fastboot flash boot_a output\boot.img && fastboot flash boot_b output\boot.img && fastboot flash userdata output\rootfs-sparse.img && fastboot reboot'
echo ""
echo "6. Disable verified boot only once, if this device has not already had disabled vbmeta flashed."
echo "   This is intentionally not part of the routine flash command."
echo ""
echo "7. First boot will be slow (resizing filesystem)."
echo "   Normal boot uses Ubuntu initramfs-tools. Use WiFi SSH after NetworkManager comes up."
echo ""
echo "Default credentials:  klipper / klipper"
echo "Change immediately after first boot!"
