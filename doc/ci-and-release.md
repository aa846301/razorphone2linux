# CI and release workflow

The public repository builds flashable images with GitHub Actions through
`.github/workflows/build-image.yml`. The workflow runs only for pushed `v*`
tags.

## What the Action does

- Installs and verifies the Ubuntu 24.04 build toolchain.
- Clones the pinned SDM845 kernel commit from `config/kernel-source.env`.
- Applies the repository DTS, panel driver, kernel patches, config fragments,
  rootfs overlay, and the native-panel/GPU build setting.
- Runs the canonical pipeline: `02-build-kernel.sh`, `03-build-rootfs.sh`, and
  `04-make-boot-image.sh`.
- Uploads `boot.img`, `rootfs-sparse.img`, `vbmeta_disabled.img`, release
  markers, initramfs, `userspace.profile`, and `SHA256SUMS` as workflow
  artifacts from `output/base/`.

## Firmware policy

Razer/Qualcomm proprietary firmware is intentionally not stored in Git. For CI,
set the repository secret `RAZER_FACTORY_ZIP_URL` to a private, access-controlled
URL for `aura-p-release-3201-user-full.zip`. The Action downloads it during the
run, extracts the firmware into the temporary checkout, and never commits the
blobs back to the repository.

If the secret is absent, CI fails before the rootfs build. This keeps public
artifacts from looking complete while missing the firmware required for the
validated native panel/GPU path.

## Manual release flow

1. For the app-free image, tag `v1.0.0`.
2. For Home Assistant, tag `v1.0.0-ha`.
3. For the 3D-printer stack, tag `v1.0.0-3dprinter`.
4. Download both artifacts from the workflow run.
5. Verify `SHA256SUMS` and `userspace.profile`.
6. Flash both A/B boot slots and userdata as documented in `FLASH-GUIDE.md`.
