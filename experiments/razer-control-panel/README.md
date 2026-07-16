# Experimental power and WiFi panel

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
