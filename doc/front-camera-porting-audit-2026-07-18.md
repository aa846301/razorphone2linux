# 前鏡頭 S5K3H7 移植核對（2026-07-18）

## 結論與最早失敗邊界

目前不能把前鏡頭標示為完成。S5K3H7 仍在 probe 階段讀取 `0x0000` 晶片 ID
時收到 `-ENXIO`，因此還沒進到 sensor mode table、CSI 串流或面板預覽。主線
`i2c-qcom-cci` 只有在 CCI IRQ 明確包含 NACK bit 時才把狀態轉成 `-ENXIO`，
所以這不是控制面板按鈕或 media graph 設定造成的錯誤。

原廠 CCI 調用鏈另有一項先前漏移植的差異：每次 `CCI_I2C_SET_PARAM` 都把
`retries=3` 寫到 bit 16–17，主線驅動則保持為零。`kernel-patches/0014` 已移植
相同的硬體 transaction retry；需要刷入新核心後判斷它是否足以讓模組 ACK。

同步 rebind 的 debugfs 採樣證明 GPIO4/VDIG、GPIO7/VANA、GPIO8/IOVDD 與
GPIO9/reset 確實在 probe 視窗內變為 output-high，失敗後才關閉；同一輪採樣
也記錄 `cam_cc_mclk2_clk: enable=1, prepare=1, rate=24000000`。下一個有判別力
的測試是量測模組端實際電壓與 24 MHz 波形，而不是再猜 mode register。

## 主線 Linux 與網路既有實作

- 主線已有 SDM845 CAMSS、CCI、CSIPHY/CSID/VFE、fixed-regulator、clock、GPIO
  與 V4L2 sensor framework；電源拓撲、reset、MCLK、CCI bus speed 與 CSI
  endpoint 可由 DTS 描述。
- 本 repository 所用的主線樹沒有 S5K3H7 driver，網路與上游樹也沒有找到可
  直接套用到 Razer/Chicony 模組的完整 S5K3H7 移植。因此 sensor register
  table 仍來自原廠模組資料，不能只靠 DTS 完成。
- 原廠來源以 Razer Phone 2 Android 9 SMR7 kernel 與 stock CamX module 為
  依據；不使用名稱相近但未被 MP/PVT/DVT include chain 引用的 S3 variant。

## 完整需求清單與逐項對照

| 項目 | Razer 生產來源 | mainline port | 實機證據／狀態 |
| --- | --- | --- | --- |
| 模組 | Chicony S5K3H7 | `samsung,s5k3h7` | driver bind 後讀 ID 失敗 |
| Linux 位址 | stock 8-bit `0x20`，即 7-bit `0x10` | `reg = <0x10>` | device `17-0010` 存在 |
| CCI | master 1，I2C FAST 400 kHz，硬體 retries=3 | `cci_i2c1`、400 kHz；`0014` 移植 retries=3 | 舊核心回傳 NACK；待刷新版 |
| I2C pins | GPIO19/20，CCI I2C、pull-up、2 mA | 與 SDM845 CCI1 pinctrl 一致 | debugfs mux 一致 |
| VANA | PM8998 GPIO7，2.8 V，60 mA metadata | fixed 2.8 V regulator | probe 時 GPIO7 high |
| VDIG | PM8998 GPIO4，1.05 V，260 mA metadata | fixed 1.05 V regulator | probe 時 GPIO4 high |
| VIO | PM8998 GPIO8，1.8 V，LVS1 parent，0 mA metadata | fixed 1.8 V，LVS1 parent | probe 時 GPIO8 high |
| MCLK | MCLK2/GPIO15，24 MHz | CAM_CC_MCLK2 24 MHz | 同窗記錄 enable/prepare=1、24 MHz |
| reset | TLMM GPIO9，active-low | `reset-gpios` active-low | probe 時 GPIO9 high |
| power order | VANA 1 ms → VDIG 1 ms → VIO 0 ms → MCLK 1 ms → reset high 18 ms | 同一順序；VIO 多 1 ms，reset 20 ms | rails/reset 時序視窗成立 |
| CSI | CSIPHY2，4 data lanes | CSIPHY2、lanes 1/2/3/4 | 尚未走到 streaming |
| link frequency | stock 1080p table／模組資料 | 330 MHz | probe 未完成，尚不可驗證 |
| 保留記憶體 | sensor probe 本身不需要專屬 carveout；CAMSS buffer 走一般 DMA | 無額外 front-camera carveout | 非目前失敗邊界 |

原廠 DTS 主要對照檔：

`vendor-source/razer-phone2-smr7/msm-4.9/arch/arm64/boot/dts/fih/RC2_common/sdm845-camera_rc2-pre-evt2.dtsi`

stock 模組資料：

`com.qti.sensormodule.chicony_s5k3h7.bin` 與
`com.qti.sensor.s5k3h7.so`。其 power sequence 為 VANA、VDIG、VIO、MCLK、
RESET，delay 為 1/1/0/1/18 ms，probe 使用 I2C FAST mode。

## 原廠到主線的調用鏈

原廠 CamX sensor module 提供 slave address、power sequence 與 register table，
Qualcomm camera sensor layer 依序啟用 regulator/GPIO、設定 MCLK、解除 reset，
再由 CCI master 1 讀取晶片 ID，且 SET_PARAM 內指定三次硬體重試。mainline
port 的等價鏈為
`s5k3h7_probe()` → runtime PM resume → regulator bulk enable → MCLK enable →
reset deassert → CCI regmap read；`0014` 補回原廠 SET_PARAM retry bits。

若新核心在三次硬體重試後仍 NACK，最早失敗邊界就是「所有軟體控制訊號看似
有效，但 sensor 在 ID read 不 ACK」。此時應量模組 pin 的電壓、MCLK 與 CCI
waveform，不應修改初始化 register table，因為該 table 尚未被執行。

## 下一輪驗證門檻

1. 刷入包含 `0014` 的新核心，確認 `s5k3h7` 是否可讀到 chip ID；舊 boot 無法
   驗證這個改動。
2. 若仍 NACK，量測模組端 VANA/VDIG/VIO、MCLK2 24 MHz、reset 與 CCI SDA/SCL；debugfs
   已證明 controller 端要求全部送出，但不能代替模組 pin 波形。
3. 只有 sensor ID 可穩定讀到後，才驗證 4-lane CSI、mode table 與 RAW10 frame。
