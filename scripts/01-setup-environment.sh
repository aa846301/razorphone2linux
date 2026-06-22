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

    if ! command -v dt-doc-validate &>/dev/null; then
        echo "Installing DeviceTree schema validator..."
        python3 -m pip install --user --break-system-packages dtschema yamllint
    fi

    echo "[1/5] Build dependencies installed."
fi

for required in aarch64-linux-gnu-gcc git dtc debootstrap qemu-aarch64-static \
        rsync cpio img2simg mkbootimg 7z zerofree dt-doc-validate; do
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
echo "[3/5] Cloning mainline SDM845 Linux kernel..."
if [ ! -d "$KERNEL_DIR" ]; then
    git clone --filter=blob:none --no-checkout "$KERNEL_REPO" "$KERNEL_DIR"
    git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_COMMIT"
    git -C "$KERNEL_DIR" checkout --detach "$KERNEL_COMMIT"
    echo "Kernel cloned to $KERNEL_DIR"
else
    current="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    if [ "$current" != "$KERNEL_COMMIT" ]; then
        if [ -n "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
            echo "ERROR: existing kernel checkout has uncommitted changes."
            echo "Clean or move it aside before switching kernel baselines."
            exit 1
        fi
        echo "Updating clean kernel checkout from $current to $KERNEL_COMMIT..."
        git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_COMMIT"
        git -C "$KERNEL_DIR" checkout --detach "$KERNEL_COMMIT"
    fi
    echo "Kernel checkout uses pinned $KERNEL_BRANCH commit $KERNEL_COMMIT."
fi

# -------------------------------------------------------
# Step 4: Clone Razer Android kernel for reference
# -------------------------------------------------------
echo "[4/5] Cloning Razer Phone 2 Android kernel (reference)..."
if [ ! -d "$REFERENCE_DIR/android_kernel_razer_aura" ]; then
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
