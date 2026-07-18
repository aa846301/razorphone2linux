# 喇叭音頻移植核對（2026-07-18）

## 結論與最早失敗邊界

控制面板有正確觸發播放，問題不在按鈕。實機播放期間 PCM 為 RUNNING、48 kHz
S16_LE stereo，MultiMedia1 已 route 到 QUAT MI2S，DAPM route 為 ON，GPIO58–61
切到 `qua_mi2s`，兩顆 TFA9912 載入與 stock 相同 hash 的 container、解除 mute，
並記錄 `tfa_dev_start success`。但兩顆功放的 status register `0x10` 仍為
`0x001c`：PLLS、CLKS、SWS、AMPS、AREFS 均未成立。最早未完成邊界是 QUAT
MI2S bit clock/reference 到功放，而不是 ALSA PCM 或面板。

原廠與主線 pinctrl 逐腳對照後找到確定差異：原廠把 GPIO60/SD0 設為 input，
GPIO61/SD1 設為 output-high；generic SDM845 DTS 兩者都沒指定方向。實機播放時
GPIO61 也確實顯示為 `in low func1`，但 Razer 的兩顆功放正是接收 SD1。板級 DTS
現已補回原廠方向，需刷入新 DTB 驗證 BCLK/CLKS 與實際聲音。

## 主線 Linux 與網路既有實作

- 主線已有 SDM845 ASoC machine driver、Q6ASM/Q6AFE/Q6ADM、QUAT MI2S DAI、
  pinctrl 與 DAPM；clock、DAI format、route、codec links 可由 DTS 與 machine
  driver 完成。
- 主線沒有 Razer 使用的 downstream TFA9912/TFA98xx container driver。本 port
  因此保留原廠 codec driver 與 stock `tfa98xx.cnt`，不能只用 DTS 取代。
- 網路查核以 Razer 官方 MR0/MR1 audio kernel source 與 Linux ASoC clock
  文件為基準；沒有找到可直接套用的 Razer Phone 2 mainline speaker port。

官方來源：

- `https://developer.razer.com/razer-phone-dev-tools/kernel-source-code/`
- `https://s3.amazonaws.com/cheryl-factory-images/audio-kernel-3040.tar.gz`
- `https://www.kernel.org/doc/html/next/sound/soc/clocking.html`

## 完整需求清單與逐項對照

| 項目 | Razer 原廠 | mainline port | 實機狀態 |
| --- | --- | --- | --- |
| 後端 | QUATERNARY MI2S RX | `QUATERNARY_MI2S_RX` | route ON |
| 格式 | 48 kHz、stereo；S16 時 BCLK 1.536 MHz | 48 kHz S16 stereo，`MI2S_BCLK_RATE=1536000` | PCM RUNNING |
| master | AP/CPU 提供 BCLK/FS，codec 為 slave (`CBS_CFS`) | CPU `BP_FP`，codec `BC_FC` | format API 等價；需確認 return |
| data line | `qcom,msm-mi2s-rx-lines=<2>` 是 bitmask SD1 | `qcom,sd-lines=<1>` | GPIO SD1 mux 有效 |
| pins | GPIO58/59 output-high、GPIO60 input、GPIO61 output-high | 板級覆寫 SD0 input、SD1 output-high | 舊 DTB 的 GPIO61 實測為 input；待刷新版 |
| codecs | TFA9912，I2C5 `0x34`、`0x35` | 兩個 codec DAI | 兩顆 probe/start/unmute |
| firmware | stock `tfa98xx.cnt` | 安裝到 firmware path | hash 與 stock 一致 |
| codec profile | 48 kHz speaker profile | 兩顆套用相同 profile | live log 一致 |
| ADSP memory | factory audio ION 約 `0x10000000..0x1fffffff` | Q6ASM 使用 29-bit DMA mask | map 成功、PCM RUNNING |
| audio PD | stock ADSP 不發布主線期待的 `avs/audio` PDR | 移除不可用 PDR gate、SSR fallback | card/PCM 枚舉完成 |
| 保留記憶體 | ADSP firmware 與音頻共享記憶體由 remoteproc/Q6 管理 | 沿用既有 ADSP carveouts；PCM DMA 限制到可見範圍 | 非目前失敗邊界 |
| 功放供電/硬體 enable | TFA status 應出現 reference/clock/amplifier state | codec driver 啟動鏈存在 | status 未出現 CLKS/PLLS/AMPS |

## 原廠到主線的調用鏈

Razer `asoc/sdm845.c` 的 `msm_mi2s_snd_startup()` 在第一次開啟 QUAT MI2S 時：

1. `update_mi2s_clk_val()` 依 sample rate、stereo 與 bit width 算出 BCLK；
2. `afe_set_lpass_clock_v2()` 對 QUAT RX 啟用 clock；
3. `snd_soc_dai_set_fmt(cpu_dai, SND_SOC_DAIFMT_CBS_CFS)`；
4. 切換 `quat-mi2s-active` pinctrl。

mainline 等價鏈為 `sdm845_snd_startup()`：

1. `snd_soc_dai_set_sysclk(...Q6AFE_LPASS_CLK_ID_QUAD_MI2S_IBIT, 1536000...)`；
2. Q6AFE 送出 `AFE_PARAM_ID_CLOCK_SET`；
3. CPU DAI 設為 `BP_FP`，兩顆 codec DAI 設為 `BC_FC|NB_NF|I2S`；
4. DTS default pinctrl 切至 QUAT MI2S pins，板級狀態依原廠指定 SD0 input、
   SD1 output-high。

clock ID、頻率與 master/slave 語意和原廠一致。先前 machine driver 忽略 CPU
`set_sysclk`、CPU `set_fmt` 的回傳值，因此 userspace 可能在 clock request 失敗
時仍看到播放成功。本輪修改 `kernel-patches/0008`，讓兩個 CPU DAI 步驟與兩顆
codec format 任一步失敗都立即回傳並記錄明確錯誤。這是以原廠調用鏈為依據的
失敗邊界修正。這一輪另修正 SD1 實際方向；在新 DTB 實機播放前仍不宣稱已經
讓硬體發聲。

## 下一輪驗證門檻

1. 刷入同一次 GitHub Actions 產生的 boot/rootfs，避免 module mismatch。
2. 執行 `scripts/diagnostics/phone-audio-playback-state.sh`；先確認播放期間
   GPIO61 為 `out ... func1`，並確認沒有新增的
   `QUAT MI2S bit clock error` 或 `CPU format error`。
3. 播放期間讀 TFA status `0x10`。只有 CLKS/PLLS 出現後才追功放 profile、
   boost/current 與 AMPS；若仍沒有 CLKS，直接量 GPIO58 BCLK、GPIO59 WS 與
   GPIO61 SD1 波形。
4. 必須實際聽到左右喇叭，不能以 `speaker-test` exit 0 當完成。
