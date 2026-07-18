#!/bin/sh
set -eu

camera=$1
shared=$2
width=$3
height=$4

command -v media-ctl >/dev/null 2>&1 || {
	echo "media-ctl is not installed; deploy the camera userspace tools" >&2
	exit 1
}

media=
for candidate in /dev/media*; do
	[ -e "$candidate" ] || continue
	if media-ctl -d "$candidate" -p 2>/dev/null | grep -q 'driver.*qcom-camss'; then
		media=$candidate
		break
	fi
done
[ -n "$media" ] || { echo "qcom-camss media device not found" >&2; exit 1; }

topology=$(media-ctl -d "$media" -p)
case "$camera" in
	rear)
		sensor=$(printf '%s\n' "$topology" | sed -n 's/.*entity [0-9][0-9]*: \(imx363 [^ (]*\).*/\1/p' | head -n1)
		csiphy=msm_csiphy0
		format=SBGGR10_1X10
		bayer=BGGR
		mirror=0
		fourcc=pBAA
		raw_width=4032
		raw_height=3024
		;;
	front)
		sensor=$(printf '%s\n' "$topology" | sed -n 's/.*entity [0-9][0-9]*: \(s5k3h7 [^ (]*\).*/\1/p' | head -n1)
		csiphy=msm_csiphy2
		format=SGRBG10_1X10
		bayer=GRBG
		mirror=1
		fourcc=pGAA
		raw_width=1920
		raw_height=1080
		;;
	*) echo "unknown camera: $camera" >&2; exit 2 ;;
esac
[ -n "$sensor" ] || { echo "$camera sensor entity not found" >&2; exit 1; }

media-ctl -d "$media" --reset
media-ctl -d "$media" -V "\"$sensor\":0[fmt:$format/${raw_width}x${raw_height} field:none]"
media-ctl -d "$media" -V "\"$csiphy\":0[fmt:$format/${raw_width}x${raw_height}],\"$csiphy\":1[fmt:$format/${raw_width}x${raw_height}]"
media-ctl -d "$media" -V '"msm_csid0":0[fmt:'"$format"'/'"${raw_width}x${raw_height}"'],"msm_csid0":1[fmt:'"$format"'/'"${raw_width}x${raw_height}"']'
media-ctl -d "$media" -V '"msm_vfe0_rdi0":0[fmt:'"$format"'/'"${raw_width}x${raw_height}"'],"msm_vfe0_rdi0":1[fmt:'"$format"'/'"${raw_width}x${raw_height}"']'
media-ctl -d "$media" -l "\"$csiphy\":1->\"msm_csid0\":0[1]"
media-ctl -d "$media" -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
video=$(media-ctl -d "$media" -e msm_vfe0_video0)
[ -n "$video" ] || { echo "VFE video node not found" >&2; exit 1; }

# The driver's incomplete 1920x1080 IMX363 mode produces a four-pixel phase
# error in the sensor RAW stream. The complete 4032x3024 mode is verified clean,
# so the diagnostic panel captures that mode and scales it for preview.
# This panel does not run Android CamX/3A; use bounded fixed controls that were
# validated on the phone and leave environment overrides for further tuning.
if [ "$camera" = rear ] && command -v v4l2-ctl >/dev/null 2>&1; then
	sensor_dev=$(media-ctl -d "$media" -e "$sensor")
	v4l2-ctl -d "$sensor_dev" --set-ctrl \
		"exposure=${RAZER_REAR_EXPOSURE:-3000},analogue_gain=${RAZER_REAR_ANALOGUE_GAIN:-400},digital_gain=${RAZER_REAR_DIGITAL_GAIN:-4096}"
fi

exec /usr/local/sbin/razer-camera-preview "$video" "$shared" "$width" "$height" "$bayer" "$mirror" "$fourcc" "$camera" "$raw_width" "$raw_height"
