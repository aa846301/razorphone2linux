#!/bin/bash
# Produce an explicitly non-send-ready RFC patch bundle from project files.
# The human submitter must review, rebase, test, and add their own Signed-off-by
# before sending any patch.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/config/kernel-source.env"
WORKDIR="${RAZER_WORKDIR:-$HOME/razorphone2linux}"
KERNEL_DIR="$WORKDIR/kernel/linux"
RFC_TREE="$WORKDIR/upstream-rfc-worktree"
OUT_DIR="$PROJECT_DIR/upstream/rfc-v0"

case "$RFC_TREE" in
    "$WORKDIR"/*) ;;
    *) echo "ERROR: unsafe RFC worktree path: $RFC_TREE"; exit 1 ;;
esac

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "ERROR: kernel checkout missing: $KERNEL_DIR"
    exit 1
fi

git -C "$KERNEL_DIR" worktree remove --force "$RFC_TREE" 2>/dev/null || true
git -C "$KERNEL_DIR" worktree add --detach "$RFC_TREE" "$KERNEL_COMMIT"

cleanup() {
    git -C "$KERNEL_DIR" worktree remove --force "$RFC_TREE" 2>/dev/null || true
}
trap cleanup EXIT

AUTHOR_NAME="${UPSTREAM_AUTHOR_NAME:-$(git -C "$PROJECT_DIR" config user.name || true)}"
AUTHOR_EMAIL="${UPSTREAM_AUTHOR_EMAIL:-$(git -C "$PROJECT_DIR" config user.email || true)}"
if [ -z "$AUTHOR_NAME" ] || [ -z "$AUTHOR_EMAIL" ]; then
    echo "ERROR: set UPSTREAM_AUTHOR_NAME and UPSTREAM_AUTHOR_EMAIL."
    echo "These identify draft commits only; the script still does not add DCO sign-offs."
    exit 1
fi
git -C "$RFC_TREE" config user.name "$AUTHOR_NAME"
git -C "$RFC_TREE" config user.email "$AUTHOR_EMAIL"

# 1/3: Panel binding and driver.
install -m 0644 "$PROJECT_DIR/panel-driver/panel-novatek-nt36830.c" \
    "$RFC_TREE/drivers/gpu/drm/panel/panel-novatek-nt36830.c"
install -m 0644 "$PROJECT_DIR/panel-driver/novatek,nt36830.yaml" \
    "$RFC_TREE/Documentation/devicetree/bindings/display/panel/novatek,nt36830.yaml"
if ! grep -q DRM_PANEL_NOVATEK_NT36830 "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"; then
    printf '\nconfig DRM_PANEL_NOVATEK_NT36830\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\ttristate "Novatek NT36830 panel"\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\tdepends on OF && DRM_MIPI_DSI\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\tselect DRM_DISPLAY_HELPER\n\tselect DRM_DISPLAY_DSC_HELPER\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\thelp\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\t  Say Y or M here if you want to enable support for the\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\t  Novatek NT36830 dual-DSI DSC panel used by the Razer\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
    printf '\t  Phone 2. The panel is attached to Qualcomm MDSS DSI.\n' >> "$RFC_TREE/drivers/gpu/drm/panel/Kconfig"
fi
if ! grep -q panel-novatek-nt36830 "$RFC_TREE/drivers/gpu/drm/panel/Makefile"; then
    printf 'obj-$(CONFIG_DRM_PANEL_NOVATEK_NT36830) += panel-novatek-nt36830.o\n' \
        >> "$RFC_TREE/drivers/gpu/drm/panel/Makefile"
fi
git -C "$RFC_TREE" add drivers/gpu/drm/panel \
    Documentation/devicetree/bindings/display/panel/novatek,nt36830.yaml
git -C "$RFC_TREE" commit -m "drm/panel: add Novatek NT36830 support" \
    -m "Add a binding and dual-DSI DSC panel driver for the Razer Phone 2." \
    -m "This is an RFC draft pending physical native scanout validation." \
    -m "Assisted-by: Codex:gpt-5"

# 2/3: Functional WiFi/MSS delta and its proposed binding.
git -C "$RFC_TREE" apply \
    "$PROJECT_DIR/kernel-patches/0004-dt-bindings-remoteproc-document-fih-nv-memory.patch"
git -C "$RFC_TREE" apply \
    "$PROJECT_DIR/kernel-patches/0001-remoteproc-qcom-share-razer-fih-nv-with-mss.patch"
git -C "$RFC_TREE" add drivers/remoteproc/qcom_q6v5_mss.c \
    Documentation/devicetree/bindings/remoteproc/qcom,msm8996-mss-pil.yaml
git -C "$RFC_TREE" commit -m "remoteproc: qcom_q6v5_mss: share optional FIH NV memory" \
    -m "Share the optional Razer/FIH NV reserved-memory region with MSS." \
    -m "Document the proposed DT property for maintainer review." \
    -m "Assisted-by: Codex:gpt-5"

# 3/3: Board DTS last, as required by DT submission guidance.
git -C "$RFC_TREE" apply \
    "$PROJECT_DIR/kernel-patches/0002-dt-bindings-add-razer-vendor-prefix.patch"
git -C "$RFC_TREE" apply \
    "$PROJECT_DIR/kernel-patches/0003-dt-bindings-arm-qcom-add-razer-phone-2.patch"
install -m 0644 "$PROJECT_DIR/dts/sdm845-razer-aura.dts" \
    "$RFC_TREE/arch/arm64/boot/dts/qcom/sdm845-razer-aura.dts"
if ! grep -q sdm845-razer-aura "$RFC_TREE/arch/arm64/boot/dts/qcom/Makefile"; then
    printf 'dtb-$(CONFIG_ARCH_QCOM) += sdm845-razer-aura.dtb\n' \
        >> "$RFC_TREE/arch/arm64/boot/dts/qcom/Makefile"
fi
git -C "$RFC_TREE" add arch/arm64/boot/dts/qcom \
    Documentation/devicetree/bindings/arm/qcom.yaml \
    Documentation/devicetree/bindings/vendor-prefixes.yaml
git -C "$RFC_TREE" commit -m "arm64: dts: qcom: add initial Razer Phone 2 support" \
    -m "Add an RFC board description for the SDM845-based Razer Phone 2." \
    -m "Add the board compatible and Razer vendor prefix bindings." \
    -m "Assisted-by: Codex:gpt-5"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
git -C "$RFC_TREE" format-patch --base="$KERNEL_COMMIT" --cover-letter \
    -o "$OUT_DIR" "$KERNEL_COMMIT"..HEAD
cp -f "$PROJECT_DIR/upstream/0000-cover-letter-rfc.md" \
    "$OUT_DIR/COVER-LETTER-DRAFT.md"

(
    cd "$RFC_TREE"
    CHECKPATCH_PY="$PROJECT_DIR/.tmp/checkpatch-python"
    if ! PYTHONPATH="$CHECKPATCH_PY${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -c 'import ply' >/dev/null 2>&1; then
        python3 -m pip install --target "$CHECKPATCH_PY" ply >/dev/null
    fi
    PYTHONPATH="$CHECKPATCH_PY${PYTHONPATH:+:$PYTHONPATH}" \
        "$RFC_TREE/scripts/checkpatch.pl" --strict "$OUT_DIR"/000[1-9]-*.patch \
        > "$OUT_DIR/checkpatch.txt" 2>&1 || true
    "$RFC_TREE/scripts/get_maintainer.pl" "$OUT_DIR"/000[1-9]-*.patch \
        > "$OUT_DIR/recipients.txt" 2>&1 || true
)

cat > "$OUT_DIR/DO-NOT-SEND.txt" <<'EOF'
This RFC bundle intentionally has no Signed-off-by tags. Do not send it without
review. Read upstream/STATUS.md, rebase to the current maintainer tree, pass all
checks, validate physical display scanout, then let the human submitter add
their own DCO sign-off.
EOF

echo "RFC v0 bundle written to: $OUT_DIR"
