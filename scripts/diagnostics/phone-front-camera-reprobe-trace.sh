#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

device=17-0010
driver=/sys/bus/i2c/drivers/s5k3h7
trace=/sys/kernel/tracing
if [ ! -e "$trace/tracing_on" ]; then
	trace=/tmp/razer-tracefs
	mkdir -p "$trace"
	mount -t tracefs nodev "$trace" 2>/dev/null || true
fi
if [ ! -e "$trace/tracing_on" ]; then
	trace=/sys/kernel/debug/tracing
fi

echo "===== device and driver ====="
ls -ld "/sys/bus/i2c/devices/$device" "$driver" 2>&1 || true

if [ ! -w "$driver/bind" ]; then
	echo "s5k3h7 bind control is unavailable" >&2
	exit 1
fi

echo "===== static power state before reprobe ====="
grep -Ei '^ gpio(4|7|8|9) ' /sys/kernel/debug/gpio 2>/dev/null || true
grep -Ei 'gpio(4|7|8|9)( |$)|GPIO_(4|7|8|9)( |$)|cam_mclk2' \
	/sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null || true

# The sensor probe keeps the rails active for only about 20 ms.  When tracefs
# is unavailable, sample debugfs in parallel with the synchronous bind write so
# that a post-failure snapshot does not hide a rail that did turn on.
(
	i=0
	while [ "$i" -lt 80 ]; do
		printf 'sample=%02d time_ns=%s ' "$i" "$(date +%s%N)"
		{ grep -Ei '^ gpio(4|7|8|9) ' /sys/kernel/debug/gpio 2>/dev/null || true; } |
			tr '\n' ';'
		{ grep -E 'front_camera_(iovdd|vana|vdig)' \
			/sys/kernel/debug/regulator/regulator_summary 2>/dev/null || true; } |
			awk '{ printf "%s:use=%s:open=%s:uV=%s;", $1, $2, $3, $5 }'
		{ grep -E '^[[:space:]]+cam_cc_mclk2_clk[[:space:]]' \
			/sys/kernel/debug/clk/clk_summary 2>/dev/null || true; } |
			awk '{ printf "%s:enable=%s:prepare=%s:rate=%s;", $1, $2, $3, $5 }'
		printf '\n'
		i=$((i + 1))
		sleep 0.001
	done
) >/tmp/razer-front-camera-power-samples.log &
sampler_pid=$!

echo "===== available trace groups ====="
find "$trace/events" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
	grep -E '^(clk|gpio|i2c|regulator|rpm|power)$' || true

trace_available=0
if [ -e "$trace/tracing_on" ]; then
	trace_available=1
	echo 0 > "$trace/tracing_on"
	: > "$trace/trace"
fi

for group in gpio regulator clk; do
	if [ -w "$trace/events/$group/enable" ]; then
		echo 1 > "$trace/events/$group/enable"
	fi
done

if [ "$trace_available" -eq 1 ]; then
	echo 1 > "$trace/tracing_on"
fi
echo "$device" > "$driver/bind" || true
wait "$sampler_pid" || true
if [ "$trace_available" -eq 1 ]; then
	echo 0 > "$trace/tracing_on"
fi

echo "===== reprobe dmesg ====="
dmesg | grep -Ei 's5k3h7|ac4a000.cci|master 1|cci1' | tail -n 80 || true

echo "===== power trace ====="
if [ "$trace_available" -eq 1 ]; then
	grep -Ei 'front_camera|front-camera|gpio-9|gpio_9|cam_mclk2|mclk2|s5k3h7|vreg_s3a|1p35' \
		"$trace/trace" || true
else
	echo "tracefs unavailable"
fi

echo "===== sampled PMIC GPIO state during reprobe ====="
cat /tmp/razer-front-camera-power-samples.log

echo "===== regulators after reprobe ====="
grep -E 'front_camera|vreg_s3a_1p35' /sys/kernel/debug/regulator/regulator_summary || true

for group in gpio regulator clk; do
	if [ -w "$trace/events/$group/enable" ]; then
		echo 0 > "$trace/events/$group/enable"
	fi
done
