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
- PMI8998 SMB2 charger, fuel gauge, and RRADC are enabled. A rootfs service
  uses the standard SMB2 `charge_behaviour` power-supply interface to prefer
  external input above 40%. A charge cycle starts at 40%, remains latched, and
  stops at 80%. The DTS keeps a conservative 2 A charge limit.
- The base image blanks the panel after boot on normal images, and keeps a
  console mode available for display debugging.
- USB NCM networking and SSH work at `192.168.137.133`.
- WiFi works through MSS/WLFW, `rmtfs`, userspace `pd-mapper`, patched
  `tqftpserv`, Razer FIH NV sharing, and the ath10k host-capability quirk.

## Hardware Support Checklist

This follows the feature categories commonly used by postmarketOS device
pages. Checked items have been validated on hardware; partial features are
split so the remaining work stays visible.

- [x] Booting and fastboot flashing
- [x] Internal UFS storage and rootfs
- [x] Native dual-DSI/DSC display and touchscreen
- [x] Panel blanking and backlight off after boot
- [x] Power and volume keys; orderly Linux power-off (attached VBUS may cold boot it again)
- [x] Adreno 630 GPU acceleration with proprietary firmware
- [x] USB NCM networking and SSH
- [x] WiFi scanning, connection, and reconnect
- [x] Battery capacity, voltage, current, and temperature reporting
- [x] Wired charging, USB-PD sink negotiation, and RRADC input telemetry
- [x] External-power-first 40-80% charge policy
- [x] Bluetooth firmware, controller initialization, and device scanning
- [ ] Bluetooth pairing and reconnect validation
- [ ] Bluetooth audio
- [ ] System suspend and deep sleep (panel blanking is supported)
- [ ] Speaker, microphones, earpiece, and USB-C audio
- [ ] Front and rear cameras
- [ ] GNSS/GPS
- [ ] Modem calls, SMS, and mobile data
- [ ] NFC
- [ ] USB OTG/host mode
- [ ] USB 3 SuperSpeed data (fastboot currently uses USB 2)
- [ ] DisplayPort alternate mode
- [ ] Accelerometer, gyroscope, magnetometer, proximity, and ambient light
- [ ] Haptics/vibrator and notification/Chroma LEDs
- [ ] Fingerprint reader
- [ ] Qi wireless charging
- [ ] Full-disk encryption integration

## External Power And Charging

`razer-charge-limits.service` starts in `external-power` mode. While a USB
input is online and battery capacity is above 40%, it selects
`inhibit-charge`: the USB power path stays active, but the battery is not
charged. At 40% or below it starts a latched `charge-cycle`, selects `auto`,
and keeps charging until capacity reaches 80%. It then returns to
`external-power` mode. The latch survives service and device restarts in
`/var/lib/razer-charge-limits/state`.

This policy does not physically disconnect the battery. The battery remains
available for load transients and will supplement a weak USB source, such as a
low-current PC port. Check the active policy and electrical flow with:

```bash
cat /sys/class/power_supply/pmi8998-charger/online
cat /sys/class/power_supply/pmi8998-charger/charge_behaviour
cat /sys/class/power_supply/qcom-battery/current_now
cat /var/lib/razer-charge-limits/state
```

## Experimental Control Panel

The manually deployed DRM/KMS panel under
`experiments/razer-control-panel/` shows RRADC USB input voltage, current and
power separately from battery current. It also provides WiFi setup and a
temporary `CHARGE TO 100%` test override. It is tracked for development but is
deliberately not installed by local builds or GitHub Actions releases; see its
[README](experiments/razer-control-panel/README.md) for deployment commands.

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

The `Build flashable image` workflow runs on `master` pushes to populate
default-branch caches, and on `v*` tag pushes to publish releases. GitHub
Actions caches are scoped by Git ref, so a cache created by one release tag is
not directly visible to the next tag. Let the matching `master` run complete
before pushing its release tag; the tag run can then reuse kernel core,
`ccache`, extracted firmware, and rootfs caches from the default branch.

The YAML spells out the release recipe on GitHub's `ubuntu-24.04-arm` hosted
runner: select the tag profile, import firmware, build the native-panel/GPU
kernel, build the ARM64 rootfs, package `boot.img`, and upload one release zip
containing only the flashable images: `boot.img`, `rootfs-sparse.img`, and
`vbmeta_disabled.img`. A `master` run uploads an Actions artifact for
validation but does not create a GitHub Release; only a `v*` tag does that.

Set `RAZER_FACTORY_ZIP_URL` as a repository variable or secret pointing to
`aura-p-release-3201-user-full.zip`. Use a variable for a public upstream URL,
or a secret plus optional `RAZER_FACTORY_ZIP_AUTH_HEADER` for a private
large-file URL. Tags choose userspace automatically: `v*`, `v*-ha`, and
`v*-3dprinter`.

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
