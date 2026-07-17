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
		format=SRGGB10
		bayer=RGGB
		mirror=0
		fourcc=pRAA
		;;
	front)
		sensor=$(printf '%s\n' "$topology" | sed -n 's/.*entity [0-9][0-9]*: \(s5k3h7 [^ (]*\).*/\1/p' | head -n1)
		csiphy=msm_csiphy2
		format=SGRBG10
		bayer=GRBG
		mirror=1
		fourcc=pGAA
		;;
	*) echo "unknown camera: $camera" >&2; exit 2 ;;
esac
[ -n "$sensor" ] || { echo "$camera sensor entity not found" >&2; exit 1; }

media-ctl -d "$media" --reset
media-ctl -d "$media" -V "\"$sensor\":0[fmt:$format/1920x1080 field:none]"
media-ctl -d "$media" -V "\"$csiphy\":0[fmt:$format/1920x1080],\"$csiphy\":1[fmt:$format/1920x1080]"
media-ctl -d "$media" -V '"msm_csid0":0[fmt:'"$format"'/1920x1080],"msm_csid0":1[fmt:'"$format"'/1920x1080]'
media-ctl -d "$media" -V '"msm_vfe0_rdi0":0[fmt:'"$format"'/1920x1080],"msm_vfe0_rdi0":1[fmt:'"$format"'/1920x1080]'
media-ctl -d "$media" -l "\"$csiphy\":1->\"msm_csid0\":0[1]"
media-ctl -d "$media" -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
video=$(media-ctl -d "$media" -e msm_vfe0_rdi0)
[ -n "$video" ] || { echo "VFE video node not found" >&2; exit 1; }

exec /usr/local/sbin/razer-camera-preview "$video" "$shared" "$width" "$height" "$bayer" "$mirror" "$fourcc"
