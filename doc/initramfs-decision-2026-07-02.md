# initramfs 方案評估與決策（2026-07-02）

目標：Razer Phone 2 (aura) 主線 Linux 的 initramfs 從「自製 busybox script」換成可長期維護的標準方案。
先在 6.16 分支落地驗證，之後才移植 7.1。

## 候選方案

| 方案 | 來源 | 狀態 |
|---|---|---|
| A. 自製 busybox | `initramfs/init-boot.sh`（舊出貨路徑，已從 repo 移除） | 手寫 partlabel 掃描、klibc bug workaround、手動塞 UFS PHY .ko；每次 kernel 變動都要人工同步 |
| B. postmarketOS initramfs | `postmarketos-mkinitfs` + `boot-deploy`（Alpine apk 生態） | pmOS 裝置的標準方案 |
| C. Ubuntu initramfs-tools | rootfs 內建 `update-initramfs` | 遷移已在 codex/6.16-standard-initramfs 動工，本 worktree commit 0f49a8b 已接管保全 |

## pmOS initramfs 調研結果（wiki 經瀏覽器擷取，2026-07-02）

來源：
- https://wiki.postmarketos.org/wiki/Initramfs
- https://wiki.postmarketos.org/wiki/Initramfs/Development
- https://wiki.postmarketos.org/wiki/Boot_process

要點：
1. **「強制覆蓋 Android 啟動需求」的實質**：pmOS initramfs 不理會 Android bootloader
   附加的 root 參數，自己用 `pmos_root=` cmdline 或掃描 **`pmOS_root` 分區 label**
   （含 subpartition）找根分區，然後 `switch_root`。boot 分區同理（`pmOS_boot`）。
2. 組成是 busybox + shell script，由 `postmarketos-mkinitfs`（Go 工具）產生、
   `boot-deploy` 打包進 boot.img；行為由 `deviceinfo` 檔驅動；device quirk 用
   hook（以 Alpine apk 套件散布）。
3. 附加功能：USB networking debug、首次開機 resize、FDE 解鎖、telnet/debug shell、
   小 boot 分區用 initramfs-extra 拆分。
4. **開機 log 上屏的官方作法**：cmdline 加 `console=tty0`（要關 splash 用
   `pmos.nosplash`）。這是純 kernel 機制，不是 pmOS 專屬能力。

## 決策：採 C（Ubuntu initramfs-tools），不採 pmOS initramfs

理由：
1. **rootfs 是 Ubuntu 24.04 + systemd**。initramfs-tools 是它的原生機制：
   `update-initramfs` 依 `/boot/config-<release>` + `depmod` 自動收錄對應模組
   （UFS PHY 之類不再手動複製），udev 原生處理 by-partlabel，跟 kernel 升級
   （6.16 → 7.1）自動同步。方案 A 的整類手工維護 bug 直接消失。
2. **pmOS initramfs 我們真正需要的只有一個行為**——蓋掉 bootloader 塞的
   `root=/dev/dm-*`。這已由 40 行的 initramfs-tools hook 等價實作
   （`rootfs-scripts/initramfs-tools/razer-root-local-top` +
   `conf.d/razer-root`），效果相同、不用引入 Alpine 工具鏈。
3. **pmOS initramfs 與我們的棧不合**：它期望 `pmOS_root` label（我們是
   `userdata`）、apk hook 套件、deviceinfo、boot-deploy；對 Ubuntu/systemd
   rootfs 沒有任何加分，還多一套要維護的生態。
4. **「更常見的方案」的事實界定**：pmOS 裝置用 postmarketos-initramfs 是因為
   rootfs 就是 Alpine 系的 pmOS；Debian/Ubuntu 系手機移植（Mobian 等）用的
   就是各自發行版的 initramfs-tools。以我們的 rootfs 而言，initramfs-tools
   才是「常見方案」。

從 pmOS 借鑑（不引入其實作）：
- boot log 上屏 = `console=tty0`（已納入 cmdline 設計）。
- 開機失敗掉 debug shell：initramfs-tools 原生就有（`panic=` 未設時掉
  busybox shell）。
- boot 分區大小上限要驗證（pmOS 拆 initramfs-extra 就是為了小 boot 分區）；
  我們 kernel 幾乎全 builtin、模組樹小，initrd 預期遠小於 boot 分區，
  build 後仍需實際確認 boot.img 大小。

## 開機 log 上屏政策（需求：boot 期間上屏，進 rootfs 後停止）

- cmdline（helix 正常模式）：`console=ttyMSM0,... console=tty0`（tty0 最後 =
  主 console）、`loglevel=6`、**不加 quiet**、`systemd.show_status=false`、
  `vt.global_cursor_default=0` → kernel + initramfs 訊息全程可見。
- rootfs 內 `razer-quiet-console.service`（oneshot，
  `ConditionKernelCommandLine=razer_quiet_console`，僅正常模式 cmdline 帶此
  flag 時生效）在 basic.target 前執行 `dmesg --console-level crit` → 切到
  rootfs 後螢幕即靜音（alert/emerg 仍可見），console 除錯模式不受影響。
  （2026-07-02 目標變更：HelixScreen 取消，UI 終局為 Home Assistant
  dashboard；framebuffer 接手者屆時再定。）
- console 除錯模式維持全量輸出（現行 `DISPLAY_MODE=console` 分支）。

## 落地順序（使用者 2026-07-02 定案）

1. **6.16 分支完成 initramfs-tools 遷移並實機驗證**（本 worktree，
   branch `claude/gallant-bun-4a6741`，基底 a9be42e）。
2. 驗證通過後移植 7.1。
3. 之後才做 NT36830 螢幕驅動、充電（PMI8998 SMB2/FG，7.1 分支 7494414 可作參考）。

## 驗證判定標準（先定死）

- `lsinitramfs` 含 `init`、udev、UFS PHY 相關模組（或確認 builtin）。
- boot.img 大小 < boot 分區容量。
- 實機 dmesg/journal 出現 `razer-root: using /dev/disk/by-partlabel/userdata
  instead of Android boot root ...`（hook 生效證據）。
- `findmnt /` 指向 userdata；systemd 正常到 multi-user。
- 螢幕在 initramfs 階段有 log、進 rootfs 後不再輸出。
