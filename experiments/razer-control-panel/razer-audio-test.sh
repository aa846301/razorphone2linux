#!/bin/sh
set -eu

for tool in aplay amixer speaker-test; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "$tool missing; install alsa-utils" >&2
		exit 1
	}
done

device=$(aplay -l | sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1,\2/p' | head -n1)
[ -n "$device" ] || {
	echo "ALSA playback device not found" >&2
	exit 1
}

amixer -c "${device%,*}" cset \
	name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1 >/dev/null

speaker-test -D "plughw:$device" -c 2 -t sine -f 440 -l 1
