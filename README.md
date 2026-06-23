# Razer Phone 2 Linux

[繁體中文](README.zh-TW.md)

Mainline Linux bring-up for the Razer Phone 2 (`aura`, Qualcomm SDM845), built
from Windows 11 through WSL Ubuntu 24.04.

## Current status

- Kernel baseline: SDM845 mainline `sdm845/7.1-dev`, pinned at
  `85f1df2a4ec7` (`7.1.0-rc1`).
- Kernel configuration follows the SDM845 tree's tested order:
  `defconfig`, `sdm845.config`, `misc.config`, then the Razer/profile
  fragments.
- Complete kernel releases build cleanly as `7.1.0-rc1-sdm845` and
  `7.1.0-rc1-sdm845-printer`.
- USB NCM networking and SSH work at `192.168.137.133`.
- Boot does not depend on a USB host: early logs stay on `ttyMSM0`, while
  `ttyGS0` remains an optional gadget serial login after userspace starts.
- Touch, Klipper, Moonraker, and HelixScreen work on the preserved 6.16
  recovery baseline.
- A native NT36830 dual-DSI/DSC DRM driver is now implemented and linked into
  the 7.1 build as a module. It exposes 60/120 Hz modes and passes its DT
  binding check. The first 7.1 test keeps MDSS/DSI disabled and uses the
  bootloader framebuffer; native-panel validation is the next separate stage.
- WiFi works through MSS/WLFW, `rmtfs`, userspace `pd-mapper`, patched
  `tqftpserv` v1.2, Razer FIH NV sharing, and the ath10k host-capability quirk.
- HelixScreen waits for `wlan0` at boot, then exposes WiFi through
  NetworkManager.

The production kernel delta is kept in the board DTS, panel driver/binding,
and the top-level files under `kernel-patches/`. Historical diagnostic code
was removed from this branch and remains recoverable from the 6.16 baseline
tag.

See [RECOVERY.md](RECOVERY.md) before display flashing. The exact known-working
6.16 WiFi/Helix boot and rootfs images are stored outside the working tree.

## Prerequisites

- Windows 11 with WSL2 and Ubuntu 24.04.
- At least 30 GB free space.
- An unlocked Razer Phone 2 bootloader.
- Android Platform Tools on Windows for flashing.
- The Razer factory package `aura-p-release-3201-user-full.zip` or its
  `modem.img`. Proprietary firmware is not stored in Git.

## Build from a clean clone

In PowerShell:

```powershell
git clone https://github.com/aa846301/razorphone2linux.git
cd razorphone2linux
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/01-setup-environment.sh"
```

The setup command uses `sudo` only to install WSL build dependencies. It clones
the pinned SDM845 kernel commit recorded in `config/kernel-source.env`.

Copy the factory ZIP into the repository root, then extract firmware:

```powershell
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/extract-modem-firmware.sh"
```

Optionally preserve the phone's factory WiFi MAC instead of using a random MAC:

```powershell
Copy-Item config\device.env.example config\device.env
# Edit RAZER_WLAN_MAC in config\device.env for this phone.
```

The default download source is Canonical's global ARM64 endpoint
`https://ports.ubuntu.com/ubuntu-ports`. Override it only when a closer mirror
is known:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all `
  -Profile printer `
  -UbuntuMirror "https://ports.ubuntu.com/ubuntu-ports"
```

Build the complete 3D-printer image:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -Profile printer
```

Build a smaller general-purpose Linux image without
Klipper/Moonraker/HelixScreen:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -Profile base
```

This wrapper runs the kernel and packaging phases as the normal WSL user and
only the rootfs phase as WSL root, so a long build cannot stop halfway waiting
for a sudo password.

The final userspace is pinned in `config/userspace.env`:

- Klipper `ca8230d505b7ba7fd225bfa6ed9655bc4520e805`
- Moonraker `9008485843740c93e0154ccbdac1fc2b02b03aaa`
- HelixScreen `v0.99.62`

Artifacts are isolated by profile:

- `output/printer/` for the complete Klipper host.
- `output/base/` for the general-purpose image.

The boot packager refuses to proceed if the kernel and rootfs module releases
do not match.

## Incremental development

From Windows/Codex Desktop use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 validate -Profile printer
```

Use `validate-boot` for DTS or boot-command-line-only work. Use `all` whenever
the package list, debootstrap configuration, or Klipper/Moonraker/Helix
installation flow changes.

The canonical implementation is limited to:

- `scripts/02-build-kernel.sh`
- `scripts/03-build-rootfs.sh`
- `scripts/03-refresh-rootfs.sh`
- `scripts/04-make-boot-image.sh`
- `scripts/build-all.sh`
- `scripts/build-all-wsl.ps1`

Historical diagnostic scripts remain available from the recovery tag documented
in `RECOVERY.md`; they are intentionally absent from the active build tree.

For a driver/DT-only compile and link check without building every module:

```bash
RAZER_KERNEL_SCOPE=display RAZER_IMAGE_PROFILE=printer \
  bash scripts/02-build-kernel.sh
```

This produces `display.kernel-release` and deliberately cannot be packaged
with a rootfs. Use the normal full build for flashable artifacts.

## Flash

Warning: flashing userdata erases Android user data. First disable verified
boot if required:

```powershell
fastboot --disable-verity --disable-verification flash vbmeta output\printer\vbmeta_disabled.img
```

Flash both A/B boot slots and userdata in one operation:

```powershell
fastboot flash boot_a output\printer\boot.img && fastboot flash boot_b output\printer\boot.img && fastboot flash userdata output\printer\rootfs-sparse.img && fastboot reboot
```

Default login is `klipper` / `klipper`. Change it after first boot.

## WiFi and HelixScreen

`razer-wifi-ready.service` starts after NetworkManager, `rmtfs`, and
`tqftpserv`, waits up to 75 seconds for `wlan0`, and then allows HelixScreen to
start. This avoids Helix caching “No WiFi hardware” when MSS/WLFW is still
starting.

HelixScreen is configured with `/display/rotate = 90` and
`HELIX_DISPLAY_ROTATION=90`. Version `v0.99.62` calls the setting `rotate`,
not `rotation`, and automatically rotates touch coordinates on fbdev.

Useful checks:

```bash
nmcli device
nmcli device wifi list
systemctl status razer-wifi-ready helixscreen
journalctl -b -u rmtfs -u tqftpserv -u razer-wifi-ready -u helixscreen
```

## Maintenance policy

Project-specific DTS, config, rootfs, and packaging changes should be committed
to this repository on feature branches and merged by pull request. The
generated WSL kernel checkout is disposable; the build creates a local
integration commit solely to produce a clean kernel release.

Submit a separate upstream kernel PR only after a change is generalized,
documented with a DT binding where needed, and useful beyond this repository.
Do not upstream diagnostic logging. The `tqftpserv` Android-path behavior
should eventually be proposed to its upstream project while this repository
keeps a pinned, tested binary for reproducible images.

See [FLASH-GUIDE.md](FLASH-GUIDE.md) for recovery and flashing notes.
See [upstream/STATUS.md](upstream/STATUS.md) before preparing a Linux kernel
mailing-list submission.
