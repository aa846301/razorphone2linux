#!/bin/bash
set -euo pipefail

START="${RAZER_CHARGE_START_PERCENT:-40}"
STOP="${RAZER_CHARGE_STOP_PERCENT:-80}"
POLL_SECONDS="${RAZER_CHARGE_POLL_SECONDS:-30}"
POWER_SUPPLY_ROOT="${RAZER_POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
RUN_ONCE="${RAZER_CHARGE_ONCE:-0}"

log() {
    printf 'razer-charge-limits: %s\n' "$*" >&2
}

find_supply() {
    local wanted_type="$1"
    local psy

    for psy in "$POWER_SUPPLY_ROOT"/*; do
        [ -r "$psy/type" ] || continue
        if [ "$(cat "$psy/type")" = "$wanted_type" ]; then
            printf '%s\n' "$psy"
            return 0
        fi
    done
    return 1
}

if ! [[ "$START" =~ ^[0-9]+$ && "$STOP" =~ ^[0-9]+$ ]] ||
        [ "$START" -ge "$STOP" ] || [ "$STOP" -gt 100 ]; then
    log "invalid thresholds: start=$START stop=$STOP"
    exit 1
fi

log "policy active: resume at <=${START}%, suspend at >=${STOP}%"

while true; do
    battery="$(find_supply Battery || true)"
    charger="$(find_supply USB || true)"

    if [ -n "$battery" ] && [ -r "$battery/capacity" ] &&
            [ -n "$charger" ] && [ -w "$charger/status" ]; then
        capacity="$(cat "$battery/capacity")"
        status="$(cat "$charger/status")"

        if [[ "$capacity" =~ ^[0-9]+$ ]]; then
            if [ "$capacity" -ge "$STOP" ] && [ "$status" != "Discharging" ]; then
                # qcom_smbx maps POWER_SUPPLY_STATUS_UNKNOWN to USB input suspend.
                printf 'Unknown\n' > "$charger/status"
                log "capacity=${capacity}%: charging suspended"
            elif [ "$capacity" -le "$START" ] && [ "$status" != "Charging" ]; then
                printf 'Charging\n' > "$charger/status"
                log "capacity=${capacity}%: charging resumed"
            fi
        else
            log "ignoring invalid capacity '$capacity'"
        fi
    elif [ "$RUN_ONCE" = "1" ]; then
        log "charger or battery power supply is unavailable"
    fi

    [ "$RUN_ONCE" = "1" ] && break
    sleep "$POLL_SECONDS"
done
