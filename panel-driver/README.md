# NT36830 native DRM panel driver

`panel-novatek-nt36830.c` is an implemented native driver, not only a
generator experiment.

Implemented:

- dual MIPI-DSI host registration using the Linux 7.1 devm lifecycle;
- Razer/FIH panel initialization and shutdown command sequences;
- VESA DSC 1.1, one 720-pixel slice per DSI interface;
- combined 1440x2560 modes at 60 Hz and 120 Hz;
- 10-bpc DSC configuration at 8 bpp;
- 12-bit DCS backlight updates sent to both DSI links;
- panel orientation from DT (`rotation = <90>`);
- three-supply and reset-GPIO sequencing;
- DT binding in `novatek,nt36830.yaml`.

Validated on the pinned `sdm845/7.1-dev` kernel:

- driver compilation;
- built-in linkage with MSM DRM/DPU/DSI;
- Razer DTB compilation;
- `dt_binding_check` for `novatek,nt36830.yaml`;
- display-related `CHECK_DTBS=y` validation.

Physical scanout is not yet claimed as working. The next test must use a
recoverable A/B boot image and serial/USB observation. The known-working 6.16
WiFi/Helix image is documented in `../RECOVERY.md`.

The generator remains available for reproducible factory-DT comparison:

```bash
bash scripts/generate-panel-driver.sh
```

Its output under `generated-reference/` is intentionally ignored by Git.
