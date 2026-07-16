#!/bin/bash
# ==========================================================================
# Razer Phone 2 (aura) - Ubuntu Noble ARM64 Rootfs Builder
# ==========================================================================
# Creates an Ubuntu 24.04 (Noble) ARM64 root filesystem image configured
# for the Razer Phone 2 running mainline Linux (Home Assistant hub target).
#
# Usage: sudo bash 03-build-rootfs.sh
# Must be run as root (sudo) for debootstrap and chroot operations.
#
# Prerequisites:
#   - Run 01-setup-environment.sh first
#   - Run 02-build-kernel.sh first (modules needed)
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
ROOTFS_DIR="$WORKDIR/rootfs"
ROOTFS_IMG="$ROOTFS_DIR/rootfs-noble-$IMAGE_PROFILE.img"
CHROOT_DIR="$ROOTFS_DIR/chroot-$IMAGE_PROFILE"
FIRMWARE_DIR="${FIRMWARE_DIR:-$PROJECT_DIR/firmware}"
ROOTFS_PACKAGES_DIR="${ROOTFS_PACKAGES_DIR:-$PROJECT_DIR/rootfs-packages/arm64}"
ROOTFS_BINARIES_DIR="${ROOTFS_BINARIES_DIR:-$PROJECT_DIR/rootfs-binaries/arm64}"
WIN_OUTPUT_DIR="$PROJECT_DIR/output/$IMAGE_PROFILE"
OUTPUT_ROOTFS_IMG="$OUTPUT_DIR/rootfs.img"
BASE_ONLY="${RAZER_ROOTFS_BASE_ONLY:-0}"

mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR"

cleanup_mounts() {
    if mountpoint -q "$CHROOT_DIR/var/cache/razer-pip"; then umount "$CHROOT_DIR/var/cache/razer-pip" || true; fi
    if mountpoint -q "$CHROOT_DIR/var/cache/apt/archives"; then umount "$CHROOT_DIR/var/cache/apt/archives" || true; fi
    if mountpoint -q "$CHROOT_DIR/dev/pts"; then umount "$CHROOT_DIR/dev/pts" || true; fi
    if mountpoint -q "$CHROOT_DIR/proc"; then umount "$CHROOT_DIR/proc" || true; fi
    if mountpoint -q "$CHROOT_DIR/sys"; then umount "$CHROOT_DIR/sys" || true; fi
    if mountpoint -q "$CHROOT_DIR/dev"; then umount "$CHROOT_DIR/dev" || true; fi
    if mountpoint -q "$CHROOT_DIR"; then umount "$CHROOT_DIR" || true; fi
}

# Kernel version. Prefer the release written by 02-build-kernel.sh so rootfs
# and boot packaging never silently consume different module directories.
KERNEL_RELEASE_FILE="$OUTPUT_DIR/kernel.release"
KERNEL_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/kernel.modules-fingerprint"
ROOTFS_MODULES_FINGERPRINT_FILE="$OUTPUT_DIR/rootfs.modules-fingerprint"
KERNEL_VERSION="deferred"
if [ "$BASE_ONLY" != "1" ]; then
    if [ -f "$KERNEL_RELEASE_FILE" ]; then
        KERNEL_VERSION=$(tr -d '\r\n' < "$KERNEL_RELEASE_FILE")
    else
        KERNEL_VERSION=$(ls "$OUTPUT_DIR/modules_install/lib/modules/" 2>/dev/null | head -1)
    fi
    if [ -z "$KERNEL_VERSION" ]; then
        echo "ERROR: No kernel modules found in $OUTPUT_DIR/modules_install/"
        echo "Please run 02-build-kernel.sh first."
        exit 1
    fi

    if [ ! -d "$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_VERSION" ]; then
        echo "ERROR: kernel.release says '$KERNEL_VERSION' but modules are missing:"
        echo "  $OUTPUT_DIR/modules_install/lib/modules/$KERNEL_VERSION"
        echo "Run 02-build-kernel.sh and then rebuild rootfs with the same output directory."
        exit 1
    fi
fi

HOSTNAME="razer-aura"
USERNAME="klipper"
# Default password - CHANGE THIS after first boot!
USER_PASSWORD="klipper"
if [ "$USERSPACE_PROFILE" = "3dprinter" ]; then
    ROOTFS_SIZE_GB=6
else
    ROOTFS_SIZE_GB=4
fi
MIRROR="${RAZER_UBUNTU_MIRROR:-https://ports.ubuntu.com/ubuntu-ports}"
DEBOOTSTRAP_CACHE_DIR="$WORKDIR/cache/debootstrap"
APT_CACHE_DIR="$WORKDIR/cache/apt-archives"
PIP_CACHE_DIR="$WORKDIR/cache/pip"

echo "========================================"
echo " Razer Phone 2 - Rootfs Builder"
echo "========================================"
echo "Distribution: Ubuntu Noble 24.04 ARM64"
echo "Profile:      $IMAGE_PROFILE"
echo "Userspace:    $USERSPACE_PROFILE"
echo "APT mirror:   $MIRROR"
echo "Kernel:       $KERNEL_VERSION"
echo "Base only:    $BASE_ONLY"
echo "Image size:   ${ROOTFS_SIZE_GB}GB"
echo "Hostname:     $HOSTNAME"
echo "User:         $USERNAME"
echo ""

# Must be root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi
trap cleanup_mounts EXIT

bash "$PROJECT_DIR/scripts/register-binfmt.sh"

# -------------------------------------------------------
# Step 1: Create rootfs image
# -------------------------------------------------------
echo "[1/10] Creating ${ROOTFS_SIZE_GB}GB rootfs image..."
mkdir -p "$ROOTFS_DIR" "$CHROOT_DIR" "$DEBOOTSTRAP_CACHE_DIR" "$APT_CACHE_DIR" "$PIP_CACHE_DIR"
cleanup_mounts

dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count="$ROOTFS_SIZE_GB" status=progress
mkfs.ext4 -L rootfs "$ROOTFS_IMG"

mount "$ROOTFS_IMG" "$CHROOT_DIR"
echo "  Rootfs image mounted at $CHROOT_DIR"

install -d "$CHROOT_DIR/usr/bin"
cp -f /usr/bin/qemu-aarch64-static "$CHROOT_DIR/usr/bin/qemu-aarch64-static"

# -------------------------------------------------------
# Step 2: Debootstrap base system
# -------------------------------------------------------
echo "[2/10] Running debootstrap (this takes several minutes)..."
DEBOOTSTRAP_ENV=()
if [ "${RAZER_NETWORK_IPV4_ONLY:-0}" = "1" ]; then
    WGETRC_FILE="$WORKDIR/cache/wgetrc-ci"
    cat > "$WGETRC_FILE" <<'EOF'
inet4_only = on
tries = 5
timeout = 30
EOF
    DEBOOTSTRAP_ENV=(env WGETRC="$WGETRC_FILE")
fi
for attempt in 1 2 3; do
    if "${DEBOOTSTRAP_ENV[@]}" debootstrap \
            --cache-dir="$DEBOOTSTRAP_CACHE_DIR" \
            --arch arm64 noble "$CHROOT_DIR" "$MIRROR"; then
        break
    fi
    if [ "$attempt" -eq 3 ]; then
        echo "ERROR: debootstrap failed after $attempt attempts." >&2
        exit 1
    fi
    echo "Debootstrap attempt $attempt failed; keeping downloaded packages and retrying..." >&2
    sleep $((attempt * 15))
done
echo "  Base system installed."

# -------------------------------------------------------
# Step 3: Mount virtual filesystems for chroot
# -------------------------------------------------------
echo "[3/10] Mounting virtual filesystems..."
mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /dev "$CHROOT_DIR/dev"
mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
mount --bind /sys "$CHROOT_DIR/sys"
mkdir -p "$CHROOT_DIR/var/cache/apt/archives"
mount --bind "$APT_CACHE_DIR" "$CHROOT_DIR/var/cache/apt/archives"
mkdir -p "$CHROOT_DIR/var/cache/razer-pip"
mount --bind "$PIP_CACHE_DIR" "$CHROOT_DIR/var/cache/razer-pip"

# -------------------------------------------------------
# Step 4: Configure APT sources
# -------------------------------------------------------
echo "[4/10] Configuring APT sources..."
cat > "$CHROOT_DIR/etc/apt/sources.list" << APT_EOF
# Ubuntu Ports (ARM64). Set RAZER_UBUNTU_MIRROR to override this official
# global endpoint with a closer regional mirror.
deb $MIRROR noble main restricted universe multiverse
deb $MIRROR noble-updates main restricted universe multiverse
deb $MIRROR noble-backports main restricted universe multiverse
deb $MIRROR noble-security main restricted universe multiverse
APT_EOF

install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/usb-gadget-setup.sh" \
    "$CHROOT_DIR/usr/local/bin/usb-gadget-setup.sh"
if [ -f "$PROJECT_DIR/config/device.env" ]; then
    install -D -m 0600 \
        "$PROJECT_DIR/config/device.env" \
        "$CHROOT_DIR/etc/razerphone2linux/device.env"
fi
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-wifi-ready.sh" \
    "$CHROOT_DIR/usr/local/sbin/razer-wifi-ready"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-root.conf" \
    "$CHROOT_DIR/etc/initramfs-tools/conf.d/razer-root"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-root-local-top" \
    "$CHROOT_DIR/etc/initramfs-tools/scripts/local-top/razer-root"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-gpu-firmware" \
    "$CHROOT_DIR/etc/initramfs-tools/hooks/razer-gpu-firmware"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/initramfs-tools/razer-bluetooth-firmware" \
    "$CHROOT_DIR/etc/initramfs-tools/hooks/razer-bluetooth-firmware"
# Panel bring-up color test: tool + units ship in the image, but the
# on-every-boot autocolortest is only auto-enabled by the debug refresh
# path (03-refresh-rootfs.sh), not in a from-scratch production build.
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-colortest.py" \
    "$CHROOT_DIR/usr/local/sbin/razer-panel-colortest"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-colortest.service" \
    "$CHROOT_DIR/etc/systemd/system/razer-panel-colortest.service"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-autocolortest.service" \
    "$CHROOT_DIR/etc/systemd/system/razer-panel-autocolortest.service"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-quiet-console.service" \
    "$CHROOT_DIR/etc/systemd/system/razer-quiet-console.service"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-charge-limits.sh" \
    "$CHROOT_DIR/usr/local/sbin/razer-charge-limits"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-charge-limits.service" \
    "$CHROOT_DIR/etc/systemd/system/razer-charge-limits.service"
install -D -m 0755 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-idle-blank.sh" \
    "$CHROOT_DIR/usr/local/sbin/razer-panel-idle-blank"
install -D -m 0644 \
    "$PROJECT_DIR/rootfs-scripts/razer-panel-idle-blank.service" \
    "$CHROOT_DIR/etc/systemd/system/razer-panel-idle-blank.service"
mkdir -p "$CHROOT_DIR/etc/systemd/system/basic.target.wants"
ln -sf ../razer-quiet-console.service \
    "$CHROOT_DIR/etc/systemd/system/basic.target.wants/razer-quiet-console.service"
mkdir -p "$CHROOT_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf ../razer-charge-limits.service \
    "$CHROOT_DIR/etc/systemd/system/multi-user.target.wants/razer-charge-limits.service"
ln -sf ../razer-panel-idle-blank.service \
    "$CHROOT_DIR/etc/systemd/system/multi-user.target.wants/razer-panel-idle-blank.service"
if [ -f "$ROOTFS_PACKAGES_DIR/tqftpserv_1.0-5_arm64.deb" ]; then
    cp -f "$ROOTFS_PACKAGES_DIR/tqftpserv_1.0-5_arm64.deb" \
        "$CHROOT_DIR/tmp/tqftpserv_1.0-5_arm64.deb"
fi
if [ -f "$ROOTFS_BINARIES_DIR/rmtfs-razer-test" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/rmtfs-razer-test" \
        "$CHROOT_DIR/usr/local/bin/rmtfs-razer-test"
fi
if [ -f "$ROOTFS_BINARIES_DIR/pd-mapper" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/pd-mapper" \
        "$CHROOT_DIR/usr/local/bin/pd-mapper"
fi

# -------------------------------------------------------
# Step 5: Configure system inside chroot
# -------------------------------------------------------
echo "[5/10] Configuring system inside chroot..."

cat > "$CHROOT_DIR/tmp/setup.sh" << 'SETUP_EOF'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
: "${ROOTFS_HOSTNAME:?}"
: "${ROOTFS_USERNAME:?}"
: "${ROOTFS_USER_PASSWORD:?}"

# Update package lists. Avoid full apt upgrade in the QEMU chroot path; it is
# slow and can stall bring-up without improving the boot/rootfs contract.
apt update

# Set locale
apt install -y locales
locale-gen en_US.UTF-8
locale-gen zh_TW.UTF-8
update-locale LANG=en_US.UTF-8

# Set timezone
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Taipei /etc/localtime
echo "Asia/Taipei" > /etc/timezone

# Set hostname
echo "$ROOTFS_HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS_EOF
127.0.0.1   localhost
127.0.1.1   $ROOTFS_HOSTNAME

::1         localhost ip6-localhost ip6-loopback
HOSTS_EOF

# Create fstab
cat > /etc/fstab << FSTAB_EOF
# Razer Phone 2 - Mainline Linux fstab
# <file system>                          <mount point>  <type>  <options>           <dump>  <pass>
/dev/disk/by-partlabel/userdata          /              ext4    errors=remount-ro   0       1
tmpfs                                    /tmp           tmpfs   defaults,nosuid     0       0
FSTAB_EOF

# Remove netplan (use NetworkManager instead)
apt purge -y netplan.io 2>/dev/null || true

# Create user
useradd -m -s /bin/bash "$ROOTFS_USERNAME"
echo "$ROOTFS_USERNAME:$ROOTFS_USER_PASSWORD" | chpasswd
usermod -aG sudo "$ROOTFS_USERNAME"

# Set root password (same as user for convenience - change later!)
echo "root:$ROOTFS_USER_PASSWORD" | chpasswd

# Install essential packages
# rmtfs: Qualcomm remote filesystem daemon - modem/WiFi firmware loader depends on this
# qrtr-tools: Qualcomm IPC Router - required by ath10k_snoc and modem subsystem
apt install -y \
    bash-completion \
    nano vim \
    chrony \
    locales \
    sudo \
    curl wget \
    network-manager \
    openssh-server \
    bluez \
    initramfs-tools \
    wpasupplicant \
    kmod \
    rmtfs \
    qrtr-tools \
    udev systemd-sysv \
    iproute2 iputils-ping \
    dbus \
    usbutils pciutils \
    evtest \
    htop \
    ca-certificates \
    gnupg \
    python3

# Install repo-controlled ARM64 packages that are not consistently available
# from the enabled Ubuntu package set during cached validation builds.
if [ -f /tmp/tqftpserv_1.0-5_arm64.deb ]; then
    apt install -y /tmp/tqftpserv_1.0-5_arm64.deb
    rm -f /tmp/tqftpserv_1.0-5_arm64.deb
else
    echo "WARNING: tqftpserv package missing from rootfs package overlay"
fi

# Enable NetworkManager
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-unmanaged-usb-gadget.conf << 'NM_USB_EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
NM_USB_EOF
systemctl enable NetworkManager

# Enable SSH
systemctl enable ssh

# -------------------------------------------------------
# Auto-resize filesystem on first boot
# -------------------------------------------------------
cat > /etc/systemd/system/resizefs.service << 'RESIZE_EOF'
[Unit]
Description=Expand root filesystem to fill partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs \$(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
RemainAfterExit=true

[Install]
WantedBy=default.target
RESIZE_EOF
systemctl enable resizefs.service

# -------------------------------------------------------
# Serial console on UART (debug)
# -------------------------------------------------------
cat > /etc/systemd/system/serial-getty@ttyMSM0.service << 'UART_EOF'
[Unit]
Description=Serial Console on ttyMSM0 (UART Debug)

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyMSM0 xterm-256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
UART_EOF
systemctl enable serial-getty@ttyMSM0.service

# -------------------------------------------------------
# Serial console on USB gadget
# -------------------------------------------------------
cat > /etc/systemd/system/serial-getty@ttyGS0.service << 'USB_EOF'
[Unit]
Description=Serial Console on ttyGS0 (USB Gadget)

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyGS0 xterm-256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
USB_EOF
systemctl enable serial-getty@ttyGS0.service

cat > /etc/systemd/system/usb-gadget.service << 'GADGET_SERVICE_EOF'
[Unit]
Description=USB ACM serial + NCM ethernet gadget
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=sysinit.target
Before=serial-getty@ttyGS0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-gadget-setup.sh

[Install]
WantedBy=sysinit.target
GADGET_SERVICE_EOF
systemctl enable usb-gadget.service

mkdir -p /etc/systemd/system/serial-getty@ttyGS0.service.d
cat > /etc/systemd/system/serial-getty@ttyGS0.service.d/after-usb-gadget.conf << 'GADGET_DROPIN_EOF'
[Unit]
After=usb-gadget.service
Wants=usb-gadget.service
GADGET_DROPIN_EOF

# -------------------------------------------------------
# Kernel modules load configuration
# -------------------------------------------------------
cat > /etc/modules-load.d/razer-aura.conf << 'MODULES_EOF'
# Razer Phone 2 kernel modules
# Keep MDSS/DSI/MSM DRM out of the default path. The practical display path is
# bootloader framebuffer -> simpledrm/fbdev (native NT36830 panel comes later).
# WiFi
qcom_sysmon
qcom_q6v5_mss
ath10k_core
ath10k_snoc
# Touchscreen
rmi_i2c
MODULES_EOF

rm -f /etc/modprobe.d/razer-late-modem-test.conf

# -------------------------------------------------------
# Disable unnecessary services for faster boot
# -------------------------------------------------------
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable fstrim.timer 2>/dev/null || true

# Clean up
apt clean
rm -f /tmp/*
history -c

echo "System configuration complete."
SETUP_EOF

chmod +x "$CHROOT_DIR/tmp/setup.sh"
chroot "$CHROOT_DIR" /usr/bin/env \
    ROOTFS_HOSTNAME="$HOSTNAME" \
    ROOTFS_USERNAME="$USERNAME" \
    ROOTFS_USER_PASSWORD="$USER_PASSWORD" \
    /tmp/setup.sh

# The distro package supplies the service unit and dependencies, but the
# repo-controlled binary adds the Android firmware path aliases required by
# Razer's modem/WLAN PD TFTP requests.
if [ -f "$ROOTFS_BINARIES_DIR/tqftpserv" ]; then
    install -D -m 0755 "$ROOTFS_BINARIES_DIR/tqftpserv" \
        "$CHROOT_DIR/usr/bin/tqftpserv"
else
    echo "WARNING: patched tqftpserv missing from $ROOTFS_BINARIES_DIR"
fi

# -------------------------------------------------------
# Steps 6-7: Install kernel-dependent runtime content
# -------------------------------------------------------
if [ "$BASE_ONLY" != "1" ]; then
echo "[6/10] Installing kernel modules (version $KERNEL_VERSION)..."
rsync -av --progress \
    "$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_VERSION" \
    "$CHROOT_DIR/lib/modules/"

# Run depmod inside chroot
chroot "$CHROOT_DIR" depmod -a "$KERNEL_VERSION"
echo "$KERNEL_VERSION" > "$OUTPUT_DIR/rootfs.kernel-release"
if [ ! -s "$KERNEL_MODULES_FINGERPRINT_FILE" ]; then
    echo "ERROR: kernel module fingerprint is missing: $KERNEL_MODULES_FINGERPRINT_FILE"
    exit 1
fi
install -D -m 0644 "$KERNEL_MODULES_FINGERPRINT_FILE" \
    "$CHROOT_DIR/etc/razerphone2linux/kernel.modules-fingerprint"
cp -f "$KERNEL_MODULES_FINGERPRINT_FILE" "$ROOTFS_MODULES_FINGERPRINT_FILE"

echo "  Kernel modules installed."

# -------------------------------------------------------
# Step 6b: Generate initramfs after kernel modules exist
# -------------------------------------------------------
echo "[6b/10] Generating Ubuntu initramfs..."

for bt_fw in qca/crbtfw21.tlv qca/Razer/aura/crnv21.bin; do
    if [ ! -f "$FIRMWARE_DIR/$bt_fw" ]; then
        echo "ERROR: required Razer Bluetooth firmware is missing: $FIRMWARE_DIR/$bt_fw"
        exit 1
    fi
    install -D -m 0644 "$FIRMWARE_DIR/$bt_fw" \
        "$CHROOT_DIR/usr/lib/firmware/$bt_fw"
done

mkdir -p "$CHROOT_DIR/boot"
if [ -f "$OUTPUT_DIR/config-$KERNEL_VERSION" ]; then
    cp -f "$OUTPUT_DIR/config-$KERNEL_VERSION" "$CHROOT_DIR/boot/config-$KERNEL_VERSION"
elif [ -f "$OUTPUT_DIR/kernel.config" ]; then
    cp -f "$OUTPUT_DIR/kernel.config" "$CHROOT_DIR/boot/config-$KERNEL_VERSION"
fi
chroot "$CHROOT_DIR" update-initramfs -c -k "$KERNEL_VERSION"

INITRD_SRC="$CHROOT_DIR/boot/initrd.img-$KERNEL_VERSION"
if [ ! -f "$INITRD_SRC" ]; then
    echo "ERROR: initramfs was not generated at /boot/initrd.img-$KERNEL_VERSION"
    exit 1
fi

cp -f "$INITRD_SRC" "$OUTPUT_DIR/initrd.img-$KERNEL_VERSION"
cp -f "$INITRD_SRC" "$OUTPUT_DIR/initrd.img"
echo "  Initramfs copied to $OUTPUT_DIR/initrd.img-$KERNEL_VERSION"

# -------------------------------------------------------
# Step 7: Install firmware blobs
# -------------------------------------------------------
echo "[7/10] Installing firmware blobs..."

# 7a: Proprietary blobs (adsp, cdsp, gpu zap, venus) from stock ROM.
# firmware/** is gitignored, so a fresh checkout/worktree only contains
# README.md. Checking "directory non-empty" is therefore not enough: require
# the Razer modem loader explicitly, or the image silently ships without
# WiFi/ADSP/CDSP (seen 2026-07-02).
if [ -f "$FIRMWARE_DIR/qcom/sdm845/Razer/aura/mba.mbn" ]; then
    mkdir -p "$CHROOT_DIR/usr/lib/firmware"
    cp -rv "$FIRMWARE_DIR"/* "$CHROOT_DIR/usr/lib/firmware/"
    echo "  Proprietary firmware installed."
elif [ "${RAZER_ALLOW_MISSING_FIRMWARE:-0}" = "1" ]; then
    echo "  WARNING: proprietary firmware missing; building anyway"
    echo "  (RAZER_ALLOW_MISSING_FIRMWARE=1). WiFi/ADSP/CDSP will not work."
else
    echo "ERROR: $FIRMWARE_DIR/qcom/sdm845/Razer/aura/mba.mbn is missing."
    echo "firmware/ is gitignored; copy it from an existing checkout or run"
    echo "scripts/extract-modem-firmware.sh. Set RAZER_ALLOW_MISSING_FIRMWARE=1"
    echo "to build a no-WiFi image deliberately."
    exit 1
fi

# 7b: WCN3990 WiFi firmware from linux-firmware (open-source, no ROM needed).
echo "  Downloading WCN3990 (ath10k) firmware from linux-firmware git..."
LINUX_FW_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
ATH10K_DIR="$CHROOT_DIR/usr/lib/firmware/ath10k/WCN3990/hw1.0"
mkdir -p "$ATH10K_DIR"

for fw_file in firmware-5.bin board.bin board-2.bin; do
    if [ -s "$ATH10K_DIR/$fw_file" ]; then
        echo "  Keeping existing $fw_file ($(du -h "$ATH10K_DIR/$fw_file" | cut -f1))"
    elif wget -q --timeout=30 -O "$ATH10K_DIR/$fw_file" \
            "${LINUX_FW_BASE}/ath10k/WCN3990/hw1.0/${fw_file}"; then
        echo "  Downloaded $fw_file ($(du -h "$ATH10K_DIR/$fw_file" | cut -f1))"
    else
        echo "  WARNING: Failed to download $fw_file - WiFi may not work"
        rm -f "$ATH10K_DIR/$fw_file"
    fi
done

# 7c: Adreno 630 firmware (a630_gmu.bin) from linux-firmware.
#     The GPU zap shader (a630_zap.mbn) still needs the stock ROM.
ADRENO_DIR="$CHROOT_DIR/usr/lib/firmware/qcom"
mkdir -p "$ADRENO_DIR"
if wget -q --timeout=30 -O "$ADRENO_DIR/a630_gmu.bin" \
        "${LINUX_FW_BASE}/qcom/a630_gmu.bin"; then
    echo "  Downloaded a630_gmu.bin ($(du -h "$ADRENO_DIR/a630_gmu.bin" | cut -f1))"
else
    echo "  WARNING: Failed to download a630_gmu.bin"
    rm -f "$ADRENO_DIR/a630_gmu.bin"
fi

else
    echo "[6-7/10] Deferring modules, firmware, initramfs, and runtime overlay."
fi

# -------------------------------------------------------
# Step 8/9: Optional final target userspace
# -------------------------------------------------------
echo "[8/10] Applying userspace profile: $USERSPACE_PROFILE"
echo "$USERSPACE_PROFILE" > "$OUTPUT_DIR/userspace.profile"
if [ "$USERSPACE_PROFILE" = "none" ]; then
    echo "  Base image selected; no app stack will be preinstalled."
else
    PROFILE_INSTALLER="$PROJECT_DIR/rootfs-profiles/$USERSPACE_PROFILE/install.sh"
    if [ ! -f "$PROFILE_INSTALLER" ]; then
        echo "ERROR: userspace profile installer is missing: $PROFILE_INSTALLER"
        exit 1
    fi
    CHROOT_DIR="$CHROOT_DIR" PROJECT_DIR="$PROJECT_DIR" \
        bash "$PROFILE_INSTALLER"
fi

# Keep the full build and validation refresh on the same runtime overlay path.
# This must run after firmware is installed so it can create firmware aliases
# and enable tqftpserv on the first reproducible build.
if [ "$BASE_ONLY" != "1" ]; then
    echo "[9/10] Applying runtime config overlay..."
    cp -f "$PROJECT_DIR/rootfs-scripts/apply-runtime-config.sh" "$CHROOT_DIR/tmp/apply-runtime-config.sh"
    chmod +x "$CHROOT_DIR/tmp/apply-runtime-config.sh"
    chroot "$CHROOT_DIR" /tmp/apply-runtime-config.sh
else
    echo "[9/10] Runtime config overlay deferred to 03-refresh-rootfs.sh."
fi

# -------------------------------------------------------
# Step 10: Cleanup and unmount
# -------------------------------------------------------
echo "[10/10] Cleaning up and creating sparse image..."

# Final cleanup inside chroot. Do not run apt clean here: /var/cache/apt/archives
# is a host-side bind mount used to speed up future full rootfs builds.
chroot "$CHROOT_DIR" bash -c "
    rm -rf /tmp/* /var/tmp/*
    rm -rf /home/klipper/.cache/pip
    rm -rf /var/lib/apt/lists/*
    find /var/log -type f -exec truncate -s 0 {} +
"

# Unmount virtual filesystems
umount "$CHROOT_DIR/var/cache/apt/archives" 2>/dev/null || true
umount "$CHROOT_DIR/var/cache/razer-pip" 2>/dev/null || true
umount "$CHROOT_DIR/proc" 2>/dev/null || true
umount "$CHROOT_DIR/dev/pts" 2>/dev/null || true
umount "$CHROOT_DIR/dev" 2>/dev/null || true
umount "$CHROOT_DIR/sys" 2>/dev/null || true

# Unmount rootfs
umount "$CHROOT_DIR"

# Compact free ext4 blocks before creating the Android sparse image. img2simg
# only omits zero-filled blocks; stale non-zero free space makes userdata
# flashes much slower without adding useful rootfs content.
if command -v e2fsck >/dev/null 2>&1; then
    e2fsck -fy "$ROOTFS_IMG"
fi
if command -v zerofree >/dev/null 2>&1; then
    zerofree "$ROOTFS_IMG"
else
    echo "  WARNING: zerofree is not installed; rootfs-sparse.img may include stale ext4 free blocks."
fi

cp -f "$ROOTFS_IMG" "$OUTPUT_ROOTFS_IMG"

mkdir -p "$WIN_OUTPUT_DIR"
cp -f "$OUTPUT_ROOTFS_IMG" "$WIN_OUTPUT_DIR/rootfs.img"
cp -f "$OUTPUT_DIR/userspace.profile" "$WIN_OUTPUT_DIR/userspace.profile"
if [ "$BASE_ONLY" != "1" ]; then
    # Create the flashable sparse image only after modules and runtime content
    # have been applied. Base-only CI jobs cache just the reusable raw image.
    SPARSE_IMG="$OUTPUT_DIR/rootfs-sparse.img"
    img2simg "$ROOTFS_IMG" "$SPARSE_IMG"
    cp -f "$SPARSE_IMG" "$WIN_OUTPUT_DIR/rootfs-sparse.img"
    cp -f "$OUTPUT_DIR/rootfs.kernel-release" "$WIN_OUTPUT_DIR/rootfs.kernel-release"
    cp -f "$ROOTFS_MODULES_FINGERPRINT_FILE" "$WIN_OUTPUT_DIR/rootfs.modules-fingerprint"
    cp -f "$OUTPUT_DIR/initrd.img-$KERNEL_VERSION" "$WIN_OUTPUT_DIR/initrd.img-$KERNEL_VERSION"
    cp -f "$OUTPUT_DIR/initrd.img" "$WIN_OUTPUT_DIR/initrd.img"
    if [ -f "$KERNEL_RELEASE_FILE" ]; then
        cp -f "$KERNEL_RELEASE_FILE" "$WIN_OUTPUT_DIR/kernel.release"
    fi
fi

echo ""
echo "========================================"
echo " Rootfs build complete!"
echo "========================================"
echo ""
echo "Outputs:"
echo "  Raw image:    $OUTPUT_ROOTFS_IMG"
if [ "$BASE_ONLY" = "1" ]; then
    echo "  Finalization: deferred to scripts/03-refresh-rootfs.sh"
else
    echo "  Sparse image: $SPARSE_IMG"
fi
echo ""
echo "Configuration:"
echo "  User:     $USERNAME / $USER_PASSWORD"
echo "  Root:     root / $USER_PASSWORD"
echo "  Hostname: $HOSTNAME"
echo "  SSH:      enabled"
echo "  WiFi:     use 'nmtui' or 'nmcli' after boot"
echo "  Userspace profile: $USERSPACE_PROFILE"
echo ""
echo "  Serial debug:  ttyMSM0 (UART) and ttyGS0 (USB gadget)"
echo ""
echo "IMPORTANT: Change passwords after first boot!"
echo ""
echo "Next: Run bash 04-make-boot-image.sh"
