# CI and release workflow

The public repository builds flashable images with GitHub Actions through
`.github/workflows/build-image.yml`. The workflow runs only for pushed `v*`
tags and uses GitHub's `ubuntu-24.04-arm` hosted runner. The workflow file is
the release recipe: parameters and build phases are written directly in YAML,
while the repo scripts remain the local build implementation.

## What the Action does

- Selects `none`, `ha`, or `3dprinter` from the release tag suffix.
- Imports factory firmware from a private large-file URL or pre-populated
  runner path.
- Installs and verifies the Ubuntu 24.04 arm64 build toolchain.
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
set `RAZER_FACTORY_ZIP_URL` as a repository variable or secret pointing to
`aura-p-release-3201-user-full.zip`. Use a variable for a public upstream URL,
or a secret plus optional `RAZER_FACTORY_ZIP_AUTH_HEADER` for a private
large-file URL. The Action downloads it during the run, extracts the firmware
into the temporary checkout, and never commits the blobs back to the repository.

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
