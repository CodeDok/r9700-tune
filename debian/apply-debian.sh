#!/bin/bash
# apply-debian.sh - ordered apply for the Debian 13 / kernel 7.2.6 port.
#
# Encodes the apply order from docs/PORT-PLAN-debian13-k8s.md §7.4:
#
#   1. existing amd-fan-tune / amd-power-tune units (unchanged)
#   2. gen-offsets.sh -> load r9700_tune_v2 with dry_run=1 (gate), then switch
#      the loaded module to dry_run=0
#   3. module stages the Ppt offset -> commit with `echo c > pp_od_clk_voltage`
#   4. `echo auto > power_dpm_force_performance_level`
#   5. soft max applied AFTER the commit and AFTER `echo auto`
#   6. power1_cap last
#   7. verify and log
#
# Modes:
#   --dry-run (default)  self-check gate only: loads the module with dry_run=1,
#                        logs what it would do, unloads it again. Restarts no
#                        units and writes nothing to the card (Stage A).
#   --apply              full ordered apply, including unit restarts (1) and
#                        `echo auto` (4).
#   --check              drift check: no unit restarts, no `echo auto`; commits
#                        the Ppt only if the staging buffer differs or the GPU
#                        was reset since the last commit, then re-applies the
#                        soft max. Used by amd-sclk-cap.service and the timer.
#
# Configuration: /etc/default/r9700-tune (see r9700-tune.default). The defaults
# are no-ops so the staged bring-up (§7.3) is done by editing that file.
#
# Nothing here persists across a power cycle. The module refuses to act if any
# self-check fails; this script stops at the first failure and does not retry.

set -uo pipefail

# ------------------------- configuration -------------------------
CONF=${R9700_TUNE_CONF:-/etc/default/r9700-tune}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

PCI=${PCI:-0000:03:00.0}
SCLK_MAX=${SCLK_MAX:-0}               # MHz, 0 = no soft max
PPT_OFFSET=${PPT_OFFSET:-0}           # percent, 0 or negative (plan notation: -35)
POWER1_CAP=${POWER1_CAP:-}            # microwatts, empty = leave to amd-power-tune
UNITS=(amd-fan-tune.service amd-power-tune.service)

MODE=dry-run
for a in "$@"; do
    case "$a" in
        --dry-run) MODE=dry-run ;;
        --apply)   MODE=apply ;;
        --check)   MODE=check ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

MOD=r9700_tune_v2
LOG=/var/log/r9700-tune.log
[ -w /var/log ] || LOG=/tmp/r9700-tune.log
STATE=/run/r9700-tune.state
LOCK=/run/r9700-tune.lock

log() { printf '%s [%s] %s\n' "$(date -Is)" "$MODE" "$*" | tee -a "$LOG" >&2; }
fail() { log "ABORT: $*"; exit 1; }

[[ $SCLK_MAX =~ ^[0-9]+$ ]] || fail "SCLK_MAX=$SCLK_MAX is not a number"
[[ $PPT_OFFSET =~ ^(0|-[0-9]+)$ ]] || fail "PPT_OFFSET=$PPT_OFFSET must be 0 or negative (e.g. -35)"
[[ -z $POWER1_CAP || $POWER1_CAP =~ ^[0-9]+$ ]] || fail "POWER1_CAP=$POWER1_CAP is not a number (microwatts)"

# ------------------------- discovery -----------------------------
# By PCI address, not card index: card0 is the Intel iGPU on this VM.
DEV=/sys/bus/pci/devices/$PCI
[ -d "$DEV" ] || fail "no PCI device $PCI"
[ "$(cat "$DEV/vendor")" = 0x1002 ] && [ "$(cat "$DEV/device")" = 0x7551 ] \
    || fail "$PCI is $(cat "$DEV/vendor"):$(cat "$DEV/device"), not the R9700"

ODSYS="$DEV/pp_od_clk_voltage"
LEVEL="$DEV/power_dpm_force_performance_level"
FAN="$DEV/gpu_od/fan_ctrl"
HWMON=$(ls -d "$DEV"/hwmon/hwmon* 2>/dev/null | head -1)
[ -w "$ODSYS" ] || fail "$ODSYS not writable"
[ -n "$HWMON" ] || fail "no hwmon under $DEV"

HERE=$(dirname "$(readlink -f "$0")")
[ -x "$HERE/gen-offsets.sh" ] || fail "$HERE/gen-offsets.sh not executable"

PARAMS=/sys/module/$MOD/parameters

# ------------------------- 1. existing units ---------------------
# Restarting them also restarts amd-sclk-cap.service (PartOf=), which runs
# --check; the lock below serialises the two runs, and both are idempotent.
if [ "$MODE" = apply ]; then
    for u in "${UNITS[@]}"; do
        if systemctl is-active "$u" >/dev/null 2>&1; then
            log "restarting $u"
            systemctl restart "$u" || fail "restart of $u failed"
        fi
    done
    sleep 5
fi

exec 9>"$LOCK"
flock -w 300 9 || fail "another r9700-tune run holds $LOCK"

# ------------------------- fingerprint ---------------------------
# Read after the unit restarts, which may change these values. The module
# cross-checks them against the OD staging buffer, which catches a wrong
# intra-table offset before anything is written. Each gpu_od file prints
# "NAME:\n<value>\nOD_RANGE:\n..." - the value is line 2. sysfs reports only
# zone 0 for the voltage offset, so only zone 0 is compared.
od_value() { sed -n 2p "$1" 2>/dev/null | tr -dc '0-9-'; }
exp_fminpwm=$(od_value "$FAN/fan_minimum_pwm")
exp_ac_target=$(od_value "$FAN/acoustic_target_rpm_threshold")
exp_ac_limit=$(od_value "$FAN/acoustic_limit_rpm_threshold")
exp_fan_target=$(od_value "$FAN/fan_target_temperature")
exp_vo0=$(grep -A1 "^OD_VDDGFX_OFFSET:" "$ODSYS" 2>/dev/null | tail -1 | tr -dc '0-9-')

for v in exp_fminpwm exp_ac_target exp_ac_limit exp_fan_target exp_vo0; do
    [[ ${!v} =~ ^-?[0-9]+$ ]] || fail "could not read $v from sysfs (got '${!v}')"
done

# ------------------------- 2. gate: self-checks ------------------
LOADED_BY_US=0
if [ -d "/sys/module/$MOD" ]; then
    # refresh the fingerprint parameters before re-checking, in case the existing
    # units changed the fan curve or voltage offsets since the module was loaded
    for k in exp_fminpwm exp_ac_target exp_ac_limit exp_fan_target exp_vo0; do
        echo "${!k}" > "$PARAMS/$k" || fail "could not update $PARAMS/$k"
    done
    log "$MOD already loaded - re-running the self-check gate"
    echo 1 > "$PARAMS/check" || fail "self-check gate failed on the loaded module (see dmesg)"
else
    OFFS=$("$HERE/gen-offsets.sh") || fail "gen-offsets.sh failed"
    log "offsets for $(uname -r):"
    while read -r kv; do log "  $kv"; done <<< "$OFFS"

    # The real targets are passed so the dry-run init logs what it would do.
    ARGS=(pci="$PCI" dry_run=1 sclk_max="$SCLK_MAX" ppt_offset="$PPT_OFFSET")
    while read -r kv; do ARGS+=("$kv"); done <<< "$OFFS"
    ARGS+=(exp_fminpwm="$exp_fminpwm" exp_ac_target="$exp_ac_target"
           exp_ac_limit="$exp_ac_limit" exp_fan_target="$exp_fan_target"
           exp_vo0="$exp_vo0")

    # DKMS install (updates/dkms/, possibly compressed) first, local build second
    if modinfo -n "$MOD" >/dev/null 2>&1; then
        log "loading $MOD from $(modinfo -n "$MOD") (dry_run=1) for the self-check gate"
        modprobe "$MOD" "${ARGS[@]}" || fail "modprobe failed - self-checks did not pass (see dmesg)"
    elif [ -f "$HERE/$MOD.ko" ]; then
        log "loading $HERE/$MOD.ko (dry_run=1) for the self-check gate"
        insmod "$HERE/$MOD.ko" "${ARGS[@]}" || fail "insmod failed - self-checks did not pass (see dmesg)"
    else
        fail "no $MOD module for $(uname -r) (run: dkms install, or make)"
    fi
    LOADED_BY_US=1
fi

if [ "$MODE" = dry-run ]; then
    if [ "$LOADED_BY_US" = 1 ]; then
        log "dry-run: self-checks passed, planned actions are in dmesg; unloading"
        rmmod "$MOD" || fail "rmmod failed"
    else
        log "dry-run: self-checks passed on the already loaded module (dry_run=$(cat "$PARAMS/dry_run")); nothing changed"
    fi
    exit 0
fi

# gate passed - switch the loaded module from check-only to acting
echo "$SCLK_MAX" > "$PARAMS/sclk_max" || fail "sclk_max=$SCLK_MAX rejected"
echo "$PPT_OFFSET" > "$PARAMS/ppt_offset" || fail "ppt_offset=$PPT_OFFSET rejected"
echo 0 > "$PARAMS/dry_run" || fail "could not clear dry_run"

# ------------------------- 3. Ppt: stage, then commit ------------
# ppt_current is the driver's staging buffer, which survives a GPU reset even
# though the reset re-uploads the OD table without the PPT bit. So besides a
# value mismatch, a changed gpu_reset_counter also triggers a (forced) commit.
current=$(cat "$PARAMS/ppt_current")
resets=$(cat "$PARAMS/reset_count")
last_reset="" last_ppt=""
# shellcheck disable=SC1090
[ -r "$STATE" ] && . "$STATE"

reason=""
if [ "$current" != "$PPT_OFFSET" ]; then
    reason="staging buffer has Ppt=$current"
elif [ "$PPT_OFFSET" != 0 ]; then
    if [ "$MODE" = apply ]; then
        reason="full apply"
    elif [ "$last_ppt" != "$PPT_OFFSET" ]; then
        reason="no commit of Ppt=$PPT_OFFSET recorded since boot"
    elif [ "$last_reset" != "$resets" ]; then
        reason="GPU reset since the last commit (counter $last_reset -> $resets)"
    fi
fi

COMMITTED=0
if [ -n "$reason" ]; then
    cap_before=$(cat "$HWMON/power1_cap")
    log "staging Ppt=$PPT_OFFSET ($reason)"
    echo 1 > "$PARAMS/ppt_force" || fail "could not set ppt_force"
    echo 1 > "$PARAMS/ppt_apply" || { echo 0 > "$PARAMS/ppt_force"; fail "staging Ppt failed (see dmesg)"; }
    echo 0 > "$PARAMS/ppt_force"
    log "committing the OD table"
    echo c > "$ODSYS" || fail "OD commit failed - SMU rejected the table? (see dmesg)"
    sleep 2
    dmesg | tail -20 | grep -qi "failed to upload overdrive" && fail "SMU rejected the OD table"
    printf 'last_reset=%s\nlast_ppt=%s\n' "$(cat "$PARAMS/reset_count")" "$PPT_OFFSET" > "$STATE"
    COMMITTED=1
else
    log "Ppt=$PPT_OFFSET already in effect - no commit"
fi

# ------------------------- 4. base state -------------------------
if [ "$MODE" = apply ]; then
    log "setting performance level to auto"
    echo auto > "$LEVEL" || fail "could not set performance level"
fi

# ------------------------- 5. soft max (after commit + auto) -----
if [ "$SCLK_MAX" != 0 ]; then
    log "applying SCLK soft max ${SCLK_MAX} MHz"
    echo 1 > "$PARAMS/sclk_apply" || fail "soft max apply failed (see dmesg)"
fi

# ------------------------- 6. power cap last ---------------------
# An OD commit re-initialises DPM, so the cap is re-sent after every commit:
# the configured value, or else the value amd-power-tune had set.
cap=""
if [ -n "$POWER1_CAP" ] && [ "$MODE" = apply ]; then
    cap=$POWER1_CAP
elif [ "$COMMITTED" = 1 ]; then
    cap=${POWER1_CAP:-$cap_before}
fi
if [ -n "$cap" ]; then
    cmin=$(cat "$HWMON/power1_cap_min") cmax=$(cat "$HWMON/power1_cap_max")
    { [ "$cap" -ge "$cmin" ] && [ "$cap" -le "$cmax" ]; } \
        || fail "power1_cap $cap outside [$cmin, $cmax] - use PPT_OFFSET to go below the floor"
    log "setting power1_cap to $cap uW"
    echo "$cap" > "$HWMON/power1_cap" || fail "could not set power1_cap"
fi

# ------------------------- 7. verify -----------------------------
log "verify:"
log "  pp_dpm_sclk: $(tr '\n' ' ' < "$DEV/pp_dpm_sclk" 2>/dev/null)"
log "  OD_VDDGFX_OFFSET: $(grep -A1 'OD_VDDGFX_OFFSET:' "$ODSYS" | tail -1)"
log "  power1_cap: $(cat "$HWMON/power1_cap" 2>/dev/null)"
log "  power1_average: $(cat "$HWMON/power1_average" 2>/dev/null)"
log "  ppt_current: $(cat "$PARAMS/ppt_current" 2>/dev/null) reset_count: $(cat "$PARAMS/reset_count" 2>/dev/null)"

exit 0
