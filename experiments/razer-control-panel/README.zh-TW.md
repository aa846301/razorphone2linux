# Razer Phone 2 實驗測試面板部署說明

[English](README.md)

這個面板用於 Razer Phone 2 Linux 實機 bring-up，可在觸控螢幕上查看 USB
輸入、電池與充電狀態、設定 WiFi、暫時充到 100%，切換前後鏡頭的
1920×1080 RAW10 預覽，以及直接執行震動與喇叭測試。

它是手動部署的實驗工具，不會放進正常 rootfs 或 GitHub Actions release。
每次重刷 userdata/rootfs 後都要重新部署。

## 部署前準備

主機端需要：

- Windows PowerShell、OpenSSH Client（`ssh`、`scp`、`ssh-keygen`）。
- WSL 的 `Ubuntu-24.04`；腳本不使用目前的預設 WSL distro。
- WSL 內已安裝 ARM64 cross compiler 與 DRM headers：

```powershell
wsl.exe -d Ubuntu-24.04 --exec sudo apt-get install -y gcc-aarch64-linux-gnu libdrm-dev
```

- PuTTY，預設尋找 `C:\Program Files\PuTTY\plink.exe`。只有首次用密碼把
  SSH public key 寫進設備時需要；若設備已接受指定 key，則不需要 PuTTY。
- 設備已刷入可正常顯示、觸控與 SSH 連線的相符 kernel/rootfs。

設備端至少要有：

```bash
test -e /dev/fb0
test -e /dev/dri/card0
test -e /dev/input/event0
```

目前面板固定讀取 `/dev/input/event0`。如果觸控不是 `event0`，服務可能啟動
但無法操作；先用 `cat /proc/bus/input/devices` 確認事件編號。

## 1. 確認設備網路與 SSH

預設使用 USB NCM 位址 `192.168.137.133`、帳號 `klipper`：

```powershell
ping 192.168.137.133
ssh klipper@192.168.137.133
```

若要透過 WiFi 部署，先記下手機目前的 WiFi IP，例如 `10.1.3.110`，後續傳入
`-HostName 10.1.3.110`。

## 2. 準備 SSH key

部署腳本預設使用：

```text
C:\tmp\razer_usb_ed25519
C:\tmp\razer_usb_ed25519.pub
```

若這組 key 不存在，但 `%USERPROFILE%\.ssh\id_ed25519` 已可登入手機，腳本
會自動改用該 key，不需要安裝 PuTTY 或重新 bootstrap。

若檔案不存在，開啟 PowerShell 執行下列命令，詢問 passphrase 時按兩次
Enter，建立無 passphrase 的測試 key：

```powershell
New-Item -ItemType Directory -Force C:\tmp | Out-Null
ssh-keygen -t ed25519 -f C:\tmp\razer_usb_ed25519
```

首次部署時，如果 key 尚未在手機的 `authorized_keys`，腳本會透過 PuTTY
使用 `-SudoPassword` 指定的密碼安裝 public key。預設測試映像密碼是
`klipper`；若你已修改密碼，部署時必須明確傳入新密碼。

## 3. 執行部署

在 repository 根目錄開啟 PowerShell。使用預設 USB NCM 位址：

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\deploy.ps1
```

透過 WiFi 部署：

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\deploy.ps1 `
  -HostName 10.1.3.110
```

若帳號、key、密碼或 WSL distro 不同：

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\deploy.ps1 `
  -Distro Ubuntu-24.04 `
  -HostName 192.168.137.133 `
  -UserName klipper `
  -IdentityFile C:\tmp\razer_usb_ed25519 `
  -SudoPassword klipper
```

腳本會依序：

1. 在指定 WSL distro 交叉編譯 ARM64 DRM/KMS presenter 與相機預覽 helper。
2. 測試 SSH key 登入；需要時用密碼安裝 public key。
3. 以 `scp` 複製控制面板、service 與 helpers 到手機 `/tmp`。
4. 安裝檔案到 `/usr/local/sbin` 與 `/etc/systemd/system`。
5. 若缺少相機、震動或聲音測試工具，在手機安裝 `v4l-utils`、`joystick`
   與 `alsa-utils`。
6. 停用 `razer-panel-idle-blank.service` 與 `getty@tty1.service`。
7. 啟用並重新啟動 `razer-control-panel.service`。

部署完成後，手機應直接顯示測試面板。面板會自行在 60 秒後 blank，觸控可
喚醒螢幕。

## 4. 查看服務與錯誤

從 Windows 連進手機：

```powershell
ssh -i C:\tmp\razer_usb_ed25519 klipper@192.168.137.133
```

在手機上查看或重啟服務：

```bash
sudo systemctl status --no-pager --full razer-control-panel.service
sudo journalctl -u razer-control-panel.service -b --no-pager -n 200
sudo systemctl restart razer-control-panel.service
```

若 service 顯示 `ConditionPathExists` 失敗，檢查 `/dev/fb0` 與
`/dev/input/event0`。若畫面沒有出現，另外檢查：

```bash
ls -l /dev/fb0 /dev/dri/card* /dev/input/event*
dmesg | grep -Ei 'drm|dsi|panel|touch|input'
```

## 5. 測試前後鏡頭

面板上的 `REAR CAMERA` 與 `FRONT CAMERA` 會重新設定 qcom-camss media
graph，啟動 1920×1080 RAW10 預覽；按 `BACK` 會停止串流並回到主畫面。

若預覽失敗，查看完整 launcher log 與 kernel log：

```bash
cat /run/razer-camera-preview.log
media-ctl -p
dmesg | grep -Ei 'imx363|s5k3h7|camss|csiphy|csid|vfe'
```

目前這只驗證預覽 bring-up，不代表拍照、錄影、AE/AWB/AF、OIS 或完整相機
framework 已完成。

## 6. 測試震動與聲音

主畫面的 `VIBRATE` 會透過 `spmi_haptics` 的 force-feedback 介面執行約一秒
的強震動；`SOUND` 會在第一個 ALSA playback PCM 播放一次 440 Hz 雙聲道
測試音。成功時面板底部會顯示 `VIBRATION OK` 或 `SOUND OK`，失敗時會顯示
最後一行錯誤。

可由 SSH 執行相同測試並查看完整輸出：

```bash
sudo /usr/local/sbin/razer-haptic-test
sudo /usr/local/sbin/razer-audio-test
```

聲卡或 codec 出現在 `aplay -l`／`dmesg` 只代表枚舉成功；仍須以實際聽到
測試音確認 playback route、PCM 格式與兩顆喇叭工作。

## 7. 已部署的檔案

```text
/usr/local/sbin/razer-control-panel
/usr/local/sbin/razer-kms-present
/usr/local/sbin/razer-camera-preview
/usr/local/sbin/razer-camera-launch
/usr/local/sbin/razer-haptic-test
/usr/local/sbin/razer-audio-test
/usr/local/sbin/razer-shutdown-console
/etc/systemd/system/razer-control-panel.service
```

## 8. 移除測試面板

使用與部署時相同的 IP、帳號、key 與密碼參數。例如預設 USB NCM：

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\remove.ps1
```

移除腳本會刪除面板檔案，重新啟用正常的 charge-limit、tty1 與 idle blanking
服務。移除後可確認：

```bash
systemctl status razer-panel-idle-blank.service
systemctl status razer-charge-limits.service
```

## 常見問題

- `Failed to cross-compile`：確認 `Ubuntu-24.04` 可啟動，並已安裝
  `gcc-aarch64-linux-gnu`、`libdrm-dev`。
- `Key login failed and PuTTY/public key is unavailable`：確認 private/public
  key 都存在，並安裝 PuTTY，或先手動把 `.pub` 內容加入手機
  `~/.ssh/authorized_keys`。
- `Unable to record the phone SSH host key`：確認 IP 正確、手機 SSH service
  正在執行，且 Windows 到手機的 TCP 22 沒被防火牆阻擋。
- `qcom-camss media device not found`：目前 kernel/DTB 沒有成功註冊 CAMSS，
  先查看 camera 相關 `dmesg`，不是重跑面板部署就能修復。
- 重刷 userdata 後面板消失：這是預期行為，重新執行 `deploy.ps1`。
