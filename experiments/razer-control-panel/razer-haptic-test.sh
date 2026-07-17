#!/bin/sh
set -eu

command -v fftest >/dev/null 2>&1 || {
	echo "fftest missing; install joystick" >&2
	exit 1
}

play_mode=
for property in $(find /sys/firmware/devicetree/base -path '*haptics@c000/qcom,play-mode' 2>/dev/null); do
	play_mode=$(od -An -tx1 -N4 "$property" | tr -d ' \n')
	break
done
if [ "$play_mode" = "00000001" ]; then
	echo "new boot required: haptics still uses buffer mode" >&2
	exit 1
fi

event=
for name in /sys/class/input/event*/device/name; do
	[ -r "$name" ] || continue
	if grep -qx 'spmi_haptics' "$name"; then
		event="/dev/input/$(basename "${name%/device/name}")"
		break
	fi
done

[ -n "$event" ] && [ -c "$event" ] || {
	echo "spmi_haptics device not found" >&2
	exit 1
}

{
	printf '4\n'
	sleep 1
	printf '%s\n' -1
} | timeout 6s fftest "$event"
