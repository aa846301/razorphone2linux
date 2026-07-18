#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this diagnostic as root." >&2
	exit 1
fi

section()
{
	printf '\n===== %s =====\n' "$1"
}

section "kernel"
uname -a

section "panel service"
systemctl --no-pager --full status razer-control-panel.service || true
journalctl -u razer-control-panel.service -b --no-pager -n 300 || true

section "panel helper log"
cat /run/razer-camera-preview.log 2>&1 || true

section "installed helpers"
ls -l /usr/local/sbin/razer-control-panel \
	/usr/local/sbin/razer-camera-launch \
	/usr/local/sbin/razer-audio-test 2>&1 || true

section "media topology"
for media in /dev/media*; do
	[ -e "$media" ] || continue
	echo "--- $media ---"
	media-ctl -d "$media" -p 2>&1 || true
done

section "ALSA cards and PCMs"
cat /proc/asound/cards 2>&1 || true
aplay -l 2>&1 || true
aplay -L 2>&1 || true

section "speaker mixer"
amixer -c 0 controls 2>&1 | grep -Ei 'QUAT|MI2S|MultiMedia|TFA|Speaker' || true
amixer -c 0 cget name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 2>&1 || true

section "relevant kernel log"
dmesg | grep -Ei 's5k3h7|imx363|ac4a000.cci|camss|q6asm|quat|mi2s|tfa98|wcd934|slim' | tail -n 500 || true
