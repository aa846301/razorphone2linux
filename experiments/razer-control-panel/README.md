# Experimental power and WiFi panel

[繁體中文部署說明](README.zh-TW.md)

This DRM/KMS UI is intentionally excluded from normal rootfs and GitHub
Actions release builds. The deploy script cross-compiles its small ARM64 KMS
presenter and installs it over SSH after flashing:

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\deploy.ps1
```

Pass the phone's current WiFi address with `-HostName`, for example
`-HostName 10.1.3.110`, to deploy over WiFi instead of the default USB NCM
address. On the live test device, it disables `razer-panel-idle-blank.service`
and manages its own 60-second blanking and touch wake-up.

The default USB deployment command, which can also restore the SSH public key
after a userdata flash, is:

```powershell
powershell -ExecutionPolicy Bypass -File C:\repo\razorphone2linux\experiments\razer-control-panel\deploy.ps1
```

The deployed files on the phone are:

```text
/usr/local/sbin/razer-control-panel
/usr/local/sbin/razer-kms-present
/usr/local/sbin/razer-camera-preview
/usr/local/sbin/razer-camera-launch
/usr/local/sbin/razer-haptic-ff
/usr/local/sbin/razer-haptic-test
/usr/local/sbin/razer-audio-test
/usr/local/sbin/razer-shutdown-console
/etc/systemd/system/razer-control-panel.service
```

Check or restart it manually over SSH with:

```bash
sudo systemctl status razer-control-panel.service
sudo systemctl restart razer-control-panel.service
```

Because this experiment is not part of `rootfs.img`, rerun `deploy.ps1` after
every userdata/rootfs flash.

The rear/front camera buttons configure the qcom-camss media graph for a
1920x1080 RAW10 stream, start a small V4L2 preview helper, and return to the
dashboard with the `BACK` button. The helper performs `STREAMOFF`, unmaps all
capture buffers, and closes the video node on exit. `deploy.ps1` installs the
`v4l-utils` package when `media-ctl` is not already present. The `VIBRATE`
and `SOUND` buttons run a one-second force-feedback rumble and a short ALSA
440 Hz playback test. Their full helpers can also be run with `sudo` over SSH.

If a camera cannot start, the dashboard shows the last launcher error. The
complete launcher output remains available until the next attempt at
`/run/razer-camera-preview.log`; kernel probe details are in `dmesg` under
`imx363`, `s5k3h7`, or `camss`.

The dashboard reads the PMI8998 RRADC `usbin_v` and `usbin_i` channels for
actual external-input voltage, current, and power. It separately reads the
battery fuel-gauge current and labels the live source as `USB ONLY`,
`USB + BATTERY`, or `BATTERY ONLY`. This matters while charging is inhibited:
the SMB2 charger's normal `voltage_now` and `current_now` files may report zero
even though USB remains online.

The `CHARGE TO 100%` button is a manual test override. It stops
`razer-charge-limits.service`, selects `charge_behaviour=auto`, and restores
the normal 40-80 policy when charging completes or the user cancels it.

Nothing under this directory is referenced by `scripts/03-build-rootfs.sh`,
`scripts/03-refresh-rootfs.sh`, or `.github/workflows/build-image.yml`.

Remove the experiment and restore the normal idle blanking service with:

```powershell
powershell -ExecutionPolicy Bypass -File experiments\razer-control-panel\remove.ps1
```
