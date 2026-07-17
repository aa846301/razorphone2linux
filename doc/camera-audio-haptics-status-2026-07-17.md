# Camera, audio, and haptics status (2026-07-17)

## Live retest after `cc5ea43e`

- Front S5K3H7 still fails chip-ID access with `-ENXIO`; CAMSS therefore does
  not bind either sensor endpoint and the otherwise detected rear IMX363 has
  no media link. The next image corrects the front VANA/VDIG upstream rail
  model to match the factory `pm8998_s3` topology.
- The input FF API accepted effects, but no physical vibration was felt. The
  installed image incorrectly used buffer mode; factory `vibrator.dtsi` uses
  direct mode and explicitly disables LRA auto resonance. The next image
  restores those settings and extends the mainline driver accordingly.
- The sound card and both TFA9912 codecs register. Enabling
  `QUAT_MI2S_RX Audio Mixer MultiMedia1` starts and unmutes both codecs, but
  playback stops when the Razer ADSP rejects `ASM_CMD_SHARED_MEM_MAP_REGIONS`
  with status 1. PCM playback is therefore not complete; the next image logs
  the exact mapped address and size for comparison with the factory audio ION
  range `0x10000000..0x1fffffff`.

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
the launcher uses the complete RAW10 media-bus format names.

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
and 0x35 on QUAT MI2S. The port now enables the codec driver, both MI2S data
lines, both amplifier DAIs, and extracts the stock `tfa98xx.cnt` container from
the authenticated factory vendor image into the rootfs firmware directory.

Live logs also showed the stock ADSP boots and exposes APR over GLINK, but does
not publish the `msm/adsp/audio_pd` service expected by the generic SDM845 DTS.
That left the card deferred at `MultiMedia1`. The Razer override now registers
q6core/q6afe/q6asm/q6adm without that unavailable protection-domain gate.

The newly built image still needs `scripts/diagnostics/phone-test-audio.sh`,
`aplay -l`, mixer and playback checks before speakers, microphones, earpiece or
USB-C audio are marked complete.
