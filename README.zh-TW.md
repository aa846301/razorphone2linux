# Razer Phone 2 Linux

[English](README.md)

這是 Razer Phone 2（`aura`、Qualcomm SDM845）的 mainline Linux 專案。預設
release 是不預裝應用程式的硬體平台映像：能驅動 GPU、WiFi、充放電保護、
螢幕休眠，讓使用者自己安裝需要的軟體。

## 目前狀態

- Kernel baseline 是 SDM845 mainline `sdm845/7.1-dev`，固定在
  `85f1df2a4ec7`（`7.1.0-rc1`）。
- NT36830 原生 dual-DSI/DSC 顯示路徑已透過 opt-in native-panel build
  實作；DSI/DSC 設定已對齊 Razer LK factory 行為。
- Adreno 630 可透過 freedreno 使用硬體 GL；需要 stock Razer
  `a630_zap.*` 與 linux-firmware `a630_sqe.fw`。
- PMI8998 SMB2 charger、fuel gauge、RRADC 已啟用。rootfs 會在 kernel
  暴露可寫 power-supply sysfs 時套用 40%/80% 充電門檻，DTS 仍保留保守
  2 A 充電限制。
- 預設正常開機會在 rootfs 起來後讓面板進入 blank；console mode 仍可用於
  顯示除錯。
- USB NCM 網路與 SSH 可由 `192.168.137.133` 連線。
- WiFi 透過 MSS/WLFW、`rmtfs`、userspace `pd-mapper`、patched
  `tqftpserv`、Razer FIH NV sharing 與 ath10k host-capability quirk 運作。

推進紀錄放在 `doc/`。已驗證的 WebKitGTK/Epiphany + sway Home Assistant
kiosk prototype 封存在 `rootfs-scripts/kiosk-prototype/`；只有 `ha`
userspace profile 會安裝，預設映像不會安裝。

## Release Profiles

硬體 image profile 固定是 `base`。應用程式 stack 由
`RAZER_USERSPACE_PROFILE` 或 release tag suffix 決定：

- `v1.0.0` -> `none`：不預裝應用的硬體平台映像。
- `v1.0.0-ha` -> `ha`：Home Assistant kiosk 套件與 prototype。
- `v1.0.0-3dprinter` -> `3dprinter`：Klipper/Moonraker/HelixScreen stack。

## 建置

前置需求：

- Windows 11、WSL2 Ubuntu 24.04。
- 至少 30 GB 可用空間。
- Windows 端 Android Platform Tools。
- 已解鎖 bootloader 的 Razer Phone 2。
- Razer factory 包 `aura-p-release-3201-user-full.zip` 或其中的
  `modem.img`。專有 firmware 不放進 Git。

建立建置環境：

```powershell
git clone https://github.com/aa846301/razorphone2linux.git
cd razorphone2linux
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/01-setup-environment.sh"
```

抽取 firmware：

```powershell
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/extract-modem-firmware.sh"
```

建置預設不預裝應用的 native-panel 映像：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel
```

本機建置可選 userspace profile：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel -UserspaceProfile ha
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -NativePanel -UserspaceProfile 3dprinter
```

完成品輸出到 `output/base/`。如果 kernel 與 rootfs modules release 不一致，
boot packager 會拒絕產生 `boot.img`。

## GitHub Actions

`Build flashable image` workflow 只會在 push `v*` tag 時執行。它會建置
native-panel 映像，並上傳
`boot.img`、`rootfs-sparse.img`、`vbmeta_disabled.img`、initramfs、release
markers、`userspace.profile` 與 `SHA256SUMS`。

請將 repository secret `RAZER_FACTORY_ZIP_URL` 設成
`aura-p-release-3201-user-full.zip` 的私有下載 URL。Tag 會自動選 profile：
`v*`、`v*-ha`、`v*-3dprinter`。

## 刷機

警告：刷入 userdata 會清除 Android 使用者資料。若尚未刷過 disabled
vbmeta，先執行一次：

```powershell
fastboot --disable-verity --disable-verification flash vbmeta output\base\vbmeta_disabled.img
```

平常刷機：

```powershell
fastboot flash boot_a output\base\boot.img && fastboot flash boot_b output\base\boot.img && fastboot flash userdata output\base\rootfs-sparse.img && fastboot reboot
```

預設帳密為 `klipper` / `klipper`，首次開機後請修改。

## 常用檢查

```bash
nmcli device
nmcli device wifi list
systemctl status razer-charge-limits razer-panel-idle-blank razer-wifi-ready
journalctl -b -u rmtfs -u tqftpserv -u razer-wifi-ready
```

操作細節請看 [FLASH-GUIDE.md](FLASH-GUIDE.md)、[RECOVERY.md](RECOVERY.md)
與 [doc/ci-and-release.md](doc/ci-and-release.md)。
