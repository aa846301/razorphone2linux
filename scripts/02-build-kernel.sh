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
IMAGE_PROFILE="${RAZER_IMAGE_PROFILE:-base}"
case "$IMAGE_PROFILE" in
    base) ;;
    *) echo "ERROR: RAZER_IMAGE_PROFILE must be base."; exit 2 ;;
esac
OUTPUT_DIR="$WORKDIR/output/$IMAGE_PROFILE"
WIN_OUTPUT_DIR="$PROJECT_DIR/output/$IMAGE_PROFILE"

mkdir -p "$OUTPUT_DIR" "$WIN_OUTPUT_DIR"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
# Suppress the kernel build system's automatic "+" suffix for an integration
# commit that is intentionally not an upstream annotated release tag.
export LOCALVERSION=""

CORE_KEY_FILE="$OUTPUT_DIR/kernel.core-key"
EXPECTED_CORE_KEY="$(RAZER_IMAGE_PROFILE="$IMAGE_PROFILE" \
    bash "$PROJECT_DIR/scripts/kernel-core-cache-key.sh")"
REUSE_KERNEL_CORE=0

CCACHE_DIR="${RAZER_CCACHE_DIR:-$WORKDIR/cache/ccache}"
if command -v ccache >/dev/null 2>&1; then
    CCACHE_EXE="$(command -v ccache)"
    CCACHE_BIN_DIR="$WORKDIR/cache/ccache-bin"
    mkdir -p "$CCACHE_DIR"
    mkdir -p "$CCACHE_BIN_DIR"
    for compiler in gcc g++ "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}g++"; do
        ln -sfn "$CCACHE_EXE" "$CCACHE_BIN_DIR/$compiler"
    done
    export CCACHE_DIR
    export CCACHE_BASEDIR="$KERNEL_DIR"
    export CCACHE_NOHASHDIR=true
    export PATH="$CCACHE_BIN_DIR:$PATH"
    ccache --max-size "${RAZER_CCACHE_MAX_SIZE:-2G}" >/dev/null
fi

# Default to 8 jobs (12-core host: leaves headroom for the desktop; the old
# hard cap of 4 wasted most of the machine). Override with RAZER_MAX_JOBS.
MAX_JOBS="${RAZER_MAX_JOBS:-8}"
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
echo "Parallel jobs: $BUILD_JOBS"
echo ""

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "ERROR: missing kernel checkout. Run scripts/01-setup-environment.sh first."
    exit 1
fi

if [ -f "$KERNEL_DIR/.razer-source-snapshot" ]; then
    echo "WARNING: using in-repository kernel source snapshot; pinned commit ancestry check skipped."
elif ! git -C "$KERNEL_DIR" merge-base --is-ancestor "$KERNEL_COMMIT" HEAD; then
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
DTS_DST="$KERNEL_DIR/arch/arm64/boot/dts/qcom/sdm845-razer-aura.dts"
cp -v "$PROJECT_DIR/dts/sdm845-razer-aura.dts" "$DTS_DST"

# Keep the checked-in DTS on the proven simplefb path by default.
# Native panel bring-up is opt-in so test artifacts can enable MDSS/DSI
# without making every normal build seize the bootloader framebuffer.
#
# RAZER_DISPLAY_NATIVE_PANEL=1 enables the whole native display path.
# RAZER_DISPLAY_NATIVE_PANEL_NODES accepts a comma/space separated subset, for
# staged debugging, for example:
#   RAZER_DISPLAY_NATIVE_PANEL_NODES=dispcc
#   RAZER_DISPLAY_NATIVE_PANEL_NODES="dispcc,mdss,mdss_mdp"
PANEL_NODE_LIST="${RAZER_DISPLAY_NATIVE_PANEL_NODES:-}"
if [ "${RAZER_DISPLAY_NATIVE_PANEL:-0}" = "1" ] && [ -z "$PANEL_NODE_LIST" ]; then
    PANEL_NODE_LIST="dispcc mdss mdss_mdp mdss_dsi0 mdss_dsi0_phy mdss_dsi1 mdss_dsi1_phy gpu"
fi

if [ -n "$PANEL_NODE_LIST" ]; then
    echo "  Enabling native display DTS nodes for this build: $PANEL_NODE_LIST"
    python3 - "$DTS_DST" "$PANEL_NODE_LIST" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
labels = [item for item in re.split(r"[\s,]+", sys.argv[2].strip()) if item]
text = path.read_text()

valid = {
    "dispcc",
    "mdss",
    "mdss_mdp",
    "mdss_dsi0",
    "mdss_dsi0_phy",
    "mdss_dsi1",
    "mdss_dsi1_phy",
    "gpu",
}

unknown = sorted(set(labels) - valid)
if unknown:
    raise SystemExit(f"unknown native display DTS node(s): {', '.join(unknown)}")

for label in labels:
    pattern = re.compile(r"(&" + re.escape(label) + r"\s*\{.*?\n\};)", re.S)

    def enable(match):
        block = match.group(1)
        if re.search(r'status\s*=\s*"[^"]+";', block):
            block = re.sub(r'status\s*=\s*"[^"]+";', 'status = "okay";', block, count=1)
        else:
            block = block.replace("{", '{\n\tstatus = "okay";', 1)
        return block

    text, count = pattern.subn(enable, text, count=1)
    if count != 1:
        raise SystemExit(f"failed to enable &{label} in {path}")

path.write_text(text)
PY
fi

# Copy panel driver
cp -v "$PROJECT_DIR/panel-driver/panel-novatek-nt36830.c" \
    "$KERNEL_DIR/drivers/gpu/drm/panel/panel-novatek-nt36830.c"

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
        normalized_patch="$(mktemp)"
        sed 's/\r$//' "$patch_file" > "$normalized_patch"
        if git -C "$KERNEL_DIR" apply --recount --reverse --check "$normalized_patch" >/dev/null 2>&1; then
            echo "  $patch_name already applied."
        else
            git -C "$KERNEL_DIR" apply --recount --check "$normalized_patch"
            git -C "$KERNEL_DIR" apply --recount "$normalized_patch"
            echo "  Applied $patch_name"
        fi
        rm -f "$normalized_patch"
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
        git -C "$KERNEL_DIR" switch -c razerphone2linux/integration
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

# Apply the single canonical config fragment.
CONFIG_FRAGMENT="$PROJECT_DIR/config/razer-aura.config"
if [ ! -f "$CONFIG_FRAGMENT" ]; then
    echo "ERROR: missing canonical config fragment: $CONFIG_FRAGMENT"
    exit 1
fi

echo "Applying Razer Phone 2 config fragment: $CONFIG_FRAGMENT"
sed 's/\r$//' "$CONFIG_FRAGMENT" > /tmp/razer_aura_fragment.config
./scripts/kconfig/merge_config.sh -m .config /tmp/razer_aura_fragment.config

if [ "${RAZER_DISPLAY_NATIVE_PANEL:-0}" = "1" ] || [ "${RAZER_DISPLAY_NATIVE_PANEL_BUILTIN:-0}" = "1" ]; then
    echo "Applying native-panel test config overrides."
    # The panel is allowed to be built in -- only WiFi/modem must stay
    # modular. DRM_MSM's own Kconfig has `select QCOM_MDT_LOADER if
    # ARCH_QCOM` unconditionally, so DRM_MSM=y always drags
    # QCOM_MDT_LOADER to =y too. This is a normal, legal Kconfig
    # combination (a =m driver depending on a =y library is completely
    # standard), so qcom_q6v5_mss.ko (kept =m below) SHOULD still load;
    # if it doesn't, that is a real bug to diagnose with dmesg, not
    # something to route around by making WiFi builtin.
    # DRM_MSM can only be built in when optional QCOM_OCMEM is built in or off;
    # turn it off for SDM845 panel tests so olddefconfig does not force
    # DRM_MSM back to a module.
    ./scripts/config --disable QCOM_OCMEM
    ./scripts/config --enable DRM_MSM
    ./scripts/config --enable DRM_PANEL_NOVATEK_NT36830
fi

if [ "${RAZER_EARLY_DEBUG_LOG:-0}" = "1" ]; then
    echo "Applying early-crash log retention config overrides."
    # Keep these opt-in: they are for bring-up artifacts that may hang or reboot
    # before userspace can load modules.  In particular, build the SDM845 APSS
    # watchdog driver into the kernel so a bootloader-enabled watchdog is
    # claimed before an early display/DRM failure can silently reset the phone.
    ./scripts/config --enable QCOM_WDT
    ./scripts/config --enable PSTORE
    ./scripts/config --enable PSTORE_CONSOLE
    ./scripts/config --enable PSTORE_RAM
    ./scripts/config --set-val PSTORE_DEFAULT_KMSG_BYTES 262144
    ./scripts/config --enable MAGIC_SYSRQ
fi

# Keep the Wi-Fi/MSS chain modular so the compressed kernel stays within ABL's
# size limit. Boot packaging verifies the exact module-tree fingerprint, so a
# rebuilt boot kernel cannot be paired with stale same-release rootfs modules.
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
# Materialize generated config headers before reading kernelrelease. Without
# this, kernelrelease can reflect stale defconfig state until the first build.
make -s prepare

echo "[4/6] Kernel configured."

KERNEL_RELEASE=$(make -s kernelrelease)
MODULE_TREE="$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE"

module_tree_fingerprint() {
    (
        cd "$MODULE_TREE"
        find . -type f -name '*.ko' -print0 |
            LC_ALL=C sort -z |
            xargs -0 -r sha256sum
    ) | sha256sum | cut -d' ' -f1
}

CORE_CACHE_REASON=""
if [ "${RAZER_FORCE_KERNEL_REBUILD:-0}" = "1" ]; then
    CORE_CACHE_REASON="forced rebuild requested"
elif [ ! -s "$CORE_KEY_FILE" ]; then
    CORE_CACHE_REASON="kernel.core-key is missing"
elif [ "$(tr -d '\r\n' < "$CORE_KEY_FILE")" != "$EXPECTED_CORE_KEY" ]; then
    CORE_CACHE_REASON="kernel core identity differs"
elif [ ! -s "$OUTPUT_DIR/Image.gz" ]; then
    CORE_CACHE_REASON="Image.gz is missing"
elif [ ! -s "$OUTPUT_DIR/kernel.config" ]; then
    CORE_CACHE_REASON="kernel.config is missing"
elif [ ! -s "$OUTPUT_DIR/kernel.release" ]; then
    CORE_CACHE_REASON="kernel.release is missing"
elif [ "$(tr -d '\r\n' < "$OUTPUT_DIR/kernel.release")" != "$KERNEL_RELEASE" ]; then
    CORE_CACHE_REASON="kernel release differs"
elif [ ! -s "$OUTPUT_DIR/kernel.modules-fingerprint" ]; then
    CORE_CACHE_REASON="module fingerprint is missing"
elif [ ! -d "$MODULE_TREE" ]; then
    CORE_CACHE_REASON="module tree is missing"
elif ! cmp -s .config "$OUTPUT_DIR/kernel.config"; then
    CORE_CACHE_REASON="generated config differs"
elif [ "$(module_tree_fingerprint)" != "$(tr -d '\r\n' < "$OUTPUT_DIR/kernel.modules-fingerprint")" ]; then
    CORE_CACHE_REASON="module tree fingerprint differs"
fi

if [ -z "$CORE_CACHE_REASON" ]; then
    REUSE_KERNEL_CORE=1
    echo "  Kernel core identity matched; reusing Image.gz and modules."
else
    echo "  Kernel core cache rejected: $CORE_CACHE_REASON."
    echo "  Full build required."
fi

# -------------------------------------------------------
# Step 5: Build kernel, DTBs, and modules
# -------------------------------------------------------
if [ "$REUSE_KERNEL_CORE" = "1" ]; then
    echo "[5/6] Building DTBs only (kernel core cache hit)..."
    make -j"$BUILD_JOBS" dtbs 2>&1 | tee "$OUTPUT_DIR/build.log"
else
    echo "[5/6] Building kernel, DTBs, and modules (this will take a while)..."
    if ! make -j"$BUILD_JOBS" Image.gz dtbs modules 2>&1 | tee "$OUTPUT_DIR/build.log"; then
        echo '' | tee -a "$OUTPUT_DIR/build.log"
        echo 'Parallel build failed under WSL, retrying with -j1 for a stable artifact...' | tee -a "$OUTPUT_DIR/build.log"
        make olddefconfig 2>&1 | tee -a "$OUTPUT_DIR/build.log"
        make prepare modules_prepare 2>&1 | tee -a "$OUTPUT_DIR/build.log"
        make -j1 Image.gz dtbs modules 2>&1 | tee -a "$OUTPUT_DIR/build.log"
    fi
fi

echo "[5/6] Build complete."
FINAL_KERNEL_RELEASE=$(make -s kernelrelease)
if [ "$FINAL_KERNEL_RELEASE" != "$KERNEL_RELEASE" ]; then
    echo "ERROR: kernel release changed during the build." >&2
    echo "Before build: $KERNEL_RELEASE" >&2
    echo "After build:  $FINAL_KERNEL_RELEASE" >&2
    exit 1
fi
if command -v ccache >/dev/null 2>&1; then
    ccache --show-stats
fi

# -------------------------------------------------------
# Step 6: Install modules and collect outputs
# -------------------------------------------------------
echo "[6/6] Collecting build outputs..."

if [ "$REUSE_KERNEL_CORE" != "1" ]; then
    rm -rf "$OUTPUT_DIR/modules_install"
    # INSTALL_MOD_STRIP: the config carries DEBUG_INFO=y, and unstripped .ko
    # files balloon each module tree to ~330MB (the rootfs ships two kernels).
    # Stripped trees are ~1/4 the size; debug symbols stay in the build tree.
    make INSTALL_MOD_PATH="$OUTPUT_DIR/modules_install" INSTALL_MOD_STRIP=1 modules_install

    echo "$KERNEL_RELEASE" > "$OUTPUT_DIR/kernel.release"
    cp -f "$KERNEL_DIR/.config" "$OUTPUT_DIR/config-$KERNEL_RELEASE"
    cp -f "$KERNEL_DIR/.config" "$OUTPUT_DIR/kernel.config"
    MODULE_TREE="$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE"
    module_tree_fingerprint > "$OUTPUT_DIR/kernel.modules-fingerprint"
    cp -v arch/arm64/boot/Image.gz "$OUTPUT_DIR/Image.gz"
    printf '%s\n' "$EXPECTED_CORE_KEY" > "$CORE_KEY_FILE"
else
    cp -f "$OUTPUT_DIR/kernel.config" "$OUTPUT_DIR/config-$KERNEL_RELEASE"
fi

# Accept either built-in or modular Wi-Fi/MSS drivers, then fingerprint the
# exact module tree so boot packaging can reject a stale same-release rootfs.
MODULES_BUILTIN="$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE/modules.builtin"
for builtin_path in \
    "kernel/drivers/net/wireless/ath/ath10k/ath10k_core.ko" \
    "kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko" \
    "kernel/drivers/remoteproc/qcom_q6v5.ko" \
    "kernel/drivers/remoteproc/qcom_q6v5_mss.ko" \
    "kernel/drivers/remoteproc/qcom_q6v5_pas.ko" \
    "kernel/drivers/remoteproc/qcom_wcnss_pil.ko" \
    "kernel/drivers/net/ipa/ipa.ko"; do
    if ! grep -qx "$builtin_path" "$MODULES_BUILTIN" && \
       [ ! -f "$OUTPUT_DIR/modules_install/lib/modules/$KERNEL_RELEASE/$builtin_path" ]; then
        echo "ERROR: SDM845 Wi-Fi/MSS driver missing (neither builtin nor module): $builtin_path"
        exit 1
    fi
done

# Copy DTB
cp -v arch/arm64/boot/dts/qcom/sdm845-razer-aura.dtb "$OUTPUT_DIR/sdm845-razer-aura.dtb"

# Create concatenated Image.gz-dtb (needed for some bootloaders)
cat "$OUTPUT_DIR/Image.gz" \
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
copy_aux_output "$OUTPUT_DIR/kernel.release" "$WIN_OUTPUT_DIR/kernel.release"
copy_aux_output "$OUTPUT_DIR/kernel.modules-fingerprint" "$WIN_OUTPUT_DIR/kernel.modules-fingerprint"
copy_aux_output "$OUTPUT_DIR/kernel.core-key" "$WIN_OUTPUT_DIR/kernel.core-key"
copy_aux_output "$OUTPUT_DIR/config-$KERNEL_RELEASE" "$WIN_OUTPUT_DIR/config-$KERNEL_RELEASE"
copy_aux_output "$OUTPUT_DIR/kernel.config" "$WIN_OUTPUT_DIR/kernel.config"
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
echo "  modules_install/    - Kernel modules"
echo "  kernel.release      - Kernel release string for rootfs/boot checks"
echo "  build.log           - Build log"
echo ""
echo "Next: Run bash 03-build-rootfs.sh"
