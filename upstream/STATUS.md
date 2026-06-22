# Razer Phone 2 (`aura`) upstream status

## Runtime status

| Area | Status | Upstream readiness |
| --- | --- | --- |
| UFS/rootfs | Boots Ubuntu 24.04 from userdata | Good basis for board DTS |
| USB gadget/SSH | Working | Userspace policy, not an upstream kernel patch |
| Touch | Synaptics RMI4 input device works | DTS needs schema validation |
| WiFi | Working after MSS FIH-NV sharing, rmtfs/pd-mapper/tqftpserv and ath10k quirk | Driver/DTS ABI needs maintainer review |
| Display | NT36830 dual-DSI/DSC driver compiles and links on 7.1; 60/120 Hz modes and binding are implemented | Hardware scanout validation still required |
| Audio/GPU/camera/sensors | Partial or unvalidated | Do not claim support upstream yet |

## Proposed patch split

1. `dt-bindings: arm: qcom: add Razer Phone 2`
2. `arm64: dts: qcom: add initial Razer Phone 2 support`
3. `dt-bindings: display: panel: add Razer NT36830 panel`
4. `drm/panel: add Novatek NT36830 panel support`
5. `dt-bindings: remoteproc: document Razer FIH NV memory`
6. `remoteproc: qcom_q6v5_mss: share Razer FIH NV memory`
7. Follow-up DTS patches enabling display and WiFi after the bindings/drivers
   are accepted.

The first submission should be smaller than the full list. A conservative path
is initial board support with display disabled, followed by separate panel and
WiFi series.

## Blocking work before sending

- Rebase onto the current Qualcomm maintainer tree or linux-next, not only the
  pinned SDM845 development branch.
- Remove project-only boot policy and diagnostic properties from the DTS.
- Split the currently working board, panel and remoteproc bindings into
  reviewable upstream commits.
- Run `make CHECK_DTBS=y qcom/sdm845-razer-aura.dtb` and resolve warnings.
- Run `scripts/checkpatch.pl --strict` on every patch.
- Test each patch boundary so the series remains bisectable.
- Validate the NT36830 driver on physical hardware at conservative 60 Hz,
  then test 120 Hz. The current code uses the factory 10-bpc, slice-height 8
  command-mode assumptions and one 720-pixel DSC slice per DSI interface.
- Decide with Qualcomm remoteproc maintainers whether `qcom,fih-nv-memory-region`
  is an acceptable DT ABI or whether the memory should be described through an
  existing mechanism.
- Obtain permission before adding any `Tested-by` or `Reviewed-by` tag.
- The human submitter must add `Signed-off-by`; Codex will not add it.

## Required checks

```bash
make dt_binding_check
make CHECK_DTBS=y qcom/sdm845-razer-aura.dtb
scripts/checkpatch.pl --strict 000*.patch
scripts/get_maintainer.pl 000*.patch
git format-patch --base=auto --cover-letter <upstream-base>
```

AI assistance should be disclosed in affected commits with:

```text
Assisted-by: Codex:gpt-5
```
