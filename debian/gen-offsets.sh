#!/bin/bash
# gen-offsets.sh - derive every struct offset the module needs from the BTF of
# the *running* kernel and print them as KEY=VALUE module parameters.
#
# Nothing is hard-coded: pahole runs against /sys/kernel/btf/amdgpu with
# /sys/kernel/btf/vmlinux as the base, so the offsets always match the kernel
# that is actually loaded. If a field cannot be resolved the script exits 2 and
# the caller must not load the module.
#
# Two traps this script handles:
#
#  1. BTF name collisions. There are 7 typedefs named OverDriveTable_t in the
#     amdgpu BTF (legacy per-asic OD tables, 52/64/140 bytes) and `pahole -C`
#     prints the first one, which is NOT the SMU14 table. We scan the whole dump
#     and select the definition by its field signature. If more than one
#     definition matches, we fail rather than guess.
#  2. Anonymous typedefs are only emitted with `pahole -a`, so `pahole -C
#     OverDriveTable_t` cannot see them at all without it.
#
# usage: ./gen-offsets.sh                 (prints KEY=VALUE lines)
#        eval "$(./gen-offsets.sh)"        (fills the vars used by apply-debian.sh)

set -eu

BTF_MOD=${BTF_MOD:-/sys/kernel/btf/amdgpu}
BTF_VML=${BTF_VML:-/sys/kernel/btf/vmlinux}

command -v pahole >/dev/null || { echo "gen-offsets: pahole not installed" >&2; exit 2; }
[ -r "$BTF_MOD" ] || { echo "gen-offsets: $BTF_MOD not readable (kernel without BTF?)" >&2; exit 2; }
[ -r "$BTF_VML" ] || { echo "gen-offsets: $BTF_VML not readable" >&2; exit 2; }

DUMP=$(mktemp)
trap 'rm -f "$DUMP"' EXIT

# -a is required: the OD tables are anonymous typedefs.
pahole -a --btf_base "$BTF_VML" "$BTF_MOD" > "$DUMP" 2>/dev/null

# Print "start end" for every top-level definition of TYPE, in either pahole
# form. Only column-0 anchors are used so nested anonymous structs are ignored:
#   struct TYPE { ... };            -> ^struct TYPE { ... ^};
#   typedef struct { ... } TYPE;    -> ^typedef struct { ... ^} TYPE;
defs() {
    local type="$1"
    awk -v t="$type" '
        $0 ~ ("^struct " t " \\{") || $0 ~ /^typedef struct \{/ { s = NR; next }
        $0 == "};" { if (s) print s, NR; s = 0; next }
        $0 ~ /^} [A-Za-z_][A-Za-z0-9_]*;/ {
            if (s && $0 ~ ("^} " t ";")) print s, NR
            s = 0
            next
        }
    ' "$DUMP"
}

# offset of FIELD inside the definition spanning lines START..END.
# pahole prints "\ttype name;  /* offset size */", "\ttype name[N];  /* offset size */"
# and function pointers as "\ttype (*name)(...);  /* offset size */".
field_off() {
    local start="$1" end="$2" field="$3"
    awk -v f="$field" -v s="$start" -v e="$end" '
        NR >= s && NR <= e && $0 ~ ("(^|[[:space:]*(])" f "(;|\\[|\\))") {
            if (match($0, /\/\* *[0-9]+ *[0-9]+/)) {
                rest = substr($0, RSTART + 3, RLENGTH - 3)
                split(rest, a, " ")
                print a[1]
                exit
            }
        }
    ' "$DUMP"
}

size_of() {
    local start="$1" end="$2"
    awk -v s="$start" -v e="$end" 'NR >= s && NR <= e && /\/\* size: [0-9]+/ {
        match($0, /size: [0-9]+/); print substr($0, RSTART + 6, RLENGTH - 6); exit
    }' "$DUMP"
}

# among all definitions of TYPE, print "start end" of the one whose body contains
# every marker field (space separated). Empty if 0 match.
pick_def() {
    local type="$1" markers="$2"
    while read -r s e; do
        body=$(awk -v s="$s" -v e="$e" 'NR >= s && NR <= e' "$DUMP")
        ok=1
        for m in $markers; do
            grep -qE "(^|[[:space:]])${m}(;|\[)" <<< "$body" || { ok=0; break; }
        done
        if [ "$ok" = 1 ]; then echo "$s $e"; fi
    done < <(defs "$type")
}

# resolve KEY from TYPE/FIELD using a field signature that disambiguates the
# BTF name collision. Fails loudly on 0 or >1 matching definitions.
resolve() {
    local key="$1" type="$2" field="$3" signature="$4" matches n start end off
    matches=$(pick_def "$type" "$signature")
    n=$(printf '%s\n' "$matches" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        echo "gen-offsets: no definition of $type with fields [$signature]" >&2
        return 2
    fi
    if [ "$n" -gt 1 ]; then
        echo "gen-offsets: $type is ambiguous - $n definitions match [$signature]" >&2
        return 2
    fi
    read -r start end <<< "$matches"
    off=$(field_off "$start" "$end" "$field")
    [ -n "$off" ] || { echo "gen-offsets: field $field not found in $type" >&2; return 2; }
    printf '%s=%s\n' "$key" "$off"
}

# resolve KEY from a plainly named struct (no collision expected)
named() {
    local key="$1" type="$2" field="$3" start end off
    read -r start end <<< "$(defs "$type" | head -1)"
    [ -n "$start" ] || { echo "gen-offsets: $type not in BTF" >&2; return 2; }
    off=$(field_off "$start" "$end" "$field")
    [ -n "$off" ] || { echo "gen-offsets: field $field not found in $type" >&2; return 2; }
    printf '%s=%s\n' "$key" "$off"
}

# ---- amdgpu_device ----
named ofs_pdev      amdgpu_device pdev
named ofs_ddev      amdgpu_device ddev
named ofs_reset_counter amdgpu_device gpu_reset_counter

# powerplay.pp_handle and pm.mutex are nested members: the module dereferences
# from the start of amdgpu_device, so add the inner offsets.
read -r ad_s ad_e <<< "$(defs amdgpu_device | head -1)"
read -r pp_s pp_e <<< "$(defs amd_powerplay | head -1)"
read -r pm_s pm_e <<< "$(defs amdgpu_pm | head -1)"
[ -n "$pp_s" ] && [ -n "$pm_s" ] || { echo "gen-offsets: amd_powerplay/amdgpu_pm not in BTF" >&2; exit 2; }
printf 'ofs_pp_handle=%s\n' "$(( $(field_off "$ad_s" "$ad_e" powerplay) + $(field_off "$pp_s" "$pp_e" pp_handle) ))"
printf 'ofs_pm_mutex=%s\n'   "$(( $(field_off "$ad_s" "$ad_e" pm) + $(field_off "$pm_s" "$pm_e" mutex) ))"

# ---- smu_context ----
named ofs_smu_adev   smu_context adev
named ofs_ppt_funcs  smu_context ppt_funcs
named ofs_smu_table  smu_context smu_table
named ofs_od_enabled smu_context od_enabled
named ofs_pm_enabled smu_context pm_enabled

# ---- smu_table_context ----
named ofs_od_table      smu_table_context overdrive_table
named ofs_boot_od_table smu_table_context boot_overdrive_table
named ofs_user_od_table smu_table_context user_overdrive_table
named ofs_tables        smu_table_context tables

# ---- pptable_funcs ----
named ofs_set_soft_freq pptable_funcs set_soft_freq_limited_range

# ---- OverDriveTable_t: the SMU14 definition, picked by its signature ----
# These five markers are unique to the SMU14 table among the 7 definitions
# named OverDriveTable_t in the amdgpu BTF.
SIG="FeatureCtrlMask VoltageOffsetPerZoneBoundary AdvancedOdModeEnabled GfxclkFmaxVmaxTemperature IdlePwrSavingFeaturesCtrl"
resolve od_fcm        OverDriveTable_t FeatureCtrlMask              "$SIG"
resolve od_vo         OverDriveTable_t VoltageOffsetPerZoneBoundary "$SIG"
resolve od_ppt        OverDriveTable_t Ppt                         "$SIG"
resolve od_fminpwm    OverDriveTable_t FanMinimumPwm               "$SIG"
resolve od_ac_target  OverDriveTable_t AcousticTargetRpmThreshold  "$SIG"
resolve od_ac_limit   OverDriveTable_t AcousticLimitRpmThreshold   "$SIG"
resolve od_fan_target OverDriveTable_t FanTargetTemperature        "$SIG"

read -r od_s od_e <<< "$(pick_def OverDriveTable_t "$SIG")"
od_size=$(size_of "$od_s" "$od_e")
printf 'od_size=%s\n' "$od_size"

# the driver kzallocs OverDriveTableExternal_t; it must be the same size.
# Three definitions carry that name, so match by size against the SMU14 table.
ext_found=0
while read -r s e; do
    if [ "$(size_of "$s" "$e")" = "$od_size" ]; then
        ext_found=1
        break
    fi
done < <(defs OverDriveTableExternal_t)
if [ "$ext_found" != 1 ]; then
    echo "gen-offsets: no OverDriveTableExternal_t of size $od_size in BTF" >&2
    exit 2
fi

# ---- cross-check: tables[SMU_TABLE_OVERDRIVE].size must equal od_size ----
sti=$(pahole -E -C smu_table_id --btf_base "$BTF_VML" "$BTF_MOD" 2>/dev/null | grep 'SMU_TABLE_OVERDRIVE' | grep -oE '[0-9]+' | head -1)
[ -n "$sti" ] || { echo "gen-offsets: SMU_TABLE_OVERDRIVE index not in BTF" >&2; exit 2; }
printf 'idx_overdrive=%s\n' "$sti"
read -r st_s st_e <<< "$(defs smu_table | head -1)"
[ -n "$st_s" ] || { echo "gen-offsets: struct smu_table not in BTF" >&2; exit 2; }
printf 'sz_smutable=%s\n' "$(size_of "$st_s" "$st_e")"
printf 'ofs_table_size=%s\n' "$(field_off "$st_s" "$st_e" size)"

# ---- expected function address (needs root for a non-zero value) ----
# printed with 0x: ulong module parameters are parsed with base 0, so a bare
# kallsyms hex string would be rejected as an invalid decimal number.
addr=$(grep -w smu_v14_0_set_soft_freq_limited_range /proc/kallsyms 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$addr" ] || { echo "gen-offsets: smu_v14_0_set_soft_freq_limited_range not in /proc/kallsyms" >&2; exit 2; }
if [ "$addr" = "0000000000000000" ]; then
    echo "gen-offsets: /proc/kallsyms returns zeros - run as root (kptr_restrict)" >&2
    exit 2
fi
printf 'expect_sfr=0x%s\n' "$addr"
