# Port plan: r9700-tune → Debian 13 / kernel 7.2 / k3s node

Target: `plutos-kubernetes` (`k3s-plutos`, k3s node `k3s-node-100`),
Debian 13 "trixie", kernel `7.2.6+deb13-amd64` (trixie-backports), KVM guest on a
Proxmox host (i9-14900K), AMD Radeon AI PRO R9700 passed through at PCI
`0000:03:00.0` (`1002:7551`, ASUS `1043:0626`).

Goal: reproduce the Unraid "quiet" profile (SCLK cap well below 1850 MHz and a
power limit below the 210 W firmware floor, plus a relaxed fan curve) **without
risking the card or the node**. You already tried the native `-500 MHz` offset
and the card still hit 210 W and ran hot, so the below-floor features are in
scope.

Everything in this document that is stated as fact about the target was read
from the node on 2026-10-10 (read-only commands). Nothing was changed.

---

## 0. Summary / decisions

1. **Do not load the upstream module (`dist/r9700_tune.ko` or `module/r9700_tune.c`
   recompiled) on this node.** Three independent blockers, any one of which is a
   show-stopper (details in §3):
   - Kernel IBT is *enabled* in this guest. The module's indirect calls
     through kallsyms/kprobe-resolved pointers (`kallsyms_lookup_name`,
     `amdgpu_dpm_set_soft_freq_range`, `smu_v14_0_2_upload_overdrive_table`)
     cannot land on an `endbr64` → control-protection fault → kernel `BUG()`
     → with `kernel.panic_on_oops=1`/`panic=10` on this node, **the VM
     reboots** at `insmod`.
   - Two hard-coded struct offsets are wrong on 7.2.6 (`smu_table` 128→**88**,
     `overdrive_table` 2016→**1880**). The module would read a stray pointer,
     copy 156 bytes of unrelated memory and upload it to the SMU as an
     overdrive table. That is the one realistic "hurt the card" vector in this
     whole project.
   - The `pp_table` sysfs node does not exist on 7.2, so the module's
     `smu_context` capture trigger (`cat pp_table`) never fires.
2. **Most of the Unraid tune is already native on this kernel** and already
   running on the node via your `amd-power-tune` / `amd-fan-tune` services
   (`pp_od_clk_voltage` + `gpu_od/fan_ctrl`, enabled by
   `amdgpu.ppfeaturemask`). Only two things need a module:
   - SCLK soft max below 1850 MHz (`SetSoftMaxByFreq`).
   - Power limit below 210 W (OD table `Ppt` percentage, feature bit 3).
3. **Port = a redesigned, much smaller module ("v2")** that:
   - makes **no indirect calls into sealed functions** (IBT-safe by
     construction),
   - needs **no kprobes and no kallsyms**: finds `amdgpu_device` through the PCI
     device's drvdata (exported APIs only),
   - takes **all struct offsets from the running kernel's BTF** at apply time
     (`pahole` on `/sys/kernel/btf/amdgpu`) and **cross-checks** them with
     pointer/fingerprint assertions before touching anything,
   - **never uploads an OD table itself**: it only edits two fields in the
     driver's own OD staging buffer; the upload is done by the driver's
     official commit path (`echo c > pp_od_clk_voltage`),
   - defaults to `dry_run=1`.
4. **Staged bring-up with go/no-go gates**, each stage individually reversible
   without reboot, with the VM reboot from Proxmox as the hard fallback.
5. Persistence through DKMS + one additional systemd unit ordered after the two
   existing ones (OD commits and `echo auto` wipe the soft cap, so order
   matters).

Nothing in any phase touches the VBIOS or any persistent state on the card. A
power cycle always returns the card to stock.

---

## 1. Target system facts (verified)

| Item | Value on target |
|---|---|
| OS / kernel | Debian 13, `7.2.6+deb13-amd64` (bpo), gcc 14.2, `PREEMPT_DYNAMIC` |
| Virtualization | KVM guest (Q35/ICH9, OVMF). Host CPU i9-14900K |
| GPUs in the VM | `card0` Intel UHD 770 (`02:00.0`), **`card1` R9700 (`03:00.0`)**, `card2` NVIDIA RTX 3060 (`01:00.0`). `card0` is **not** the R9700 |
| R9700 hwmon | `hwmon0` (apply.sh hard-codes `hwmon4`) |
| amdgpu | loaded, `amdgpu.ppfeaturemask=0xffffffff` (from `/etc/default/grub.d/amdgpu-overdrive.cfg`), `runpm=-1`, card has never runtime-suspended |
| Firmware | SMC `0x00684f00`, VBIOS `115-G287BP00-100`, `firmware-amd-graphics 20260810-1~bpo13+1` |
| `pp_od_clk_voltage` | **present and functional**: `SCLK_OFFSET -500..+1000`, `MCLK 97..1500`, `VDDGFX_OFFSET -200..0`; current `vo=-65`, `s=0` |
| `gpu_od/fan_ctrl/` | `fan_curve` (5 pts, hotspot temp 25–100 °C, 12–100 %), `fan_target_temperature` (25–105, **now 100**), `acoustic_target_rpm_threshold` (500–6500, now 3000), `acoustic_limit_rpm_threshold` (500–6500, now 6500), `fan_minimum_pwm` (12–100, now 12), `fan_zero_rpm_enable` unsupported (reads empty) |
| `pp_table` sysfs | **absent** |
| Power | `power1_cap` 210 W, `power1_cap_min` **210 W**, default 300 W, max 330 W |
| Clocks | `pp_dpm_sclk`: S 41 / 0: 500 / 1: 2350 MHz; MCLK 96…1258 |
| Thermals | edge/junction/mem crit 110/110/108 °C, emergency 115/115/113 °C; `FW_CTF`, `THROTTLERS`, `FAN_CONTROL` enabled in `pp_features` |
| Existing tuning | `amd-power-tune.service` → `/usr/local/sbin/amd-power-tune 210 -65 0`; `amd-fan-tune.service` → curve `50:12 70:15 80:50 90:60 100:90`, everything else stock |
| Secure Boot / lockdown | disabled / `none` |
| Module signing | `CONFIG_MODULE_SIG=y`, **not** `_FORCE` (nvidia DKMS module already loads unsigned, taint `O`+`E`) |
| Kprobes / kallsyms | `KPROBES=y`, `KALLSYMS_ALL=y`, all amdgpu symbols visible in `/proc/kallsyms` |
| **IBT** | `CET detected: Indirect Branch Tracking enabled` (kernel IBT active) |
| **Oops policy** | `kernel.panic_on_oops=1`, `kernel.panic=10` → an oops reboots the VM |
| GPU reset | `reset_method: flr bus` |
| BTF | `/sys/kernel/btf/vmlinux` + `/sys/kernel/btf/amdgpu` present, `pahole 1.30` installed |
| Toolchain | `linux-headers-7.2.6+deb13-amd64`, `build-essential`, `gcc-14`, `dkms 3.4.3` installed |
| ROCm | 7.2.4 in `/opt/rocm-7.2.4`, `amd-smi` in `/usr/local/bin` |
| k3s | `k3s-node-100` is the **only schedulable node** (110 and 200 are `SchedulingDisabled`); `amd.com/gpu: 4` advertised by the AMD device plugin; no pod obviously requesting the GPU was running at the time (verify before each window) |
| Recent dmesg | one `sdma1` ring timeout + ring reset ~14 h into uptime ("device wedged, but no recovery needed"); two "Fan curve pwm setting(11) must be within [12, 100]" rejections |

### Verified struct offsets (kernel `7.2.6+deb13-amd64`, from BTF)

These are informational — the v2 design regenerates them at apply time and
never bakes them into the module.

| Symbol | Offset |
|---|---|
| `amdgpu_device.pdev` | 8 |
| `amdgpu_device.ddev` | 16 |
| `amdgpu_device.powerplay.pp_handle` | 92400 (+0) |
| `amdgpu_device.pm.mutex` | 92416 (+0) |
| `sizeof(struct amdgpu_device)` | 386648 |
| `smu_context.adev` | 0 |
| `smu_context.ppt_funcs` | 32 |
| `smu_context.smu_table` | **88** (upstream module: 128) |
| `smu_context.od_enabled` / `pm_enabled` | 2584 / 2704 |
| `sizeof(struct smu_context)` | 3376 |
| `smu_table_context.driver_pptable` | 160 |
| `smu_table_context.overdrive_table` | **1880** (upstream module: 2016) |
| `smu_table_context.boot_overdrive_table` / `user_overdrive_table` | 1888 / 1896 |
| `pptable_funcs.od_edit_dpm_table` | 64 |
| `pptable_funcs.set_soft_freq_limited_range` | 768 (signature `(smu, enum smu_clk_type, u32 min, u32 max, bool automatic)`) |
| `enum smu_clk_type`: `SMU_GFXCLK` / `SMU_SCLK` | 0 / 13 (both map to `PPCLK_GFXCLK`) |

`OverDriveTable_t` (SMU 14.0 driver interface) is **byte-identical between
v6.18 and v7.2**: `FeatureCtrlMask` 0, `VoltageOffsetPerZoneBoundary[6]` 4,
`GfxclkFoffset` 24, `Ppt` 36, `FanLinearPwmPoints[6]` 40,
`FanLinearTempPoints[6]` 46, `FanMinimumPwm` 52, `AcousticTargetRpmThreshold`
54, `AcousticLimitRpmThreshold` 56, `FanTargetTemperature` 58, `FanMode` 62,
size 156. Feature bits: `GFX_VF_CURVE` 0, `PPT` 3, `FAN_CURVE` 4, `GFXCLK` 8.
So the module's *intra-table* offsets are still right; only the two container
offsets above are wrong.

---

## 2. Gap analysis: Unraid tune → Debian 13 / 7.2

| Unraid `apply.sh` knob | Mechanism on Unraid | Native equivalent on this node | Status |
|---|---|---|---|
| `MHZ` (SCLK soft max, e.g. 2000) | module → `SetSoftMaxByFreq` | `s <offset>` in `pp_od_clk_voltage` (`-350` = 2000 MHz) — floor **1850 MHz** (`-500`) | native down to 1850; **below needs module** |
| `MHZ` = 1200 | same | — | **module (v2)** |
| `POWER_CAP=210` | `power1_cap` | `power1_cap` (already 210) | native |
| `PPT_OFFSET=-50` (150 W) | module → OD `Ppt` field, bit 3 | — (`power1_cap_min` = 210 W = board 300 W × (100−30) %) | **module (v2)** |
| `VDDGFX_OFFSET` | module → OD VF curve ("may be rejected") | `vo <mV>` (already −65, range to −200) | native, better than the module |
| `MCLK_MAX` | module ("attempt", per upstream) | `m 1 <MHz>` (`OD_MCLK`) | native; **not recommended** (GDDR6 stability risk, negligible gain) |
| `FAN_CURVE_PWM=15,20,28,38,50,65` @ 40–90 °C (6 pts) | module → OD fan table | `gpu_od/fan_ctrl/fan_curve` (5 pts, hotspot) | native |
| `FAN_TARGET_TEMP=85/90` | module | `gpu_od/fan_ctrl/fan_target_temperature` (now **100**) | native, currently stock |
| `FAN_ACOUSTIC_TARGET=1000–1200` | module | `gpu_od/fan_ctrl/acoustic_target_rpm_threshold` (now 3000) | native, currently stock |
| `FAN_ACOUSTIC_LIMIT=1300–1600` | module | `gpu_od/fan_ctrl/acoustic_limit_rpm_threshold` (now 6500) | native, currently stock |
| `FAN_MIN_PWM=10–15` | module | `gpu_od/fan_ctrl/fan_minimum_pwm` (floor **12**) | native; 10 % impossible |
| `cat pp_table` trigger | kprobe on `smu_sys_get_pp_table` | node absent on 7.2 | replaced by direct pointer discovery |
| `/sys/class/drm/card0`, `hwmon4` | hard-coded | `card1` / `hwmon0` here, and not stable | discover by vendor/device id (your scripts already do) |

Why the README said OD is "impossible" on the R9700: the Unraid kernel ran with
the default `ppfeaturemask` (`0xfff7bfff`, which clears the `PP_OVERDRIVE_MASK`
bit `0x4000`). On this node the bit is set, and the SMU's
`OverDriveLimitsBasicMin/Max.FeatureCtrlMask` are evidently non-zero (the
`OD_RANGE` values are real firmware limits). Same card, different kernel
parameter.

---

## 3. Why the upstream module must not be loaded here

1. **IBT (`CONFIG_X86_KERNEL_IBT`, active at runtime).** With IBT, every
   indirect `call`/`jmp` must land on an `endbr64`. The module makes three
   indirect calls, and none of them can land on one:
   - `lookup_symbol()` calls `kallsyms_lookup_name` through `kp.addr`. x86
     kprobes deliberately place `kp.addr` 4 bytes *past* an `endbr64`
     (`arch_adjust_kprobe_addr()`), and if the function was IBT-sealed there
     is no `endbr64` at all. Either way the call lands on a non-`endbr64`
     instruction. This is the first thing `r9700_tune_init` does.
   - `amdgpu_dpm_set_soft_freq_range` and
     `smu_v14_0_2_upload_overdrive_table` are only ever called directly, so
     objtool seals (removes) their `endbr64`; a call through the
     kallsyms-resolved address lands on the replacement NOP.
   Result: `Missing ENDBR` → `BUG()` (`ibt_fatal` defaults to true) → oops →
   `panic_on_oops=1` → **node reboot at `insmod`**, before any GPU
   interaction. (`register_kprobe()` itself is fine; it is the *call through*
   the pointer that faults.)
2. **Wrong container offsets** (`SMU_TABLE_OFS 128`, `OVERDRIVE_TABLE_OFS 2016`
   vs 88 / 1880 here). `apply_fan()` would dereference `smu + 2144` as the OD
   buffer pointer and upload whatever it finds. Even if the IBT problem were
   patched around, this must never run.
3. **No `pp_table` node** → `smu_ptr` is never captured → fan/PPT path would
   silently do nothing (harmless but useless).
4. Hard-coded `card0` / `hwmon4` → on this VM they point at the Intel iGPU and
   a non-existent hwmon.

Rejected alternative: booting with `ibt=off` (or `ibt=warn`) and keeping the
original calling style. It is a persistent kernel-security downgrade for the
whole node, it does not fix items 2–4, and it keeps the fragile
"resolve-and-call internal functions" pattern that breaks on every kernel
update. The v2 design below needs neither `ibt=` tweaks nor kprobes.

---

## 4. Safety model

What can and cannot go wrong, so the plan's precautions are proportionate.

**Cannot happen via any interface used here**
- Bricking: no VBIOS/EEPROM writes exist in this plan. The OD table, SMU
  messages, soft limits and `power1_cap` are volatile. Reboot = stock.
- Overvolting / overclocking: every value in scope *lowers* clock, voltage or
  power. `vo` range is −200…0 mV; the module writes only `Ppt` (negative) and
  a lower soft max.

**Can happen, and how it is contained**
- *Too-low fan curve → high temperature.* Contained by firmware: the SMU
  thermal controller still ramps the fan to hold `fan_target_temperature`
  (set it to 85–90 °C as a safety net instead of the current 100), throttles
  at ~110 °C junction and hard-shuts at 115 °C (`FW_CTF`). Lower power limits
  make this strictly less likely than today.
- *Undervolt instability.* Causes hangs/ring resets/garbage compute results,
  not hardware damage. **The existing −65 mV may already be marginal**: there
  was an `sdma1` ring timeout + reset ~14 h into this uptime. Phase 0 checks
  this before anything is stacked on top.
- *SMU rejecting an out-of-range OD value* (e.g. `Ppt=-50` when the declared
  minimum is −30). The driver logs `Failed to upload overdrive table` and
  returns an error; `echo r` + `echo c` restores the boot table. Upstream
  reports the SMU accepts it on 6.18; your SMC firmware may differ → staged.
- *GPU hang needing a full adapter reset.* amdgpu does mode-1/FLR resets in
  passthrough VMs; `reset_method` is `flr bus`. If the device stays wedged,
  the VM must be rebooted from Proxmox; in the rare worst case the Proxmox
  host must be rebooted to re-initialise the PCIe device. Not damage, but
  downtime.
- *Kernel oops from a module bug.* → node reboot (`panic_on_oops=1`). This is
  the largest operational risk and the reason for the IBT-safe, dry-run-first,
  BTF-verified design and the maintenance-window rules below.

**Operational blast radius**
- `k3s-node-100` is currently the only schedulable node. Any node reboot is a
  full-cluster outage of the workloads. etcd quorum is fine (3 control-plane
  members are all up). Do every module stage in a maintenance window, with the
  Proxmox UI/SSH open and the VMID at hand.

---

## 5. Phase 0 — Preparation and baseline (no changes to the card)

Exit criterion: you have a written baseline, a proven rollback path, and a
stable UV.

1. **Snapshot the current state** into the repo (e.g. `docs/baseline/<date>/`)
   with a read-only script:
   `pp_od_clk_voltage`, every `gpu_od/fan_ctrl/*`, `pp_dpm_sclk|mclk|fclk`,
   `pp_features`, `pp_power_profile_mode`, all of `hwmon0/*`, `fw_version/*`,
   `/proc/cmdline`, `systemctl cat amd-*-tune.service`,
   `/etc/default/amd-fan-tune`, `uname -a`, `dmesg | grep amdgpu`.
2. **Decide the SDMA-timeout question.** Look at
   `journalctl -k -b 0 | grep -B5 -A20 "ring sdma1 timeout"` and correlate with
   what ran at that time (`journalctl --since … --until …` for k3s/containerd).
   If no workload explanation exists, run 24 h at `vo 0`
   (`amd-power-tune 210 0 0`) and see whether it recurs. Do not stack a soft
   cap and a PPT offset on an undervolt you have not confirmed stable — a
   capped card will spend more time at mid-curve points, which are where
   marginal offsets usually fail.
3. **Fix the fan safety net first** (native, reversible, independent of
   everything else): set `TARGET_TEMPERATURE=85` (or 90) in
   `/etc/default/amd-fan-tune` and restart `amd-fan-tune.service`. This is the
   SMU's thermal setpoint; today it is 100 °C, which is why "quiet curve" and
   "very hot" happen together.
4. **Verify the native `-500` actually applied** the last time (sanity check
   of your observation): after `amd-power-tune 210 -65 -500`,
   `pp_dpm_sclk` must show level 1 at **1850 MHz**, and under load
   `hwmon0/freq1_input` must stay ≤ 1.85 GHz. If it still showed 2350 MHz the
   commit was rejected (see `dmesg`), and the conclusion "still 210 W at 1850
   MHz" needs re-measuring. Either way the below-floor work remains useful.
5. **Prove the rollback path** (on the current native setup):
   - `echo r > pp_od_clk_voltage; echo c > pp_od_clk_voltage` → `OD_*`
     back to stock; `echo auto > power_dpm_force_performance_level`;
     `echo 300000000 > hwmon0/power1_cap` → stock.
   - Restart `amd-power-tune.service` + `amd-fan-tune.service` → tuned again.
   - Know the VMID; verify you can `qm reset <vmid>` from the Proxmox host (or
     the web UI) and that the VM and the GPU come back (this is the hard
     fallback for everything in Phase 2).
6. **Maintenance-window checklist** (used by every Phase 2 stage):
   - `kubectl cordon k3s-node-100`; confirm nothing is holding the GPU:
     `kubectl get pods -A -o json | jq '.items[] | select(.spec.containers[].resources.limits["amd.com/gpu"]?) | .metadata.name'`
     and `sudo fuser -v /dev/kfd /dev/dri/renderD129` on the node.
   - Proxmox console open; `journalctl -kf` open in a second terminal.
   - Monitoring loop in a third terminal (one line per second: junction temp,
     fan RPM, `power1_average`, `freq1_input`, `gpu_busy_percent`).
   - Enable throttle logging for the window:
     `echo "1 60" > /sys/bus/pci/devices/0000:03:00.0/thermal_throttling_logging`.
7. **Load generator** for measurements: your real inference workload (a pod
   pinned to this node), or a one-off `rocm/pytorch` matmul loop job. Keep it
   the same across stages so numbers are comparable.
8. Optional hardening of the existing setup (not required): change the grub
   drop-in from `0xffffffff` to `0xfff7ffff` (= default + overdrive bit) so
   nothing else is force-enabled; takes effect on the next reboot only, so fold
   it into a planned reboot.

---

## 6. Phase 1 — Native settings (official sysfs, no module)

Even though the floors are not low enough for you, this layer is the
foundation: it is what the module layer sits on, and the final apply order
depends on it. All of it goes through your existing scripts/config.

Mapping of the Unraid "quiet" profile:

| Unraid env | New config | Note |
|---|---|---|
| `bash apply.sh 2000` / `1200` | `amd-power-tune 210 -65 -500` | native floor; the module (Phase 2) lowers further |
| `PPT_OFFSET=-50` | — | Phase 2 |
| `FAN_TARGET_TEMP=90` | `TARGET_TEMPERATURE=85` | 85 recommended over 90 as the safety net |
| `FAN_ACOUSTIC_TARGET=1000` | `ACOUSTIC_TARGET_RPM=1000` | range 500–6500 |
| `FAN_ACOUSTIC_LIMIT=1300` | `ACOUSTIC_LIMIT_RPM=1600` | start generous (1600), lower later; thermal protection overrides it anyway |
| `FAN_MIN_PWM=10` | `MINIMUM_PWM=12` | floor is 12 (11 was rejected in dmesg) |
| `FAN_CURVE_PWM=10,13,16,22,30,42` (40–90 °C) | `FAN_CURVE="40:12 55:16 70:25 80:40 90:60"` | 5 hotspot points; same OD table, same semantics |
| `POWER_CAP=210` | first arg of `amd-power-tune` | unchanged |

Procedure: change **one** group at a time (fan safety net → acoustic → curve →
`-500`), restart the corresponding unit, run the load generator 10–15 min,
record temp/fan/power/clock. Watch for the `OD_UNSUPPORTED_FEATURE` trap your
script already documents (a rejected fan-ctrl reset stages a bad table and
every later commit fails until reboot) — this is why unsupported files like
`fan_zero_rpm_enable` must stay untouched.

Expected result: still ~210 W under sustained compute (that is the floor), but
quieter/cooler behaviour governed by the SMU setpoint rather than by a 100 °C
target. This is the "before" measurement for Phase 2.

---

## 7. Phase 2 — Module v2 (below the firmware floors)

### 7.1 Design (what changes vs. `module/r9700_tune.c`)

| Aspect | Upstream module | v2 for this node | Why |
|---|---|---|---|
| Finding `amdgpu_device` | kprobe on `amdgpu_dpm_force_performance_level`, triggered by `echo auto` | `pci_get_domain_bus_and_slot(0, 0x03, 0)` → `pci_get_drvdata()` (= `&adev->ddev`) → `adev = ddev − offsetof(amdgpu_device, ddev)` | exported APIs only, deterministic, no trigger needed |
| Finding `smu_context` | kprobe on `smu_sys_get_pp_table`, triggered by `cat pp_table` (node absent here) | `smu = *(void **)(adev + ofs_pp_handle)` | same |
| Resolving functions | `kallsyms_lookup_name` via kprobe `kp.addr` + indirect call | **none** | the indirect call is the IBT fault |
| SCLK soft max | indirect call to `amdgpu_dpm_set_soft_freq_range` (sealed) | `mutex_lock(adev->pm.mutex)`; `smu->ppt_funcs->set_soft_freq_limited_range(smu, SMU_GFXCLK, 0, max, false)`; unlock | target is address-taken (lives in the `smu_v14_0_2_ppt_funcs` table) → keeps its `endbr64` → legal indirect call. Same message (`SetSoftMaxByFreq`) upstream proved works |
| Power below 210 W | module builds a 156-byte OD table and calls `smu_v14_0_2_upload_overdrive_table` (sealed) | module writes `Ppt` (s16 @36) and sets bit 3 in `FeatureCtrlMask` (@0) **inside the driver's staging buffer** `smu->smu_table.overdrive_table`; **userspace commits** with `echo c > pp_od_clk_voltage` | the upload runs in the driver's own `PP_OD_COMMIT_DPM_TABLE` path under `pm.mutex`, with its error handling and bookkeeping; the module never calls into the driver |
| Fan / acoustic / VF curve / MCLK | in module | **removed** — native `gpu_od` / `vo` / `m` | less code, less risk |
| Struct offsets | compiled-in constants from one kernel tree | **module parameters** supplied by the apply script, generated at run time from `/sys/kernel/btf/amdgpu` with `pahole` | always matches the running kernel; survives kernel updates without code changes |
| Verification | none | mandatory self-checks before any write/call (below); `dry_run=1` default | a wrong offset must become "refuse", never "act" |
| Build | manual `make` against one tree | DKMS (`r9700-tune-v2/<ver>`), unsigned (SB off) | rebuilt on every kernel update; load fails safe (stock) if anything is off |

Self-checks the module performs (fail → `-EINVAL`, nothing done):

1. PCI device `0000:03:00.0` exists, vendor `0x1002`, device `0x7551`, bound to
   `amdgpu`.
2. `*(void **)(adev + ofs_pdev) == pdev` (confirms `ddev`/`pdev` offsets).
3. `*(void **)(smu + ofs_smu_adev) == adev` (confirms `pp_handle` offset).
4. `*(bool *)(smu + ofs_pm_enabled)` and `od_enabled` are true.
5. `ppt_funcs` non-NULL; the function pointer at
   `ppt_funcs + ofs_set_soft_freq` equals the address of
   `smu_v14_0_set_soft_freq_limited_range` that the apply script read from
   `/proc/kallsyms` and passed in (`expect_sfr=0x…`). This is a value
   comparison, not a call.
6. OD staging buffer fingerprint: `overdrive_table`, `boot_overdrive_table`
   and `user_overdrive_table` pointers non-NULL and distinct; in the staging
   buffer `FanMinimumPwm`@52, `AcousticTargetRpmThreshold`@54,
   `AcousticLimitRpmThreshold`@56, `FanTargetTemperature`@58 equal the values
   currently shown by `gpu_od/fan_ctrl/*` (passed in by the apply script), and
   `VoltageOffsetPerZoneBoundary[0..5]`@4 equal the current `OD_VDDGFX_OFFSET`.
   Six independent fields matching the sysfs view leaves no realistic way to
   be pointed at the wrong memory.
7. Parameter ranges: `sclk_max` 0 or 800…2350; `ppt_offset` 0 or −60…0
   (never positive).

Module parameters: `dry_run` (default **1**), `sclk_max`, `ppt_offset`,
`apply` (write 1 to re-run both actions), the `ofs_*`/`expect_*` values, and
`pci=0000:03:00.0`. `rmmod` does nothing to the card (same as upstream); reset
is `echo auto > power_dpm_force_performance_level` (soft max) and
`echo r; echo c > pp_od_clk_voltage` + re-run the native units (PPT).

Open empirical question the staging resolves: whether the SMU applies `Ppt%`
to the **board** limit (300 W; upstream's reading, `-50` → 150 W) or to the
**current** `SetPptLimit` value (210 W; `-50` → 105 W). Stage C below is
designed so the first data point (`-35`) distinguishes the two before any
aggressive value is used.

### 7.2 Repository layout for the port

```
debian/
  r9700_tune_v2.c        # module described above (~250 lines)
  dkms.conf
  gen-offsets.sh         # pahole -> ofs_* parameters for the running kernel
  apply-debian.sh        # discovery, self-check inputs, ordered apply (see 7.4)
  amd-sclk-cap.service   # systemd unit, ordered after the two existing units
  amd-sclk-cap-check.service  # drift-check oneshot started by the timer
  amd-sclk-cap.timer     # optional drift check (see 7.5)
  dropins/r9700-sclk-cap.conf # Wants= drop-in for the two existing units
  r9700-tune.default     # -> /etc/default/r9700-tune (per-stage values)
  install.sh             # DKMS + scripts + units; --enable after Stage D
  Makefile
docs/
  PORT-PLAN-debian13-k8s.md   # this file
  baseline/<date>/            # Phase 0 snapshot
```

The upstream `module/` and `dist/` stay untouched (they are correct for
Unraid 6.18.44).

### 7.3 Bring-up stages (each in a maintenance window, each with a gate)

**Stage A — build and dry run (zero GPU interaction).**
- `gen-offsets.sh` prints the offsets; compare against the table in §1 (they
  must match exactly on `7.2.6+deb13-amd64`).
- Build via DKMS; `modinfo` shows vermagic `7.2.6+deb13-amd64 SMP preempt mod_unload`.
- `insmod … dry_run=1 sclk_max=1800 ppt_offset=-35 <ofs_*> <expect_*>`.
  Gate: `dmesg` shows every self-check passing and the exact actions it
  *would* take; `lsmod` shows the module; `rmmod` is clean; the card is
  unchanged. Any failed check → fix before proceeding, never bypass.
- Note: a mistake in the pointer arithmetic here is a *read* of kernel memory
  inside two known allocations, not a write and not a call; with the
  `pdev`/`adev` cross-checks the worst realistic outcome is "check failed".

**Stage B — SCLK soft max only (`ppt_offset=0`).**
- B1: `sclk_max=1800` (inside the native range, so the behaviour is known):
  gate = `pp_dpm_sclk`/`freq1_input` cap at ~1.8 GHz under load, idle still
  drops to 500 MHz, no dmesg errors.
- B2: `sclk_max=1500`, then B3: `sclk_max=1200`. Same gate; also record
  `power1_average` and junction temperature at each step — this already tells
  you whether a clock cap alone reaches your thermal target.
- Rollback at any point: `echo auto > power_dpm_force_performance_level`
  (instant), or reboot.

**Stage C — PPT offset (the out-of-range OD field), with `power1_cap` first
raised to the stock 300 W so the arithmetic is unambiguous.**
- C1: `ppt_offset=-35` → module stages it → `echo c > pp_od_clk_voltage`.
  Gate: commit accepted (no `Failed to upload overdrive table` in dmesg);
  under load `power1_average` ≈ 195 W. (If the commit is rejected: your SMC
  firmware does not accept below-floor `Ppt`; stop here, soft max alone is the
  tune.)
- C2: set `power1_cap` back to 210 W, re-measure: ≈195 W means `Ppt` is
  board-relative (min(210, 195)); ≈136 W means it is cap-relative. Write the
  result down; it decides the final numbers.
- C3: step −40 → −45 → −50 (board-relative targets 180/165/150 W, or
  equivalent cap-relative values), 10–15 min load each, watching for
  instability (page faults, ring timeouts) and for the SMU clamping silently
  (power not falling further = clamped; stop there).
- After every OD commit the SMU re-initialises DPM: **re-apply the soft max
  and `power1_cap` after each commit** (upstream's finding; the apply script
  encodes this order).
- Rollback: `echo r > pp_od_clk_voltage; echo c > pp_od_clk_voltage`
  (boot OD table), then restart `amd-power-tune`/`amd-fan-tune`, then
  `echo auto` for the soft max.

**Stage D — combined profile and soak.**
- Final values (e.g. `sclk_max=1200–1500`, `ppt_offset=-45…-50`, fan curve
  from Phase 1), 1–2 h of your real workload, then 24 h normal operation
  uncordoned with throttle logging on. Gate: zero `amdgpu` errors, junction
  comfortably below 95 °C, no compute anomalies.

### 7.4 Final apply order (encoded in `apply-debian.sh` / the unit)

1. `amd-fan-tune` (gpu_od commits) and `amd-power-tune` (`vo`, `s`, `c`,
   `power1_cap`, `echo auto`) — the existing units, unchanged.
2. `gen-offsets.sh` → load/refresh `r9700_tune_v2` with `dry_run=0`.
3. `ppt_offset` staged by the module → `echo c > pp_od_clk_voltage`.
4. `echo auto > power_dpm_force_performance_level` (harmless now, defines the
   base state).
5. Soft max via the module (`echo 1 > …/parameters/apply` or `sclk_max`
   write) — **after** every OD commit and every `echo auto`.
6. `power1_cap` last.
7. Verify and log: `pp_dpm_sclk`, `OD_*`, `power1_cap`, `power1_average`.

Anything that later writes `power_dpm_force_performance_level` or commits an
OD table (a restart of either existing unit, a GPU reset, a suspend/resume)
silently drops the soft max and the `Ppt` bit. Hence §7.5.

### 7.5 Persistence and drift control

- `amd-sclk-cap.service`: `Type=oneshot`, `RemainAfterExit=yes`,
  `After=amd-power-tune.service amd-fan-tune.service`,
  `PartOf=amd-power-tune.service amd-fan-tune.service` (so a restart of either
  re-runs it, in order), plus a drop-in `Wants=amd-sclk-cap.service` on the
  two existing units. `ConditionPathExists=/sys/module/amdgpu`.
  Fails safe: if DKMS has no module for the running kernel, or any self-check
  fails, the unit exits 0 with a log line and the card runs the Phase 1
  native profile.
- `amd-sclk-cap.timer` (optional, recommended): every 5 min run a check-only
  mode that compares `pp_dpm_sclk` max level and the `Ppt` state against the
  config and re-applies if drifted (covers GPU resets like the SDMA event, and
  runtime-PM resume should it ever start suspending — today
  `runtime_suspended_time` is 0).
- DKMS rebuilds on kernel updates. Because offsets are parameters, no source
  change is needed unless the field *names* change; `gen-offsets.sh` fails
  loudly (and the unit skips) if `pahole` cannot find a field.
- Keep `power/control` at `auto` unless the timer ever reports resume-related
  drift; then switch it to `on`.

---

## 8. Phase 3 — Operations

- Monitoring: a Prometheus/alert rule (or a cron) on `temp2_input` (junction)
  > 95 °C sustained and on `dmesg` `amdgpu` errors; the device plugin already
  exports basic metrics if you run it with monitoring enabled.
- k8s: nothing changes for pods; the AMD device plugin keeps advertising
  `amd.com/gpu`. Document in the cluster runbook that the GPU is power-limited
  and how to lift it (`systemctl stop amd-sclk-cap` + `echo auto`).
- Kernel updates (trixie-backports moves fast — the node has five kernels
  installed): after each reboot check `systemctl status amd-sclk-cap` and
  `journalctl -u amd-sclk-cap`. If it skipped, the GPU is at the native
  profile until DKMS/offsets are confirmed — acceptable by design.
- Keep the Phase 0 baseline and a per-stage measurement log in
  `docs/baseline/`.

---

## 9. Emergency procedures (fastest first)

| Symptom | Action |
|---|---|
| Too hot / fan too slow | `echo r > gpu_od/fan_ctrl/fan_curve; echo c > gpu_od/fan_ctrl/fan_curve` (stock fan), or `systemctl restart amd-fan-tune` with a stronger curve |
| Clocks pinned / wrong | `echo auto > power_dpm_force_performance_level` |
| Power/OD state suspicious | `echo r > pp_od_clk_voltage; echo c > pp_od_clk_voltage; echo 300000000 > hwmon*/power1_cap` |
| Commit errors / `OD_UNSUPPORTED_FEATURE` | only a reboot clears it (your script already notes this); card is safe meanwhile |
| GPU hang (ring timeouts, `device wedged`) | let amdgpu reset; if it stays wedged: `qm reset <vmid>` from Proxmox; last resort: host reboot |
| Kernel oops | the node reboots itself (`panic_on_oops=1`); module is not loaded at boot in dry-run/skip mode, so the node comes back on the native profile |
| Want everything stock | `systemctl disable --now amd-sclk-cap amd-power-tune amd-fan-tune`, remove the grub drop-in, reboot |

---

## 10. Known unknowns

- Whether your SMC firmware (`0x00684f00`) accepts `Ppt` below the declared −30 %
  (upstream saw it work on the Unraid firmware). Stage C1 answers it safely.
- Board-relative vs cap-relative `Ppt` semantics (Stage C2).
- Whether the −65 mV undervolt is implicated in the SDMA timeout (Phase 0.2).
- Whether 1850 MHz really drew 210 W or the offset had not applied (Phase 0.4).
- Real-world noise at the chosen acoustic limit — the fan range here is
  0–6500 RPM; 1013 RPM at idle today.

---

## Appendix A — Commands used for the survey (all read-only)

```bash
# identity / kernel / security
uname -a; cat /etc/os-release; cat /proc/cmdline; mokutil --sb-state
cat /sys/kernel/security/lockdown; grep -E 'KPROBES|KALLSYMS|MODULE_SIG|IBT|BTF|LOCKDOWN' /boot/config-$(uname -r)
journalctl -k -b 0 | grep -i 'Indirect Branch'; cat /proc/sys/kernel/panic_on_oops

# GPU
lspci -nnk | grep -A3 VGA; ls -la /sys/class/drm
G=/sys/bus/pci/devices/0000:03:00.0
cat $G/pp_od_clk_voltage; for f in $G/gpu_od/fan_ctrl/*; do echo "== $f"; cat $f; done
cat $G/pp_dpm_sclk $G/pp_dpm_mclk $G/pp_features $G/power_dpm_force_performance_level
for f in $G/hwmon/hwmon*/*; do printf '%s %s\n' "$f" "$(cat $f 2>/dev/null)"; done
for f in $G/fw_version/*; do printf '%s %s\n' "$(basename $f)" "$(cat $f)"; done
cat $G/reset_method $G/power/control $G/power/runtime_status $G/power/runtime_suspended_time

# existing tuning
systemctl cat amd-power-tune amd-fan-tune; cat /etc/default/amd-fan-tune /etc/default/grub.d/amdgpu-overdrive.cfg
cat /usr/local/sbin/amd-power-tune /usr/local/sbin/amd-fan-tune

# symbols and offsets
grep -wE 'amdgpu_dpm_set_soft_freq_range|smu_v14_0_2_upload_overdrive_table|smu_v14_0_set_soft_freq_limited_range' /proc/kallsyms
B="--btf_base /sys/kernel/btf/vmlinux /sys/kernel/btf/amdgpu"
pahole $B -C smu_context | grep -E 'ppt_funcs|smu_table;|od_enabled|pm_enabled'
pahole $B -C smu_table_context | grep -E 'overdrive_table|driver_pptable'
pahole $B -C pptable_funcs | grep -E 'set_soft_freq_limited_range|od_edit_dpm_table'
pahole $B -C amdgpu_device | grep -E 'ddev;|pdev;|powerplay;|struct amdgpu_pm'
pahole $B -E -C smu_clk_type | grep -E 'SMU_GFXCLK|SMU_SCLK'

# k8s
k3s kubectl get nodes -o wide; k3s kubectl get pods -A -o wide | grep k3s-node-100
```

## Appendix B — Upstream kernel sources consulted (tag v7.2)

- `drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu14_driver_if_v14_0.h`
  (`OverDriveTable_t`, `PP_OD_FEATURE_*_BIT`) — identical to v6.18.
- `drivers/gpu/drm/amd/pm/swsmu/smu14/smu_v14_0_2_ppt.c`
  (`PP_OD_COMMIT_DPM_TABLE` path, `od_enabled` gate, power-limit floor from
  `OverDriveLimitsBasicMin.Ppt`, `.set_soft_freq_limited_range =
  smu_v14_0_set_soft_freq_limited_range`).
- `drivers/gpu/drm/amd/pm/swsmu/smu14/smu_v14_0.c`
  (`smu_v14_0_set_soft_freq_limited_range`: `SetSoftMaxByFreq` with
  `max+1`, `SetSoftMinByFreq` only when `min > 0`).
- `drivers/gpu/drm/amd/pm/amdgpu_dpm.c` (`amdgpu_dpm_set_soft_freq_range`
  now takes `adev->pm.mutex` via `guard(mutex)`).
