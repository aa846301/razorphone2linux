#!/bin/bash
set -euo pipefail

START="${RAZER_CHARGE_START_PERCENT:-40}"
STOP="${RAZER_CHARGE_STOP_PERCENT:-80}"
POLL_SECONDS="${RAZER_CHARGE_POLL_SECONDS:-30}"
POWER_SUPPLY_ROOT="${RAZER_POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
RUN_ONCE="${RAZER_CHARGE_ONCE:-0}"
STATE_FILE="${RAZER_CHARGE_STATE_FILE:-/var/lib/razer-charge-limits/state}"

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

find_charger() {
    local psy

    for psy in "$POWER_SUPPLY_ROOT"/*; do
        [ -r "$psy/type" ] || continue
        [ "$(cat "$psy/type")" = "USB" ] || continue
        [ -r "$psy/charge_behaviour" ] || continue
        printf '%s\n' "$psy"
        return 0
    done
    return 1
}

active_behaviour() {
    local raw

    raw="$(cat "$1/charge_behaviour")"
    if [[ "$raw" =~ \[([^]]+)\] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$raw"
    fi
}

save_mode() {
    mkdir -p "$(dirname "$STATE_FILE")"
    printf '%s\n' "$1" > "$STATE_FILE"
}

if ! [[ "$START" =~ ^[0-9]+$ && "$STOP" =~ ^[0-9]+$ ]] ||
        [ "$START" -ge "$STOP" ] || [ "$STOP" -gt 100 ]; then
    log "invalid thresholds: start=$START stop=$STOP"
    exit 1
fi

# Prefer the external input after a fresh install or migration. A charge cycle
# starts only after capacity reaches START and stays latched through STOP.
mode="external-power"
if [ -r "$STATE_FILE" ]; then
    saved_mode="$(cat "$STATE_FILE")"
    case "$saved_mode" in
        external-power|charge-cycle) mode="$saved_mode" ;;
        *) save_mode "$mode" ;;
    esac
else
    save_mode "$mode"
fi

log "policy active: external power above ${START}%; charge ${START}-${STOP}%"

while true; do
    battery="$(find_supply Battery || true)"
    charger="$(find_charger || true)"

    if [ -n "$battery" ] && [ -r "$battery/capacity" ] &&
            [ -n "$charger" ] && [ -w "$charger/charge_behaviour" ]; then
        capacity="$(cat "$battery/capacity")"

        if [[ "$capacity" =~ ^[0-9]+$ ]]; then
            if [ "$capacity" -le "$START" ] && [ "$mode" != "charge-cycle" ]; then
                mode="charge-cycle"
                save_mode "$mode"
                log "capacity=${capacity}%: charge cycle started"
            elif [ "$capacity" -ge "$STOP" ] && [ "$mode" != "external-power" ]; then
                mode="external-power"
                save_mode "$mode"
                log "capacity=${capacity}%: charge cycle complete"
            fi

            online="$(cat "$charger/online" 2>/dev/null || echo 0)"
            if [ "$online" = "1" ]; then
                behaviour="$(active_behaviour "$charger")"
                if [ "$mode" = "charge-cycle" ]; then
                    desired="auto"
                else
                    desired="inhibit-charge"
                fi

                if [ "$behaviour" != "$desired" ]; then
                    printf '%s\n' "$desired" > "$charger/charge_behaviour"
                    log "capacity=${capacity}%: mode=${mode}, behaviour=${desired}"
                fi
            fi
        else
            log "ignoring invalid capacity '$capacity'"
        fi
    elif [ "$RUN_ONCE" = "1" ]; then
        log "charger charge_behaviour or battery capacity is unavailable"
    fi

    [ "$RUN_ONCE" = "1" ] && break
    sleep "$POLL_SECONDS"
done
