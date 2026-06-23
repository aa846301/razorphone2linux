#!/bin/bash
# ==========================================================================
# Razer Phone 2 (aura) - Kernel Build Script
# ==========================================================================
# Cross-compiles the mainline Linux kernel with Razer Phone 2 device tree
# and NT36830 panel driver.
#
# Usage: bash 02-build-kernel.sh [menuconfig]
#   Optional arg "menuconfig" opens kernel config editor before building.
#
# Prerequisites: Run 01-setup-environment.sh first.
# ==========================================================================

set -euo pipefail

WORKDIR="${RAZER_WORKDIR:-$HOME/razorphone2linux}"
KERNEL_DIR="$WORKDIR/kernel/linux"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/config/kernel-source.env"
source "$PROJECT_DIR/config/build.env"
IMAGE_PROFILE="${RAZER_IMAGE_PROFILE:-printer}"
KERNEL_SCOPE="${RAZER_KERNEL_SCOPE:-full}"
case "$IMAGE_PROFILE" in
    base|printer) ;;
    *) echo "ERROR: RAZER_IMAGE_PROFILE must be base or printer."; exit 2 ;;
esac
case "$KERNEL_SCOPE" in
    full|display) ;;
    *) echo "ERROR: RAZER_KERNEL_SCOPE must be full or display."; exit 2 ;;
esac
OUTPUT_DIR="$WORKDIR/output/$IMAGE_PROFILE"
WIN_OUTPUT_DIR="$PROJECT_DIR/output/$IMAGE_PROFILE"

mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
# Suppress the kernel build system's automatic "+" suffix for an integration
# commit that is intentionally not an upstream annotated release tag.
export LOCALVERSION=""

MAX_JOBS="${RAZER_BUILD_JOBS:-4}"
case "$MAX_JOBS" in
    ''|*[!0-9]*|0)
        echo "ERROR: RAZER_BUILD_JOBS must be a positive integer."
        exit 2
        ;;
esac
NPROC=$(nproc)
if [ "$NPROC" -gt "$MAX_JOBS" ]; then
    BUILD_JOBS="$MAX_JOBS"
else
    BUILD_JOBS="$NPROC"
fi

echo "========================================"
echo " Razer Phone 2 - Kernel Build"
echo "========================================"
echo "Kernel dir: $KERNEL_DIR"
echo "Image profile: $IMAGE_PROFILE"
echo "Build scope: $KERNEL_SCOPE"
echo "Parallel jobs: $BUILD_JOBS"
echo ""

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "ERROR: missing kernel checkout. Run scripts/01-setup-environment.sh first."
    exit 1
fi

if ! git -C "$KERNEL_DIR" merge-base --is-ancestor "$KERNEL_COMMIT" HEAD; then
    echo "ERROR: pinned kernel commit is not an ancestor of the checkout."
    echo "Expected base commit: $KERNEL_COMMIT"
    exit 1
fi

if [ -n "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
    echo "ERROR: kernel checkout contains uncommitted files before integration."
    echo "Use a clean checkout or move it aside and rerun 01-setup-environment.sh."
    git -C "$KERNEL_DIR" status --short
    exit 1
fi

if grep -Rqs -E 'QRTR diag|GLINK diag|q6v5_diag_dump_crash_smem|IPA QMI diag' \
        "$KERNEL_DIR/net/qrtr/af_qrtr.c" \
        "$KERNEL_DIR/drivers/rpmsg/qcom_glink_native.c" \
        "$KERNEL_DIR/drivers/remoteproc/qcom_q6v5.c" \
        "$KERNEL_DIR/drivers/net/ipa/ipa_qmi.c"; then
    echo "ERROR: stale diagnostic instrumentation exists in the kernel checkout."
    echo "Move ~/razorphone2linux/kernel/linux aside and rerun 01-setup-environment.sh."
    exit 1
fi

# -------------------------------------------------------
# Step 1: Install device tree and panel driver into kernel tree
# -------------------------------------------------------
echo "[1/6] Installing device tree and panel driver..."

# Copy DTS
install -v -m 0644 "$PROJECT_DIR/dts/sdm845-razer-aura.dts" \
    "$KERNEL_DIR/arch/arm64/boot/dts/qcom/sdm845-razer-aura.dts"

# Copy panel driver
install -v -m 0644 "$PROJECT_DIR/panel-driver/panel-novatek-nt36830.c" \
    "$KERNEL_DIR/drivers/gpu/drm/panel/panel-novatek-nt36830.c"

install -v -m 0644 "$PROJECT_DIR/panel-driver/novatek,nt36830.yaml" \
    "$KERNEL_DIR/Documentation/devicetree/bindings/display/panel/novatek,nt36830.yaml"

# -------------------------------------------------------
# Step 2: Patch DTS Makefile to include our device tree
# -------------------------------------------------------
echo "[2/6] Patching DTS Makefile..."
DTS_MAKEFILE="$KERNEL_DIR/arch/arm64/boot/dts/qcom/Makefile"

if ! grep -q "sdm845-razer-aura" "$DTS_MAKEFILE"; then
    # Find the line with the last sdm845 entry and add our DTB after it
    # Use sed to add after the last sdm845 dtb line
    LAST_SDM845_LINE=$(grep -n "sdm845-" "$DTS_MAKEFILE" | tail -1 | cut -d: -f1)
    if [ -n "$LAST_SDM845_LINE" ]; then
        sed -i "${LAST_SDM845_LINE}a\\dtb-\$(CONFIG_ARCH_QCOM) += sdm845-razer-aura.dtb" "$DTS_MAKEFILE"
        echo "  Added sdm845-razer-aura.dtb to DTS Makefile (after line $LAST_SDM845_LINE)"
    else
        # Fallback: append to end
        echo "dtb-\$(CONFIG_ARCH_QCOM) += sdm845-razer-aura.dtb" >> "$DTS_MAKEFILE"
        echo "  Added sdm845-razer-aura.dtb to DTS Makefile (appended)"
    fi
else
    echo "  sdm845-razer-aura.dtb already in DTS Makefile."
fi

# -------------------------------------------------------
# Step 3: Patch panel driver Kconfig and Makefile
# -------------------------------------------------------
echo "[3/6] Patching panel driver Kconfig and Makefile..."

PANEL_KCONFIG="$KERNEL_DIR/drivers/gpu/drm/panel/Kconfig"
PANEL_MAKEFILE="$KERNEL_DIR/drivers/gpu/drm/panel/Makefile"

# Add Kconfig entry if not present
if ! grep -q "DRM_PANEL_NOVATEK_NT36830" "$PANEL_KCONFIG"; then
    # Find the NT36523 entry and add our entry after it
    cat >> "$PANEL_KCONFIG" << 'KCONFIG_EOF'

config DRM_PANEL_NOVATEK_NT36830
	tristate "NovaTeK NT36830 Dual-DSI AMOLED panel with DSC"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	select DRM_DISPLAY_HELPER
	select DRM_DISPLAY_DSC_HELPER
	help
	  Say Y or M here if you want to enable support for the NovaTeK
	  NT36830 AMOLED display panel used in the Razer Phone 2.
	  This panel uses Dual DSI with Display Stream Compression (DSC)
	  at 1440x2560 resolution.

	  If unsure, say N.
KCONFIG_EOF
    echo "  Added DRM_PANEL_NOVATEK_NT36830 to Kconfig"
else
    echo "  DRM_PANEL_NOVATEK_NT36830 already in Kconfig."
fi

# Add Makefile entry if not present
if ! grep -q "panel-novatek-nt36830" "$PANEL_MAKEFILE"; then
    echo "obj-\$(CONFIG_DRM_PANEL_NOVATEK_NT36830) += panel-novatek-nt36830.o" >> "$PANEL_MAKEFILE"
    echo "  Added panel-novatek-nt36830 to panel Makefile"
else
    echo "  panel-novatek-nt36830 already in panel Makefile."
fi

# -------------------------------------------------------
# Step 3b: Apply repo-controlled kernel patches
# -------------------------------------------------------
echo "[3b/6] Applying repo-controlled kernel patches..."
PATCH_DIR="$PROJECT_DIR/kernel-patches"
if [ -d "$PATCH_DIR" ]; then
    while IFS= read -r patch_file; do
        patch_name="$(basename "$patch_file")"
        if git -C "$KERNEL_DIR" apply --recount --reverse --check "$patch_file" >/dev/null 2>&1; then
            echo "  $patch_name already applied."
        else
            git -C "$KERNEL_DIR" apply --recount --check "$patch_file"
            git -C "$KERNEL_DIR" apply --recount "$patch_file"
            echo "  Applied $patch_name"
        fi
    done < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort)
else
    echo "  No kernel-patches directory."
fi

# Keep the generated external kernel checkout clean. The authoritative source
# remains this project (DTS, panel source, config, and top-level patches), while
# the local integration commit prevents git's "-dirty" marker and makes it
# obvious exactly what was built.
if [ -n "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
    if [ -z "$(git -C "$KERNEL_DIR" branch --show-current)" ]; then
        integration_branch="razerphone2linux/integration-${KERNEL_COMMIT:0:12}"
        git -C "$KERNEL_DIR" switch -C "$integration_branch"
    fi
    git -C "$KERNEL_DIR" add -A
    git -C "$KERNEL_DIR" \
        -c user.name="RazerPhone2Linux Build" \
        -c user.email="razerphone2linux@example.invalid" \
        commit -m "arm64: qcom: integrate Razer Phone 2 project sources"
fi

if [ -n "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
    echo "ERROR: kernel integration commit did not leave a clean source tree."
    git -C "$KERNEL_DIR" status --short
    exit 1
fi

# -------------------------------------------------------
# Step 4: Configure kernel
# -------------------------------------------------------
echo "[4/6] Configuring kernel..."
cd "$KERNEL_DIR"

# Start with sdm845 defconfig (from the sdm845-mainline project)
if [ -f "arch/arm64/configs/sdm845_defconfig" ]; then
    make sdm845_defconfig
elif [ -f "arch/arm64/configs/defconfig" ]; then
    make defconfig
else
    echo "ERROR: No suitable defconfig found!"
    exit 1
fi

# The SDM845 tree ships two maintained fragments on top of arm64 defconfig.
# Apply them before the project fragments; using defconfig alone is not the
# configuration tested by sdm845-mainline.
for upstream_fragment in \
    arch/arm64/configs/sdm845.config \
    arch/arm64/configs/misc.config; do
    if [ ! -f "$upstream_fragment" ]; then
        echo "ERROR: missing SDM845 upstream config fragment: $upstream_fragment"
        exit 1
    fi
    echo "Applying SDM845 upstream config fragment: $upstream_fragment"
    ./scripts/kconfig/merge_config.sh -m .config "$upstream_fragment"
done

# Apply the canonical Razer config fragment.
CONFIG_FRAGMENT="$PROJECT_DIR/config/razer-aura.config"
if [ ! -f "$CONFIG_FRAGMENT" ]; then
    echo "ERROR: missing canonical config fragment: $CONFIG_FRAGMENT"
    exit 1
fi

echo "Applying Razer Phone 2 config fragment: $CONFIG_FRAGMENT"
sed 's/\r$//' "$CONFIG_FRAGMENT" > /tmp/razer_aura_fragment.config
./scripts/kconfig/merge_config.sh -m .config /tmp/razer_aura_fragment.config

if [ "$IMAGE_PROFILE" = "printer" ]; then
    PRINTER_CONFIG_FRAGMENT="$PROJECT_DIR/config/razer-aura-printer.config"
    echo "Applying printer-host config fragment: $PRINTER_CONFIG_FRAGMENT"
    sed 's/\r$//' "$PRINTER_CONFIG_FRAGMENT" > /tmp/razer_aura_printer_fragment.config
    ./scripts/kconfig/merge_config.sh -m .config /tmp/razer_aura_printer_fragment.config
fi

# Keep the Qualcomm Wi-Fi bring-up chain aligned with the postmarketOS SDM845
# reference config. The remoteprocs are modules so userspace can start the
# MSS/RFS path after rootfs services are available, while GLINK/SMD core
# transports stay built in like the working pmOS SDM845 kernels.
./scripts/config --module CFG80211
./scripts/config --module MAC80211
./scripts/config --module ATH10K
./scripts/config --module ATH10K_SNOC
./scripts/config --module QCOM_Q6V5_COMMON
./scripts/config --module QCOM_Q6V5_MSS
./scripts/config --module QCOM_Q6V5_ADSP
./scripts/config --module QCOM_Q6V5_PAS
./scripts/config --disable QCOM_Q6V5_WCSS
./scripts/config --module QCOM_WCNSS_PIL
./scripts/config --module QCOM_RPROC_COMMON
./scripts/config --module QCOM_SYSMON
./scripts/config --disable QCOM_PD_MAPPER
./scripts/config --module QCOM_PDR_HELPERS
./scripts/config --module QCOM_PDR_MSG
./scripts/config --enable QCOM_RMTFS_MEM
./scripts/config --module QCOM_MDT_LOADER
./scripts/config --module QCOM_QMI_HELPERS
./scripts/config --enable QCOM_AOSS_QMP
./scripts/config --enable RESET_QCOM_AOSS
./scripts/config --enable RESET_QCOM_PDC
./scripts/config --enable RPMSG_QCOM_SMD
./scripts/config --enable RPMSG_QCOM_GLINK
./scripts/config --enable RPMSG_QCOM_GLINK_RPM
./scripts/config --module RPMSG_QCOM_GLINK_SMEM
./scripts/config --module QRTR
./scripts/config --module QRTR_SMD
./scripts/config --module QRTR_TUN
./scripts/config --module QRTR_MHI
./scripts/config --module MHI_BUS
./scripts/config --module QCOM_PIL_INFO
./scripts/config --module QCOM_IPA
./scripts/config --disable LOCALVERSION_AUTO

# Optional: open menuconfig for manual adjustments
if [ "${1:-}" = "menuconfig" ]; then
    make menuconfig
fi

# Finalize config
make olddefconfig

echo "[4/6] Kernel configured."

# -------------------------------------------------------
# Step 5: Build kernel, DTBs, and modules
# -------------------------------------------------------
echo "[5/6] Building kernel (this will take a while)..."
if [ "$KERNEL_SCOPE" = "display" ]; then
    BUILD_TARGETS=(Image.gz dtbs)
else
    BUILD_TARGETS=(Image.gz dtbs modules)
fi

if ! make -j"$BUILD_JOBS" "${BUILD_TARGETS[@]}" 2>&1 | tee "$OUTPUT_DIR/build.log"; then
    echo '' | tee -a "$OUTPUT_DIR/build.log"
    echo 'Parallel build failed under WSL, retrying with -j1 for a stable artifact...' | tee -a "$OUTPUT_DIR/build.log"
    make olddefconfig 2>&1 | tee -a "$OUTPUT_DIR/build.log"
    make prepare 2>&1 | tee -a "$OUTPUT_DIR/build.log"
    if [ "$KERNEL_SCOPE" = "full" ]; then
        make modules_prepare 2>&1 | tee -a "$OUTPUT_DIR/build.log"
    fi
    make -j1 "${BUILD_TARGETS[@]}" 2>&1 | tee -a "$OUTPUT_DIR/build.log"
fi

echo "[5/6] Build complete."

# -------------------------------------------------------
# Step 6: Install modules and collect outputs
# -------------------------------------------------------
echo "[6/6] Collecting build outputs..."

KERNEL_RELEASE=$(make -s kernelrelease)
if [ "$KERNEL_SCOPE" = "full" ]; then
    rm -rf "$OUTPUT_DIR/modules_install"
    make INSTALL_MOD_PATH="$OUTPUT_DIR/modules_install" modules_install
    echo "$KERNEL_RELEASE" > "$OUTPUT_DIR/kernel.release"
    rm -f "$OUTPUT_DIR/display.kernel-release"

    for module_path in \
        "kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko" \
        "kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko" \
        "kernel/drivers/remoteproc/qcom_q6v5.ko" \
        "kernel/drivers/remoteproc/qcom_q6v5_mss.ko" \
        "kernel/drivers/remoteproc/qcom_q6v5_pas.ko" \
        "kernel/drivers/remoteproc/qcom_wcnss_pil.ko" \
        "kernel/drivers/net/ipa/ipa.ko"; do
        installed_module="$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE/$module_path"
        if [ ! -f "$installed_module" ] && [ ! -f "$installed_module.zst" ]; then
            echo "ERROR: expected SDM845 Wi-Fi/MSS module missing after modules_install: $module_path"
            exit 1
        fi
    done
else
    rm -rf "$OUTPUT_DIR/modules_install"
    rm -f "$OUTPUT_DIR/kernel.release"
    echo "$KERNEL_RELEASE" > "$OUTPUT_DIR/display.kernel-release"
fi

# Copy kernel image
cp -v arch/arm64/boot/Image.gz "$OUTPUT_DIR/Image.gz"

# Copy DTB
cp -v arch/arm64/boot/dts/qcom/sdm845-razer-aura.dtb "$OUTPUT_DIR/sdm845-razer-aura.dtb"

# Create concatenated Image.gz-dtb (needed for some bootloaders)
cat arch/arm64/boot/Image.gz \
    arch/arm64/boot/dts/qcom/sdm845-razer-aura.dtb \
    > "$OUTPUT_DIR/Image.gz-dtb"

mkdir -p "$WIN_OUTPUT_DIR"
copy_aux_output() {
    local src="$1"
    local dst="$2"

    if ! cp -f "$src" "$dst"; then
        echo "  WARNING: failed to copy $(basename "$src") to Windows output."
        echo "           WSL output remains authoritative for boot packaging: $src"
    fi
}

copy_aux_output "$OUTPUT_DIR/Image.gz" "$WIN_OUTPUT_DIR/Image.gz"
copy_aux_output "$OUTPUT_DIR/sdm845-razer-aura.dtb" "$WIN_OUTPUT_DIR/sdm845-razer-aura.dtb"
copy_aux_output "$OUTPUT_DIR/Image.gz-dtb" "$WIN_OUTPUT_DIR/Image.gz-dtb"
if [ "$KERNEL_SCOPE" = "full" ]; then
    copy_aux_output "$OUTPUT_DIR/kernel.release" "$WIN_OUTPUT_DIR/kernel.release"
    rm -f "$WIN_OUTPUT_DIR/display.kernel-release"
else
    copy_aux_output "$OUTPUT_DIR/display.kernel-release" "$WIN_OUTPUT_DIR/display.kernel-release"
    rm -f "$WIN_OUTPUT_DIR/kernel.release"
fi
echo "mainline" > "$OUTPUT_DIR/kernel.flavor"
copy_aux_output "$OUTPUT_DIR/kernel.flavor" "$WIN_OUTPUT_DIR/kernel.flavor"

echo ""
echo "========================================"
echo " Kernel build complete!"
echo "========================================"
echo ""
echo "Outputs in: $OUTPUT_DIR"
echo "  Image.gz            - Compressed kernel image"
echo "  sdm845-razer-aura.dtb - Device tree blob"
echo "  Image.gz-dtb        - Combined kernel + DTB"
if [ "$KERNEL_SCOPE" = "full" ]; then
    echo "  modules_install/    - Kernel modules"
    echo "  kernel.release      - Kernel release string for rootfs/boot checks"
else
    echo "  display.kernel-release - Display-only compile validation"
    echo "  NOTE: this partial artifact cannot be packaged with rootfs."
fi
echo "  build.log           - Build log"
echo ""
echo "Next: Run bash 03-build-rootfs.sh"
