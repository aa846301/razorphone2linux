# Razer Phone 2 (SDM845) - Linux Flashing Guide

## Prerequisites

- **ADB/Fastboot**: Install Android Platform Tools
- **Unlocked bootloader**: `fastboot flashing unlock`
- All image files in `output/` directory:
  - `boot.img` - Kernel + initramfs
  - `rootfs-sparse.img` - Ubuntu 24.04 arm64 + Klipper/Moonraker/HelixScreen
  - `vbmeta_disabled.img` (4 KB) - Disabled verified boot

## Flashing Steps

### 1. Boot into Fastboot Mode

```
adb reboot bootloader
```

Or power off, then hold **Volume Down + Power** until fastboot screen appears.

### 2. Flash vbmeta (Disable Verified Boot)

```powershell
fastboot --disable-verity --disable-verification flash vbmeta output\printer\vbmeta_disabled.img
```

### 3. Flash Boot A/B and Rootfs

> **WARNING**: This erases all Android data on the phone!

```powershell
fastboot flash boot_a output\printer\boot.img && fastboot flash boot_b output\printer\boot.img && fastboot flash userdata output\printer\rootfs-sparse.img && fastboot reboot
```

## Login Credentials

| Account | Username | Password |
|---------|----------|----------|
| User    | klipper  | klipper  |
| Root    | root     | klipper  |

## Serial Console

The kernel is configured with serial console on `ttyMSM0` (115200 baud).
USB CDC ACM serial gadget (`ttyGS0`) is also enabled for USB serial access.

## Network

- **NetworkManager** is enabled for WiFi/Ethernet management
- **SSH** is enabled (port 22)
- USB gadget brings up ACM serial plus NCM ethernet. The device side uses
  `usb0 = 192.168.137.133/24`; set the Windows host side to `192.168.137.1/24`
  if it does not receive a usable address automatically.

## HelixScreen

HelixScreen is installed in `/home/klipper/helixscreen` and starts through
`helixscreen.service`. The rootfs forces `HELIX_DISPLAY_BACKEND=fbdev` so the
known-good 6.16 recovery image can use the bootloader framebuffer. The 7.1
development kernel also contains the native NT36830 dual-DSI/DSC driver.

Moonraker listens on `localhost:7125`; Klipper and Moonraker are enabled as
systemd services.

## Known Limitations

- **Display**: The native NT36830 dual-DSI/DSC driver compiles and links on
  7.1, but physical scanout has not yet been validated. Keep the recovery
  artifacts from `RECOVERY.md` before flashing a 7.1 test image.
- **Firmware**: WiFi requires Qualcomm firmware under `firmware/` before
  rebuilding rootfs.

## Troubleshooting

### Phone doesn't boot
- Ensure vbmeta was flashed with verification disabled
- Reflash both boot slots:
  `fastboot flash boot_a output\printer\boot.img && fastboot flash boot_b output\printer\boot.img && fastboot reboot`

### No display output
- Connect via USB serial (`ttyGS0`) or SSH to debug
- Check `dmesg | grep drm` for panel driver status

### Revert to Android
Flash original factory images for Razer Phone 2.

To restore the preserved working Linux 6.16 WiFi/Helix image, follow
`RECOVERY.md`.
