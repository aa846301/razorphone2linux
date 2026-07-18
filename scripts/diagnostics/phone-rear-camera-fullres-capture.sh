#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

output=${1:-/tmp/razer-rear-4032x3024.raw10}
media=
for candidate in /dev/media*; do
	[ -e "$candidate" ] || continue
	candidate_topology=$(media-ctl -d "$candidate" -p 2>/dev/null || true)
	if grep -q 'driver.*qcom-camss' <<<"$candidate_topology"; then
		media=$candidate
		break
	fi
done
[ -n "$media" ] || { echo "qcom-camss media device not found" >&2; exit 1; }

topology=$(media-ctl -d "$media" -p)
sensor=$(printf '%s\n' "$topology" |
	sed -n 's/.*entity [0-9][0-9]*: \(imx363 [^ (]*\).*/\1/p' | head -n1)
[ -n "$sensor" ] || { echo "IMX363 entity not found" >&2; exit 1; }

media-ctl -d "$media" --reset
media-ctl -d "$media" -V "\"$sensor\":0[fmt:SBGGR10_1X10/4032x3024 field:none]"
media-ctl -d "$media" -V '"msm_csiphy0":0[fmt:SBGGR10_1X10/4032x3024],"msm_csiphy0":1[fmt:SBGGR10_1X10/4032x3024]'
media-ctl -d "$media" -V '"msm_csid0":0[fmt:SBGGR10_1X10/4032x3024],"msm_csid0":1[fmt:SBGGR10_1X10/4032x3024]'
media-ctl -d "$media" -V '"msm_vfe0_rdi0":0[fmt:SBGGR10_1X10/4032x3024],"msm_vfe0_rdi0":1[fmt:SBGGR10_1X10/4032x3024]'
media-ctl -d "$media" -l "\"msm_csiphy0\":1->\"msm_csid0\":0[1]"
media-ctl -d "$media" -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'

sensor_dev=$(media-ctl -d "$media" -e "$sensor")
video=$(media-ctl -d "$media" -e msm_vfe0_video0)
[ -n "$sensor_dev" ] && [ -n "$video" ] || { echo "camera device node missing" >&2; exit 1; }

v4l2-ctl -d "$sensor_dev" --set-ctrl \
	"exposure=${RAZER_REAR_EXPOSURE:-3000},analogue_gain=${RAZER_REAR_ANALOGUE_GAIN:-400},digital_gain=${RAZER_REAR_DIGITAL_GAIN:-4096}"
rm -f -- "$output"
v4l2-ctl -d "$video" \
	--set-fmt-video width=4032,height=3024,pixelformat=pBAA \
	--stream-mmap 4 --stream-skip 2 --stream-count 1 --stream-to "$output" --verbose

stat --printf='capture=%n bytes=%s\n' "$output"
v4l2-ctl -d "$sensor_dev" --get-subdev-fmt pad=0,stream=0
v4l2-ctl -d "$video" --get-fmt-video
