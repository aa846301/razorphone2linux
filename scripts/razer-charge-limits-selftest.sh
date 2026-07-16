#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_SCRIPT="$PROJECT_DIR/rootfs-scripts/razer-charge-limits.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/power/BAT0" "$TEST_ROOT/power/USB0" "$TEST_ROOT/state"
printf 'Battery\n' > "$TEST_ROOT/power/BAT0/type"
printf 'USB\n' > "$TEST_ROOT/power/USB0/type"
printf '1\n' > "$TEST_ROOT/power/USB0/online"

run_policy() {
    RAZER_POWER_SUPPLY_ROOT="$TEST_ROOT/power" \
    RAZER_CHARGE_STATE_FILE="$TEST_ROOT/state/policy" \
    RAZER_CHARGE_ONCE=1 \
        bash "$POLICY_SCRIPT" >/dev/null
}

assert_file() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(cat "$path")"
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: expected %s=%s, got %s\n' \
            "$path" "$expected" "$actual" >&2
        exit 1
    fi
}

# A fresh install in the middle of the range must immediately prefer external
# power instead of charging to 80% first.
printf '60\n' > "$TEST_ROOT/power/BAT0/capacity"
printf '[auto] inhibit-charge\n' > "$TEST_ROOT/power/USB0/charge_behaviour"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" inhibit-charge
assert_file "$TEST_ROOT/state/policy" external-power

# Reaching 40% starts a latched charge cycle. It remains active in the middle
# of the range and completes only at 80%.
printf '40\n' > "$TEST_ROOT/power/BAT0/capacity"
printf 'auto [inhibit-charge]\n' > "$TEST_ROOT/power/USB0/charge_behaviour"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" auto
assert_file "$TEST_ROOT/state/policy" charge-cycle

printf '60\n' > "$TEST_ROOT/power/BAT0/capacity"
printf '[auto] inhibit-charge\n' > "$TEST_ROOT/power/USB0/charge_behaviour"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" '[auto] inhibit-charge'
assert_file "$TEST_ROOT/state/policy" charge-cycle

printf '80\n' > "$TEST_ROOT/power/BAT0/capacity"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" inhibit-charge
assert_file "$TEST_ROOT/state/policy" external-power

# Legacy state is deliberately migrated to external-power-first because old
# "auto" did not prove that capacity had actually crossed 40%.
printf 'auto\n' > "$TEST_ROOT/state/policy"
printf '60\n' > "$TEST_ROOT/power/BAT0/capacity"
printf 'auto\n' > "$TEST_ROOT/power/USB0/charge_behaviour"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" inhibit-charge
assert_file "$TEST_ROOT/state/policy" external-power

# Do not change charger controls while no external input is present.
printf '0\n' > "$TEST_ROOT/power/USB0/online"
printf 'auto\n' > "$TEST_ROOT/power/USB0/charge_behaviour"
run_policy
assert_file "$TEST_ROOT/power/USB0/charge_behaviour" auto

printf 'PASS: external-power-first 40-80 charge policy works correctly\n'
