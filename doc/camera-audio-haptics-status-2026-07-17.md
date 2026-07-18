# Camera, audio, and haptics status (2026-07-17)

## Source and live follow-up (2026-07-19)

- Rear IMX363 was streamed again at 4032x3024 using the driver's complete mode
  table.  Its RAW10 has the expected two-pixel Bayer phase, while the 1920x1080
  mode has a strong four-pixel phase.  This rules out CSI byte-lane order and
  locates the stripe defect in the incomplete 1080p sensor mode.  The panel now
  uses the clean full-resolution mode and applies bounded grey-world balance to
  BMP/preview output; saved RAW10 remains unchanged.
- Front S5K3H7 still fails at chip-ID read.  Mainline `i2c-qcom-cci` maps the
  observed `-ENXIO` specifically from a CCI NACK IRQ.  Razer's factory camera
  call chain programs `retries=3` in SET_PARAM bits 16-17, while mainline used
  zero.  Patch `0014` restores that hardware retry field for the next image.
- Audio playback reaches a RUNNING PCM, active DAPM route and started/unmuted
  TFA9912 codecs, but both amplifiers report no CLKS/PLLS.  Factory pinctrl
  makes GPIO61/QUAT SD1 an output; generic SDM845 left it directionless and the
  live phone showed `in low func1`.  The board DTS now restores SD1 output-high
  (and the factory SD0 input-enable state) for the next image.

## Rear RAW10 capture follow-up (2026-07-18)

- The control panel now has a `CAPTURE` action during camera preview. The next
  complete V4L2 frame is saved as a full-resolution BMP, the unchanged packed
  RAW10 buffer, and a metadata text file under
  `/var/lib/razer-control-panel/captures/`.
- A live 1920x1080 rear capture was successfully saved and retrieved. Its centre
  crop has a strong four-column colour phase: mean adjacent-column RGB
  difference is about 7 levels, while columns four pixels apart differ by less
  than 0.8 level. This is objective four-pixel periodicity, not a subjective
  preview report.
- The userspace decoder matches Linux's documented `pBAA`/packed Bayer RAW10
  layout: four high-byte samples followed by their four low two-bit fields.
  The retrieved 2,592,000-byte RAW10 itself also contains the phase: in the
  central crop, nominally same-colour samples two columns apart differ by about
  47 raw levels on average, but samples in the same four-column phase differ by
  about 13.7. The phase is already present in the high eight sample bits, so BMP
  demosaic and low-two-bit extraction cannot be its cause.
- No speculative byte-order change is made. The current IMX363 driver comes from
  the sdm845-mainline commit `a6f70df2c534` rather than upstream Linux and its
  source explicitly labels link frequencies as uncertain and leaves downstream
  sensor registers disabled. The next production change requires Razer's stock
  IMX363 CamX mode table or a hardware CSI lane/clock trace to distinguish sensor
  configuration from CAMSS delivery.

## Follow-up live audit of `v1.0.18` (2026-07-18)

- Front S5K3H7 still fails before media registration. Debugfs proves CCI1 SDA
  and SCL are correctly muxed to GPIO19/GPIO20, and the earlier trace already
  proved VANA, VDIG, VIO, MCLK2 and reset become active. The failure is a CCI1
  queue timeout followed by `-ENXIO`, not a control-panel error.
- The factory sensor binary selects `I2C_FAST_MODE` (`1`, 400 kHz), but the
  port inherited SDM845's 1 MHz FAST_PLUS default for `cci_i2c1`. The DTS now
  overrides CCI1 to 400 kHz. This requires a new boot image and remains pending
  hardware validation.

## Live audit of `v1.0.17` (2026-07-18)

- Rear IMX363 probes and the complete sensor-to-`/dev/video0` graph streams.
  The apparent panel failure is userspace CPU starvation: the original
  full-screen software demosaic used one core continuously for more than 14
  seconds without completing its first shared frame. The preview now demosaics
  one sample per 4x4 output block and remains a diagnostic path, not an ISP.
- Front S5K3H7 still returns `-ENXIO` at chip-ID read. A live rebind trace taken
  during the factory 20 ms reset delay proves GPIO4/VDIG, GPIO8/VIO, MCLK and
  reset are asserted, while GPIO7/VANA stays low. The PMIC GPIO dump explains
  the mismatch: GPIO4 and GPIO8 retain low output-drive strength, but GPIO7 is
  `no` drive. Mainline DT now explicitly programs all three switched rails to
  `PMIC_GPIO_STRENGTH_LOW`, removing dependence on bootloader register state.
- A five-second FF_RUMBLE trace proves PMI8998 `HAP_EN_CTL1` changes to `0x80`
  and status changes to `0x82` (BUSY), then both return to zero at stop.
  `HAP_PLAY` is not a reliable static-read test because its trigger bit clears.
  The panel no longer trusts `fftest`'s text or scans the slow regmap debugfs.
  Its dedicated helper sends 100% gain and maximum FF_RUMBLE magnitude for two
  seconds, then explicitly asks for physical confirmation; LRA motion remains
  unverified.
- Audio has no ALSA card because the SLIMbus controller itself never completes
  probe: Razer's factory ADSP omits `avs/audio` from PDR, and mainline treats
  lookup error `-ENXIO` as fatal. Downstream falls back to SSR and schedules
  domain-up on QMI server arrival. Patch `0015` ports that call chain so the
  WCD9340 SLIM devices can enumerate before the existing ASoC/MI2S fixes run.

These changes require a new kernel/DTB. Only the preview performance and panel
diagnostics are userspace changes that can be redeployed without flashing.

## Follow-up live audit of `v1.0.16`

- Rear IMX363 is now proven at the hardware level. With the graph configured as
  `SBGGR10_1X10` and the capture node set to `pBAA`, `/dev/video0` delivered ten
  consecutive 1920x1080 frames at about 23 FPS. The panel launcher was instead
  opening the `msm_vfe0_rdi0` subdevice and its preview helper used the
  single-planar API. Both userspace errors are corrected for the next image.
- Front S5K3H7 still fails the chip-ID transaction with `-ENXIO`. The factory
  rail order and voltages are already present, but the PM8998 GPIO4/GPIO7/GPIO8
  pin states were not: the live PMIC GPIO dump retained pull configurations
  that differ from Razer's output-low factory states. The next DTB restores the
  original normal-function, output-low, power-source-0 pinctrl. The later
  `v1.0.17` audit above found that explicit mainline drive strength was also
  required because GPIO7 inherited a disabled output driver.
- EV_FF accepts and uploads rumble effects, but no physical vibration occurs.
  Factory `qti-haptics` source shows the missing initialization: PMI8998
  `HAP_EN_CTL3` must enable the H-bridge, PWM path, current limiter, DAC and
  control path (`0xfd`) before `HAP_EN_CTL1`/`HAP_PLAY` can drive the LRA.
- Q6ASM now maps playback at ADSP-visible IOVA `0x1ff80000`; PCM0 is RUNNING and
  both TFA9912 devices start and unmute, but the phone remains silent. A later
  audit of Razer's `msm-dai-q6-v2.c` proved that
  `qcom,msm-mi2s-rx-lines = <2>` is a bitmask selecting SD1, not a count of two
  lines. The earlier SD0+SD1/four-channel interpretation was wrong; the
  corrected backend is stereo on SD1.

The PMIC output-stage, SD1 stereo QUAT backend, front-rail pinctrl and panel
preview corrections are source-complete but not yet hardware-validated. They
must remain marked incomplete until a matching boot/rootfs pair is flashed.

## Full live audit of `v1.0.15`

- The phone is running the `v1.0.15` kernel, but its rootfs still contains the
  older `qcom-spmi-haptics.ko` and `q6asm.ko`. Boot-only flashing is therefore
  insufficient for this hardware patch series. Temporarily loading the release
  haptics module makes the PMI8998 device probe and completes an FF_RUMBLE test;
  the installed rootfs module still reverts to the failure after reboot.
- Front S5K3H7 chip-ID access fails with `-ENXIO`. Live rail tracing proves that
  GPIO4, GPIO7, GPIO8, reset and MCLK are asserted, but source review found the
  DTS voltage/topology was copied from an unused 1.352 V S3 variant. Production
  MP/PVT/DVT overlays actually include `sdm845-camera_rc2-pre-evt2.dtsi`, where
  GPIO7 switches the 2.8 V VANA rail. The DTS is corrected to that production
  topology.
- The rear IMX363 does probe, but has zero media links because CAMSS creates
  external links only after every async endpoint binds. A CAMSS patch now links
  and registers each sensor in the notifier `bound` callback, so a failed front
  sensor no longer hides the rear sensor node.
- The sound card and both TFA9912 codecs enumerate. With the matching diagnostic
  `q6asm.ko`, playback requests an IOVA at `0xfff80000`; Razer's ADSP accepts the
  factory audio ION range `0x10000000..0x1fffffff`, so memory mapping times out.
  The Q6ASM DAI now uses a 29-bit coherent DMA mask to keep allocations inside
  the firmware-visible address range.

These source corrections still require a matching boot image and rootfs/module
set, followed by physical front/rear preview, vibration and audible playback
tests. Enumeration or a successful userspace ioctl alone is not completion.

## Camera audit and live diagnosis

Both preview paths are represented end to end in the source:

- rear IMX363: CCI0 -> CSIPHY0 -> CSID0 -> VFE0 RDI0;
- front S5K3H7: CCI1 -> CSIPHY2 -> CSID0 -> VFE0 RDI0;
- the experimental control panel resets/configures the media graph and renders
  1920x1080 RAW10 frames for either sensor.

On the pre-fix image, IMX363 bound successfully but S5K3H7 failed its chip-ID
read with `-ENXIO`. CAMSS consequently waited for the missing async endpoint
and did not create the rear sensor media link either.

The stock SMR7 CamX module confirms the front sensor's 8-bit address is `0x20`
(Linux 7-bit address `0x10`). Its decoded factory power sequence is VANA,
VDIG, VIO, 24 MHz MCLK, then RESET, with 1/1/0/1/18 ms delays. The initial
driver incorrectly enabled VIO first; it now follows the factory sequence and
the launcher uses the complete RAW10 media-bus format names. The production
RC2 MP include chain additionally confirms VANA is the GPIO7-switched 2.8 V
rail, not the unused later file's direct 1.352 V S3 supply.

This remains preview bring-up, not a complete camera stack. Hardware streaming
on the newly built image must be recorded before checking off support; 3A,
still capture, recording, rear telephoto, autofocus, OIS and framework
integration are still outside this preview milestone.

## Haptics source and port

The official Android 9 SMR7 source is present at
`vendor-source/razer-phone2-smr7/msm-4.9/`. Its PMI8998 DTS node describes the
integrated LRA haptics peripheral at `0xc000`, and both Cheryl2 defconfigs enable
Qualcomm PMIC haptics. The mainline equivalent is `qcom-spmi-haptics`, exposed
through Linux force feedback.

Razer's board DTS specifies 1300 mV, 800 mA, sine drive and a 6667 us period.
The mainline driver previously scaled full rumble to 3596 mV and exposed no DT
limit, so the port adds voltage/current properties and applies the factory
ceiling while retaining the standard force-feedback interface. Validate with
`scripts/diagnostics/phone-test-haptics.sh` before checking off support.

## Audio source and port

The official SMR7 RC2 board DTS proves the path is ADSP/QDSP6 + SLIMbus +
WCD9340 (tavil), plus two NXP TFA9912 smart amplifiers at I2C5 addresses 0x34
and 0x35 on QUAT MI2S. The port now enables the codec driver, the factory SD1
data line, both amplifier DAIs, and extracts the stock `tfa98xx.cnt` container from
the authenticated factory vendor image into the rootfs firmware directory.

Live logs also showed the stock ADSP boots and exposes APR over GLINK, but does
not publish the `msm/adsp/audio_pd` service expected by the generic SDM845 DTS.
That left the card deferred at `MultiMedia1`. The Razer override now registers
q6core/q6afe/q6asm/q6adm without that unavailable protection-domain gate.

The newly built image still needs `scripts/diagnostics/phone-test-audio.sh`,
`aplay -l`, mixer and playback checks before speakers, microphones, earpiece or
USB-C audio are marked complete.
