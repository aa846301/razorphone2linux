# 專案路徑

正式來源只保留以下幾區：

- `config/`：kernel、userspace、build profile 的固定設定。
- `dts/`：Razer Phone 2 正式 DTS。
- `panel-driver/`：NT36830 DRM panel driver。
- `kernel-patches/`：正式建置會套用的最小 kernel patch。
- `rootfs-scripts/`、`rootfs-binaries/`、`rootfs-packages/`：可重建的 rootfs overlay。
- `scripts/`：唯一受支援的 build、package、flash 流程。
- `upstream/`：送 Linux upstream 前的狀態與 cover letter 草稿。

可工作的 Linux 6.16/WiFi/Helix 還原點請看專案根目錄
`RECOVERY.md`。

大型 factory、OnePlus 參考檔及舊研究輸出已移出 Git 工作目錄：

- `C:\repo\razorphone2linux-archive\reference-inputs-20260622`
- `C:\repo\razorphone2linux-recovery\known-working-6.16-20260622`
