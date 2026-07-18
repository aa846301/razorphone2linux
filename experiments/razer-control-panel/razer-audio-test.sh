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

log=/tmp/razer-panel-speaker-test.log
speaker-test -D "plughw:$device" -c 2 -r 48000 -F S16_LE -t sine -f 440 -l 1 \
	>"$log" 2>&1 &
speaker_pid=$!
sleep 1
if ! kill -0 "$speaker_pid" 2>/dev/null; then
	status=0
	wait "$speaker_pid" || status=$?
	cat "$log"
	exit "$status"
fi
sleep 5
kill -TERM "$speaker_pid" 2>/dev/null || true
sleep 1
kill -KILL "$speaker_pid" 2>/dev/null || true
cat "$log"
