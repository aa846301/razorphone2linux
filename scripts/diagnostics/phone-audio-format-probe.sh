#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

dump_tfa()
{
	local device=$1
	awk '$1 ~ /^(00:|01:|02:|10:|11:|20:|21:|22:|23:|40:|41:|42:)$/ { print }' \
		"/sys/kernel/debug/regmap/$device/registers"
}

amixer -c 0 cset name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1 >/dev/null

for format in S16_LE S24_LE S32_LE; do
	echo "===== $format ====="
	speaker-test -D hw:0,0 -c 2 -r 48000 -F "$format" -t sine -f 660 -l 1 \
		>"/tmp/razer-audio-$format.log" 2>&1 &
	pid=$!
	sleep 2
	cat /proc/asound/card0/pcm0p/sub0/hw_params 2>&1 || true
	echo "--- left TFA ---"
	dump_tfa 5-0034
	echo "--- right TFA ---"
	dump_tfa 5-0035
	kill -TERM "$pid" 2>/dev/null || true
	sleep 1
	kill -KILL "$pid" 2>/dev/null || true
	cat "/tmp/razer-audio-$format.log"
	dmesg | grep -Ei 'q6afe|mi2s|tfa98|invalid.*format|clock' | tail -n 35 || true
done
