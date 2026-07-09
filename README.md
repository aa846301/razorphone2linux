# Razer Phone 2 Linux

[繁體中文](README.zh-TW.md)

Mainline Linux for the Razer Phone 2 (`aura`, Qualcomm SDM845). The default
release image is an app-free hardware platform: GPU-capable, WiFi-capable,
charge-limited, and ready for users to install their own software.

## Current Status

- Kernel baseline: SDM845 mainline `sdm845/7.1-dev`, pinned at
  `85f1df2a4ec7` (`7.1.0-rc1`).
- Native NT36830 dual-DSI/DSC display is implemented through the opt-in
  native-panel build path. The DSI/DSC configuration is aligned with Razer LK
  factory behavior.
- Adreno 630 hardware GL works through freedreno when the stock Razer
  `a630_zap.*` firmware and linux-firmware `a630_sqe.fw` are present.
- PMI8998 SMB2 charger, fuel gauge, and RRADC are enabled. The rootfs applies
  40%/80% charge thresholds when the kernel exposes writable power-supply
  controls, while the DTS keeps a conservative 2 A charge limit.
- The base image blanks the panel after boot on normal images, and keeps a
  console mode available for display debugging.
- USB NCM networking and SSH work at `192.168.137.133`.
- WiFi works through MSS/WLFW, `rmtfs`, userspace `pd-mapper`, patched
  `tqftpserv`, Razer FIH NV sharing, and the ath10k host-capability quirk.

Historical bring-up notes live in `doc/`. The validated WebKitGTK/Epiphany +
sway Home Assistant kiosk prototype is archived under
`rootfs-scripts/kiosk-prototype/`; it is installed only by the `ha` userspace
profile, not by the default image.

## Release Profiles

The hardware image profile is always `base`. Optional app stacks are selected
with `RAZER_USERSPACE_PROFILE` or by release tag suffix:

- `v1.0.0` -> `none`: app-free platform image.
- `v1.0.0-ha` -> `ha`: Home Assistant kiosk packages and prototype.
- `v1.0.0-3dprinter` -> `3dprinter`: Klipper/Moonraker/HelixScreen stack.

## Build

Prerequisites:

- Windows 11 with WSL2 Ubuntu 24.04.
- At least 30 GB free space.
- Android Platform Tools on Windows.
- An unlocked Razer Phone 2 bootloader.
- The Razer factory package `aura-p-release-3201-user-full.zip` or its
  `modem.img`. Proprietary firmware is not stored in Git.

Set up the build environment:

```powershell
git clone https://github.com/aa846301/razorphone2linux.git
cd razorphone2linux
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/01-setup-environment.sh"
```

Extract firmware:

```powershell
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/extract-modem-firmware.sh"
```

Build the default app-free native-panel image:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel
```

Build an optional userspace profile locally:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel -UserspaceProfile ha
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel -UserspaceProfile 3dprinter
```

Artifacts are written to `output/base/`. The boot packager refuses to produce
`boot.img` if the kernel and rootfs module releases do not match.

## GitHub Actions

The `Build flashable image` workflow runs only when a `v*` tag is pushed. It
builds the native-panel image and uploads
`boot.img`, `rootfs-sparse.img`, `vbmeta_disabled.img`, initramfs, release
markers, `userspace.profile`, and `SHA256SUMS`.

Set the repository secret `RAZER_FACTORY_ZIP_URL` to a private URL for
`aura-p-release-3201-user-full.zip`. Tags choose userspace automatically:
`v*`, `v*-ha`, and `v*-3dprinter`.

## Flash

Warning: flashing userdata erases Android user data. If disabled vbmeta has not
already been flashed once:

```powershell
fastboot --disable-verity --disable-verification flash vbmeta output\base\vbmeta_disabled.img
```

Routine flash:

```powershell
fastboot flash boot_a output\base\boot.img && fastboot flash boot_b output\base\boot.img && fastboot flash userdata output\base\rootfs-sparse.img && fastboot reboot
```

Default login is `klipper` / `klipper`. Change it after first boot.

## Useful Checks

```bash
nmcli device
nmcli device wifi list
systemctl status razer-charge-limits razer-panel-idle-blank razer-wifi-ready
journalctl -b -u rmtfs -u tqftpserv -u razer-wifi-ready
```

See [FLASH-GUIDE.md](FLASH-GUIDE.md), [RECOVERY.md](RECOVERY.md), and
[doc/ci-and-release.md](doc/ci-and-release.md) for operational details.
