#!/bin/bash
# ==========================================================================
# Razer Phone 2 (aura) - Mainline Linux Build Environment Setup
# ==========================================================================
# This script sets up the complete build environment in WSL Ubuntu 24.04
# for cross-compiling a mainline Linux kernel targeting the Razer Phone 2.
#
# Usage: bash 01-setup-environment.sh
# Must be run inside WSL Ubuntu (not Windows).
# ==========================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/config/kernel-source.env"

WORKDIR="$HOME/razorphone2linux"
KERNEL_DIR="$WORKDIR/kernel/linux"
REFERENCE_DIR="$WORKDIR/reference"
FIRMWARE_DIR="$WORKDIR/firmware"

echo "========================================"
echo " Razer Phone 2 - Build Environment Setup"
echo "========================================"

# -------------------------------------------------------
# Step 1: Install build dependencies
# -------------------------------------------------------
if [ "${RAZER_SKIP_APT:-0}" = "1" ]; then
    echo "[1/5] Skipping apt dependency installation (RAZER_SKIP_APT=1)."
else
    echo "[1/5] Installing build dependencies..."
    sudo apt update
    sudo apt install -y \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        build-essential bc bison flex \
        libssl-dev libncurses-dev libelf-dev \
        device-tree-compiler \
        debootstrap qemu-user-static \
        rsync git curl wget cpio lz4 \
        python3 python3-pip python3-git python3-libfdt python3-ply \
        libgmp-dev libmpc-dev \
        android-sdk-libsparse-utils \
        u-boot-tools \
        kmod p7zip-full zerofree

    # Install mkbootimg (Android boot image tool)
    if ! command -v mkbootimg &>/dev/null; then
        echo "Installing mkbootimg..."
        sudo apt install -y mkbootimg 2>/dev/null || {
            echo "mkbootimg not in apt, installing via pip..."
            pip3 install --break-system-packages mkbootimg 2>/dev/null || \
            pip3 install mkbootimg
        }
    fi

    # Install adb/fastboot
    if ! command -v fastboot &>/dev/null; then
        echo "Installing android-tools for fastboot/adb..."
        sudo apt install -y android-tools-adb android-tools-fastboot 2>/dev/null || \
        sudo apt install -y adb fastboot 2>/dev/null || {
            echo "WARNING: Could not install fastboot/adb. Install manually."
        }
    fi

    echo "[1/5] Build dependencies installed."
fi

for required in aarch64-linux-gnu-gcc git dtc debootstrap qemu-aarch64-static \
        rsync cpio img2simg mkbootimg 7z zerofree; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "ERROR: required tool is missing: $required" >&2
        echo "Rerun without RAZER_SKIP_APT=1 after sudo access is available." >&2
        exit 1
    fi
done

# -------------------------------------------------------
# Step 2: Create directory structure
# -------------------------------------------------------
echo "[2/5] Creating directory structure..."
mkdir -p "$WORKDIR"/{kernel,reference,firmware,rootfs,output,scripts}
mkdir -p "$FIRMWARE_DIR"/{qcom/sdm845/Razer/aura,ath10k/WCN3990/hw1.0}

echo "[2/5] Directory structure created."

# -------------------------------------------------------
# Step 3: Clone mainline SDM845 kernel
# -------------------------------------------------------
echo "[3/5] Preparing mainline SDM845 Linux kernel..."
if [ -d "$KERNEL_LOCAL_DIR" ]; then
    echo "Using in-repository kernel source: $KERNEL_LOCAL_DIR"
    rm -rf "$KERNEL_DIR"
    mkdir -p "$(dirname "$KERNEL_DIR")"
    if [ -d "$KERNEL_LOCAL_DIR/.git" ]; then
        git clone --local --no-hardlinks "$KERNEL_LOCAL_DIR" "$KERNEL_DIR"
        git -C "$KERNEL_DIR" checkout --detach "$KERNEL_COMMIT"
        current="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
        if [ "$current" != "$KERNEL_COMMIT" ]; then
            echo "ERROR: in-repository kernel checkout is at $current"
            echo "Expected pinned commit: $KERNEL_COMMIT"
            exit 1
        fi
    else
        if [ -f "$KERNEL_LOCAL_DIR/.razer-kernel-commit" ]; then
            local_commit="$(tr -d '\r\n' < "$KERNEL_LOCAL_DIR/.razer-kernel-commit")"
            if [ "$local_commit" != "$KERNEL_COMMIT" ]; then
                echo "ERROR: in-repository kernel snapshot marker is $local_commit"
                echo "Expected pinned commit: $KERNEL_COMMIT"
                exit 1
            fi
        else
            echo "WARNING: kernel-source/linux has no .razer-kernel-commit marker."
        fi
        cp -a "$KERNEL_LOCAL_DIR" "$KERNEL_DIR"
        touch "$KERNEL_DIR/.razer-source-snapshot"
        find "$KERNEL_DIR" -type f -name '*.sh' -exec chmod 0755 {} +
        git -C "$KERNEL_DIR" init
        git -C "$KERNEL_DIR" add -A
        git -C "$KERNEL_DIR" \
            -c user.name="RazerPhone2Linux Build" \
            -c user.email="razerphone2linux@example.invalid" \
            commit -m "import in-repository kernel source snapshot"
        echo "WARNING: kernel-source/linux is not a Git checkout; pinned commit ancestry cannot be verified."
    fi
    echo "Kernel prepared from in-repository source at $KERNEL_DIR"
elif [ ! -d "$KERNEL_DIR" ]; then
    git clone --filter=blob:none --no-checkout "$KERNEL_REPO" "$KERNEL_DIR"
    git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_COMMIT"
    git -C "$KERNEL_DIR" checkout --detach "$KERNEL_COMMIT"
    echo "Kernel cloned to $KERNEL_DIR"
else
    current="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    if [ "$current" != "$KERNEL_COMMIT" ]; then
        echo "ERROR: existing kernel checkout is at $current"
        echo "Expected pinned commit: $KERNEL_COMMIT"
        echo "Move the old checkout aside, then rerun this script."
        exit 1
    fi
    echo "Kernel checkout already uses pinned commit $KERNEL_COMMIT."
fi

# -------------------------------------------------------
# Step 4: Clone Razer Android kernel for reference
# -------------------------------------------------------
echo "[4/5] Cloning Razer Phone 2 Android kernel (reference)..."
if [ "${RAZER_SKIP_REFERENCE:-0}" = "1" ]; then
    echo "Skipping reference kernel clone (RAZER_SKIP_REFERENCE=1, CI builds do not need it)."
elif [ ! -d "$REFERENCE_DIR/android_kernel_razer_aura" ]; then
    git clone --depth=1 https://github.com/ASKSAP/android_kernel_razer_aura.git \
        "$REFERENCE_DIR/android_kernel_razer_aura"
    echo "Reference kernel cloned."
else
    echo "Reference kernel already exists, skipping."
fi

# -------------------------------------------------------
# Step 5: Verify cross-compiler
# -------------------------------------------------------
echo "[5/5] Verifying cross-compilation toolchain..."
CROSS_COMPILE_VER=$(aarch64-linux-gnu-gcc --version | head -1)
echo "Cross compiler: $CROSS_COMPILE_VER"

echo ""
echo "========================================"
echo " Environment setup complete!"
echo "========================================"
echo ""
echo "Workspace: $WORKDIR"
echo "Kernel:    $KERNEL_DIR"
echo "Reference: $REFERENCE_DIR"
echo ""
echo "Next steps:"
echo "  1. Put the Razer factory package or modem.img in the project directory."
echo "  2. Run: bash scripts/extract-modem-firmware.sh"
echo "  3. From Windows run:"
echo "       powershell -ExecutionPolicy Bypass -File scripts/build-all-wsl.ps1 all"
echo ""
echo "IMPORTANT: You need to extract firmware blobs from Razer Phone 2 stock ROM"
echo "  into the project firmware/ directory before the full rootfs build."
echo "  Required firmware:"
echo "    - qcom/sdm845/Razer/aura/adsp.mbn"
echo "    - qcom/sdm845/Razer/aura/cdsp.mbn"
echo "    - qcom/sdm845/Razer/aura/a630_zap.mbn"
echo "    - qcom/sdm845/Razer/aura/venus.mbn"
echo "    - qcom/sdm845/Razer/aura/mba.mbn"
echo "    - qcom/sdm845/Razer/aura/modem.mbn"
echo "    - qcom/sdm845/Razer/aura/slpi.mbn"
echo "    - qcom/sdm845/Razer/aura/ipa_fws.mbn"
echo "    - ath10k/WCN3990/hw1.0/board.bin"
echo "    - ath10k/WCN3990/hw1.0/firmware-5.bin"
