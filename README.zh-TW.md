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
- PMI8998 SMB2 charger、fuel gauge、RRADC 已啟用。rootfs service 會透過
  標準 `charge_behaviour` power-supply 介面，在電量高於 40% 時優先使用外部
  輸入；電量降到 40% 會開始一輪充電，持續充到 80% 才停止。DTS 仍保留
  保守的 2 A 充電限制。
- 預設正常開機會在 rootfs 起來後讓面板進入 blank；console mode 仍可用於
  顯示除錯。正常關機會在硬體停止前恢復真實 tty/kernel log。
- 系統會透過 `qbootctl` 標記 Qualcomm A/B 開機完成，避免正常重開機耗盡
  目前槽位的 retry count。
- USB NCM 網路與 SSH 可由 `192.168.137.133` 連線。
- WiFi 透過 MSS/WLFW、`rmtfs`、userspace `pd-mapper`、patched
  `tqftpserv`、Razer FIH NV sharing 與 ath10k host-capability quirk 運作。
- 後置 IMX363 已證實能輸出 RAW10，但舊版面板的逐像素 demosaic 太慢，第一
  幀長時間無法完成；預覽器已改為區塊式診斷畫面。前置 S5K3H7 仍待下一版
  驗證 PM8998 GPIO7 驅動強度修正，也還不是完整相機 stack。
- PMI8998 LRA 已套用原廠 1300 mV／800 mA 限制，實機暫存器證實 FF 播放時
  輸出級會進入 BUSY；仍須實際觸感驗證。音訊已接上 WCD9340/SLIMbus、原廠
  雙 TFA9912 與 `tfa98xx.cnt`，並加入原廠 QMI-arrival fallback；下一版仍須
  在手機驗證成功後才會勾選下方項目。

## 硬體支援清單

以下分類參考 postmarketOS 裝置頁常用的功能項目。打勾代表已在實機驗證；
部分完成的功能會拆開列出，讓剩餘工作保持清楚。

- [x] 開機與 fastboot 刷機
- [x] Qualcomm A/B 開機成功標記
- [x] 內部 UFS 儲存與 rootfs
- [x] 原生 dual-DSI/DSC 顯示與觸控
- [x] 開機後面板 blank 與關閉背光
- [x] 電源鍵、音量鍵與 Linux 正常關機流程（接著 VBUS 時可能再次冷開機）
- [x] Adreno 630 GPU 硬體加速與專有韌體
- [x] USB NCM 網路與 SSH
- [x] WiFi 掃描、連線與重新連線
- [x] 電池電量、電壓、電流與溫度資訊
- [x] 有線充電、USB-PD sink 協商與 RRADC 輸入量測
- [x] 外部供電優先的 40-80% 充電策略
- [x] 藍牙韌體、控制器初始化與裝置掃描
- [ ] 藍牙配對與重新連線驗證
- [ ] 藍牙音訊
- [ ] 系統 suspend 與深度休眠（目前僅支援面板 blank）
- [ ] 喇叭、麥克風、聽筒與 USB-C 音訊
- [ ] 前後相機
- [ ] GNSS/GPS
- [ ] Modem 通話、SMS 與行動數據
- [ ] NFC
- [ ] USB OTG/host mode
- [ ] USB 3 SuperSpeed 資料傳輸（目前 fastboot 使用 USB 2）
- [ ] DisplayPort alternate mode
- [ ] 加速度計、陀螺儀、磁力計、距離與環境光感測器
- [ ] 震動馬達與 notification/Chroma LED
- [ ] 指紋辨識
- [ ] Qi 無線充電
- [ ] 全磁碟加密整合

## 外部供電與充電策略

`razer-charge-limits.service` 初始會進入 `external-power` 模式。USB 輸入在線
且電池高於 40% 時，服務會選擇 `inhibit-charge`：USB 供電路徑維持開啟，
但不對電池充電。電量到達 40% 或以下時，服務會鎖存進入 `charge-cycle`、
切換成 `auto`，並持續充到 80% 才回到 `external-power`。狀態會寫入
`/var/lib/razer-charge-limits/state`，重新啟動服務或手機後仍會保留。

這個策略不會在硬體上切斷電池。電池仍可處理瞬間負載；如果接的是電流不足
的電腦 USB port，電池也可能同時補足系統用電。可用以下指令確認策略與電流
方向：

```bash
cat /sys/class/power_supply/pmi8998-charger/online
cat /sys/class/power_supply/pmi8998-charger/charge_behaviour
cat /sys/class/power_supply/qcom-battery/current_now
cat /var/lib/razer-charge-limits/state
```

## 實驗用控制面板

`experiments/razer-control-panel/` 內的 DRM/KMS 面板會分開顯示 RRADC 量到的
USB 輸入電壓、電流、功率與電池電流，也提供 WiFi 設定及暫時性的
`CHARGE TO 100%` 測試按鈕。程式會保留在 repository 供開發測試，但本機
建置與 GitHub Actions release 都不會安裝；部署方式請看它的
[README](experiments/razer-control-panel/README.md)。

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

`Build flashable image` workflow 會在 push `master` 時建立預設分支共用快取，
並在 push `v*` tag 時發佈 release。GitHub Actions cache 會依 Git ref 隔離，
所以一個 release tag 建立的 cache 無法直接由下一個 tag 使用。推 release tag
前，應先讓相同 commit 的 `master` run 完成；tag run 才能從預設分支復用
kernel core、`ccache`、已抽取 firmware 與 rootfs cache。

`master` 暖 cache 時會同時使用三個獨立 ARM64 job：工廠 firmware 抽取、
kernel/DTB/modules，以及不依賴 kernel 的 rootfs base。rootfs base 只包含
distribution、套件、帳號與可選 application profile；release job 最後再由
`03-refresh-rootfs.sh` 套用當次 firmware、modules、services 與 initramfs。
因此 firmware 前置失敗時，不會連已成功完成的 kernel build 一起丟掉。
三個 seed job 全部成功後，正常的 `build` job 必須在 `master` 還原這些 cache，
並組裝一份完整驗證映像。只有 tag build 會把這條已驗證流程正式發佈成
GitHub Release。

YAML 會直接列出 GitHub `ubuntu-24.04-arm` hosted runner 上的 release
recipe：選 tag profile、匯入韌體、建 native-panel/GPU kernel、建 ARM64
rootfs、封裝 `boot.img`，並上傳只包含可刷入映像的 release zip：
`boot.img`、`rootfs-sparse.img` 與 `vbmeta_disabled.img`。`master` run 只會
上傳供驗證的 Actions artifact，不會建立 GitHub Release；只有 `v*` tag
會正式發佈。

請將 `RAZER_FACTORY_ZIP_URL` 設成 repository variable 或 secret，指向
`aura-p-release-3201-user-full.zip`。公開上游 URL 可以用 variable；私有
大檔 URL 則用 secret，若需要 HTTP auth header，再加
`RAZER_FACTORY_ZIP_AUTH_HEADER` secret。Tag 會自動選 profile：`v*`、`v*-ha`、
`v*-3dprinter`。

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
