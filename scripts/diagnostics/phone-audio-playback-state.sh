#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

echo "===== route before playback ====="
amixer -c 0 cget name='QUAT_MI2S_RX Audio Mixer MultiMedia1' || true
amixer -c 0 cset name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1 >/dev/null

speaker-test -D plughw:0,0 -c 2 -r 48000 -F S16_LE -t sine -f 440 -l 1 \
	>/tmp/razer-audio-trace-speaker-test.log 2>&1 &
speaker_pid=$!
sleep 2

echo "===== PCM while playing ====="
for file in /proc/asound/card0/pcm0p/sub0/{status,hw_params,sw_params}; do
	echo "--- $file ---"
	cat "$file" 2>&1 || true
done

echo "===== pin mux while playing ====="
grep -Ei 'GPIO_(58|59|60|61)|gpio(58|59|60|61)' \
	/sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null || true

echo "===== ASoC DAPM while playing ====="
find /sys/kernel/debug/asoc -type f -path '*/dapm/*' -print0 2>/dev/null |
	xargs -0 grep -H -Ei 'quat|mi2s|tfa|playback|speaker' 2>/dev/null || true

echo "===== TFA9912 status while playing ====="
for device in 5-0034 5-0035; do
	printf '%s: ' "$device"
	awk '$1 == "10:" { print }' "/sys/kernel/debug/regmap/$device/registers" \
		2>/dev/null || echo "status unavailable"
done

# A broken DSP/MI2S path can leave speaker-test blocked in drain forever.
# Sampling is complete, so terminate it without blocking this SSH diagnostic.
kill -TERM "$speaker_pid" 2>/dev/null || true
sleep 1
kill -KILL "$speaker_pid" 2>/dev/null || true

echo "===== speaker-test result ====="
cat /tmp/razer-audio-trace-speaker-test.log

echo "===== audio kernel tail ====="
dmesg | grep -Ei 'q6asm|q6afe|quat|mi2s|tfa98|audio' | tail -n 180 || true
