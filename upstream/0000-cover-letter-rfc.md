Subject: [RFC PATCH 0/6] arm64: qcom: initial Razer Phone 2 support

Add initial mainline support for the Razer Phone 2, also known as `aura`.
The device is based on Qualcomm SDM845.

The current development image boots Ubuntu 24.04 from the userdata
partition. UFS, USB gadget networking, SSH, Synaptics RMI4 touch and the
bootloader-provided framebuffer are usable. WiFi has also been demonstrated,
but currently depends on a Razer/FIH NV reserved-memory handoff plus Qualcomm
userspace services and is kept separate from the minimal board submission.

The built-in NT36830 panel is dual-DSI with DSC. A native DRM panel driver,
binding, 60/120 Hz modes and the board display graph are implemented and pass
compile/link and schema checks. Physical DRM scanout is not yet validated, so
the first board submission should remain conservative about display support.

This RFC is intended to establish the acceptable DT representation and patch
split before a send-ready v1. Known gaps and test status are documented in
`upstream/STATUS.md`.

Proposed series:

  1. dt-bindings: arm: qcom: add Razer Phone 2
  2. arm64: dts: qcom: add initial Razer Phone 2 support
  3. dt-bindings: display: panel: add Razer NT36830 panel
  4. drm/panel: add Novatek NT36830 panel support
  5. dt-bindings: remoteproc: document Razer FIH NV memory
  6. remoteproc: qcom_q6v5_mss: share Razer FIH NV memory

The final submission may be split into independent board, panel and
remoteproc series according to maintainer feedback.

Assisted-by: Codex:gpt-5

---

Development base: sdm845/7.1-dev at 85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8.
Send base: to be selected from the current Qualcomm maintainer tree.
Testing: full base/printer builds; panel compile/link; panel dt_binding_check;
Razer DTB with CHECK_DTBS=y.
Not yet tested: native NT36830 scanout on physical hardware.
