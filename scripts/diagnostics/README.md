# Bring-up diagnostics

These scripts preserve one-off or narrowly scoped experiments from WiFi, MSS,
rmtfs, QRTR, DIAG, and stock Android comparison work. They do not participate
in `build-all.sh`, rootfs assembly, boot packaging, release artifacts, or
GitHub Actions.

The collection is retained because the project documentation records both
successful and failed hardware experiments. Keeping the exact reproducers
prevents repeating destructive or inconclusive tests from memory.

## Host-side builders and captures

- `build-diag-router-live.sh`
- `build-pdmapper-live.sh`
- `capture-android-wifi-mechanism.sh`
- `deploy-pmos-mss-diag-live.ps1`
- `prepare-rmtfs-detail-live.sh`

## Phone-side experiments

Files named `phone-*.sh` are copied to a live phone and run explicitly. Many
require root and may stop remote processors, replace live modules, alter module
autoload policy, or reboot the device. Read the script and its matching status
document before use. None are safe general-purpose setup commands.

Run host-side commands from the repository root, for example:

```bash
bash scripts/diagnostics/build-pdmapper-live.sh
```

The following read-only bring-up tests are safe to copy to the phone after a
matching kernel/rootfs image is installed:

- `phone-test-haptics.sh` finds the PMI8998 `spmi_haptics` input node and plays
  one `FF_RUMBLE` effect with `fftest`.
- `phone-test-audio.sh` lists ALSA PCMs and plays one stereo sine-test pass. An
  explicit ALSA PCM name can be passed as its first argument.

### Front camera

`phone-front-camera-state.sh` captures the live CCI1, GPIO9/GPIO15,
regulator, and S5K3H7 probe state. Run it as root on the phone after a failed
front-camera probe so the failure can be separated from the control panel.
