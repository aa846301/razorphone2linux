#!/bin/bash
# Compute the reusable kernel-core identity. DTS, firmware, and rootfs inputs
# are intentionally excluded because they do not change Image.gz or modules.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_DIR
source "$PROJECT_DIR/config/kernel-source.env"

CACHE_VERSION="${RAZER_KERNEL_CORE_CACHE_VERSION:-2}"
COMPILER_ID="$(aarch64-linux-gnu-gcc -v 2>&1 || echo unavailable)"
SOURCE_TREE_ID="$({
    git -C "$PROJECT_DIR" ls-files -s -- kernel-source/linux |
        LC_ALL=C awk '$4 !~ /^kernel-source\/linux\/arch\/[^/]+\/boot\/dts\//'
} | sha256sum | cut -d' ' -f1)"

{
    printf 'cache_version=%s\n' "$CACHE_VERSION"
    printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
    printf 'kernel_source_tree=%s\n' "$SOURCE_TREE_ID"
    printf 'compiler=%s\n' "$COMPILER_ID"
    printf 'image_profile=%s\n' "${RAZER_IMAGE_PROFILE:-base}"
    printf 'native_panel=%s\n' "${RAZER_DISPLAY_NATIVE_PANEL:-0}"
    printf 'native_panel_nodes=%s\n' "${RAZER_DISPLAY_NATIVE_PANEL_NODES:-}"
    printf 'native_panel_builtin=%s\n' "${RAZER_DISPLAY_NATIVE_PANEL_BUILTIN:-0}"
    printf 'early_debug_log=%s\n' "${RAZER_EARLY_DEBUG_LOG:-0}"

    for file in \
        config/kernel-source.env \
        config/razer-aura.config \
        panel-driver/panel-novatek-nt36830.c; do
        sha256sum "$PROJECT_DIR/$file"
    done

    # Hash the working-tree patch inputs, including newly created patches
    # that have not been staged yet during local bring-up.
    while IFS= read -r -d '' file; do
        sha256sum "$file"
    done < <(
        find "$PROJECT_DIR/kernel-patches" -maxdepth 1 -type f \
            -name '*.patch' -print0 | sort -z
    )
} | sha256sum | cut -d' ' -f1
