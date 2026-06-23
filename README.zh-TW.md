# Razer Phone 2 Linux

[English](README.md)

這是 Razer Phone 2（`aura`、Qualcomm SDM845）的 mainline Linux 專案，標準
建置環境為 Windows 11 + WSL2 Ubuntu 24.04。

## 目前狀態

- kernel 已升級至 SDM845 mainline `sdm845/7.1-dev`，固定 commit
  `85f1df2a4ec7`（`7.1.0-rc1`）。
- base/printer 完整 kernel 已分別成功產生
  `7.1.0-rc1-sdm845` 與 `7.1.0-rc1-sdm845-printer`。
- USB NCM 網路與 SSH 可由 `192.168.137.133` 連線。
- 開機不依賴 USB host：early log 固定走 `ttyMSM0`，`ttyGS0` 只作為
  userspace 啟動後的可選 USB gadget serial 登入介面。
- 6.16 還原基線上的觸控、Klipper、Moonraker、HelixScreen 已可用。
- NT36830 原生 dual-DSI/DSC DRM driver 已真正實作，並以 module 納入
  7.1 build，提供 60/120 Hz mode 且通過 panel DT binding 檢查。第一階段
  7.1 測試仍停用 MDSS/DSI、沿用 bootloader framebuffer；原生面板另列
  下一階段測試。
- WiFi 已透過 MSS/WLFW、`rmtfs`、userspace `pd-mapper`、修正版
  `tqftpserv` v1.2、Razer FIH NV sharing 與 ath10k host-capability quirk
  成功運作。
- 開機時 HelixScreen 會先等待 `wlan0`，之後可由 NetworkManager 顯示與
  管理 WiFi。

正式 kernel 差異只放在 DTS、panel driver/binding 與
`kernel-patches/` 頂層。舊診斷程式已從此分支清除，仍可由 6.16
baseline tag 完整還原。

顯示刷機前請先看 [RECOVERY.md](RECOVERY.md)。已驗證可工作的 6.16
WiFi/Helix boot/rootfs 映像保存在專案工作目錄之外。

## 前置需求

- Windows 11、WSL2、Ubuntu 24.04。
- 至少 30 GB 可用空間。
- 已解鎖 bootloader 的 Razer Phone 2。
- Windows 端已安裝 Android Platform Tools。
- Razer factory 包 `aura-p-release-3201-user-full.zip` 或其中的
  `modem.img`。專有 firmware 不會提交至 Git。

## 從全新 clone 完整建置

在 PowerShell 執行：

```powershell
git clone https://github.com/aa846301/razorphone2linux.git
cd razorphone2linux
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/01-setup-environment.sh"
```

setup 只有在安裝 WSL build dependencies 時使用 `sudo`，並會依
`config/kernel-source.env` clone 固定版本的 SDM845 kernel。

把 factory ZIP 放到專案根目錄，然後抽取 firmware：

```powershell
wsl bash -lc "cd /mnt/c/repo/razorphone2linux && bash scripts/extract-modem-firmware.sh"
```

若要固定為此手機的 factory WiFi MAC，而不是每次使用隨機 MAC：

```powershell
Copy-Item config\device.env.example config\device.env
# 編輯 config\device.env 內此手機專用的 RAZER_WLAN_MAC。
```

預設下載源已改成 Canonical 全球 ARM64 端點
`https://ports.ubuntu.com/ubuntu-ports`。只有確定有更近 mirror 時才覆寫：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all `
  -Profile printer `
  -UbuntuMirror "https://ports.ubuntu.com/ubuntu-ports"
```

建置含完整 3D 列印組件的映像：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -Profile printer
```

建置不含 Klipper/Moonraker/HelixScreen 的精簡 Linux 映像：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 all -Profile base
```

此 wrapper 會以一般 WSL 使用者 build kernel/封裝，只讓 rootfs 階段以
WSL root 執行，因此不會在長時間 build 中途卡在 sudo 密碼。

userspace 版本固定於 `config/userspace.env`：

- Klipper `ca8230d505b7ba7fd225bfa6ed9655bc4520e805`
- Moonraker `9008485843740c93e0154ccbdac1fc2b02b03aaa`
- HelixScreen `v0.99.62`

完成品依 profile 隔離：

- `output/printer/`：完整 Klipper 上位機。
- `output/base/`：一般用途 Linux。

若 kernel 與 rootfs modules 版本不同，boot packager 會直接拒絕產生
`boot.img`。

## 增量開發

由 Windows/Codex Desktop 執行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-all-wsl.ps1 validate -Profile printer
```

只有 DTS 或 boot command line 改動時可用 `validate-boot`。套件清單、
debootstrap 或 Klipper/Moonraker/Helix 安裝流程改動時必須使用 `all`。

唯一正式 build 流程為：

- `scripts/02-build-kernel.sh`
- `scripts/03-build-rootfs.sh`
- `scripts/03-refresh-rootfs.sh`
- `scripts/04-make-boot-image.sh`
- `scripts/build-all.sh`
- `scripts/build-all-wsl.ps1`

只驗證 driver、DTB 與 vmlinux 連結，不編譯全部 modules 時可使用：

```bash
RAZER_KERNEL_SCOPE=display RAZER_IMAGE_PROFILE=printer \
  bash scripts/02-build-kernel.sh
```

此模式只產生 `display.kernel-release`，刻意禁止拿去和 rootfs 封裝。
需要刷機包時仍必須使用正常完整 build。

## 刷機

警告：刷入 userdata 會清除 Android 使用者資料。首次需要時先停用
verified boot：

```powershell
fastboot --disable-verity --disable-verification flash vbmeta output\printer\vbmeta_disabled.img
```

boot A/B 兩槽與 userdata 必須一起完整刷入：

```powershell
fastboot flash boot_a output\printer\boot.img && fastboot flash boot_b output\printer\boot.img && fastboot flash userdata output\printer\rootfs-sparse.img && fastboot reboot
```

預設帳密為 `klipper` / `klipper`，首次開機後請修改。

## WiFi 與 HelixScreen

`razer-wifi-ready.service` 會在 NetworkManager、`rmtfs`、`tqftpserv`
之後啟動，最多等待 `wlan0` 75 秒才放行 HelixScreen。這可避免 Helix
在 MSS/WLFW 尚未完成時把狀態記成「No WiFi hardware」。

HelixScreen 已設定 `/display/rotate = 90`，並以
`HELIX_DISPLAY_ROTATION=90` 固定旋轉。`v0.99.62` 正確欄位名稱是
`rotate`，不是 `rotation`；fbdev 模式會一併旋轉觸控座標。

檢查指令：

```bash
nmcli device
nmcli device wifi list
systemctl status razer-wifi-ready helixscreen
journalctl -b -u rmtfs -u tqftpserv -u razer-wifi-ready -u helixscreen
```

## 專案維護方式

DTS、config、rootfs 與封裝等本機專案差異，先在本 repo 的 feature
branch commit，再用 PR 合併。WSL kernel checkout 是可重建的工作目錄；
build 時建立 local integration commit，只是為了得到乾淨且可追蹤的
kernel release。

只有在修改已泛用化、必要 binding 文件齊全，且對其他裝置也有價值時，
才另外送 upstream kernel PR。診斷 LOG 不應 upstream。`tqftpserv`
的 Android path 支援之後適合回送其 upstream；本 repo 則保留固定且已
驗證的 binary，確保映像可重現。

更多刷機與救援資訊請見 [FLASH-GUIDE.md](FLASH-GUIDE.md)。
準備送 Linux kernel mailing list 前請先看
[upstream/STATUS.md](upstream/STATUS.md)。
