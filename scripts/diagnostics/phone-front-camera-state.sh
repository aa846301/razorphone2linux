#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this diagnostic as root." >&2
	exit 1
fi

echo "Kernel: $(uname -r)"
echo "CCI adapters:"
for adapter in /sys/class/i2c-adapter/i2c-*; do
	[ -e "$adapter" ] || continue
	name=$(cat "$adapter/name" 2>/dev/null || true)
	case "$name" in
		*CCI*|*cci*) printf '%s: %s\n' "${adapter##*/}" "$name" ;;
	esac
done

echo "CCI runtime PM:"
for item in runtime_status control; do
	path="/sys/bus/platform/devices/ac4a000.cci/power/$item"
	[ -r "$path" ] && printf '%s=%s\n' "$item" "$(cat "$path")"
done

echo "Relevant TLMM pin mux state:"
for path in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
	[ -r "$path" ] || continue
	grep -E 'pin (9|15|19|20) ' "$path" || true
done

echo "Relevant TLMM pin configuration:"
for path in /sys/kernel/debug/pinctrl/*/pinconf-pins; do
	[ -r "$path" ] || continue
	grep -E 'pin (9|15|19|20) ' "$path" || true
done

echo "Front-camera regulators:"
for regulator in /sys/class/regulator/*; do
	[ -r "$regulator/name" ] || continue
	name=$(cat "$regulator/name")
	case "$name" in
		front_camera_*)
			state=$(cat "$regulator/state" 2>/dev/null || echo unknown)
			printf '%s: %s\n' "$name" "$state"
			;;
	esac
done

echo "Front-camera and CCI log tail:"
dmesg | grep -Ei 's5k3h7|ac4a000.cci|master 1|cci1' | tail -n 120 || true
