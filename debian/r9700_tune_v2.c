// SPDX-License-Identifier: GPL-2.0
/*
 * r9700_tune_v2.c - IBT-safe, BTF-verified SCLK soft-max cap and
 * below-firmware-floor PPT offset for the AMD Radeon AI PRO R9700
 * (Navi 48, SMU 14.0.2) on Debian 13 / kernel 7.2.6+deb13-amd64.
 *
 * Design rules (see docs/PORT-PLAN-debian13-k8s.md §7.1):
 *
 *  1. No indirect calls into sealed functions. No kprobes, no kallsyms
 *     symbol resolution. The only indirect call is through
 *     smu->ppt_funcs->set_soft_freq_limited_range, which is address-taken
 *     (it lives in the static const smu_v14_0_2_ppt_funcs table), so it
 *     keeps its endbr64 and is legal under CONFIG_X86_KERNEL_IBT. The
 *     pointer is compared against expect_sfr immediately before the call.
 *  2. amdgpu_device is found through the PCI device's drvdata
 *     (pci_set_drvdata(pdev, ddev) in amdgpu_pci_probe), using exported
 *     APIs only. No capture probes, no trigger writes.
 *  3. Every struct offset is a module parameter supplied by
 *     gen-offsets.sh from the running kernel's BTF. Nothing is baked in.
 *  4. The module never uploads an overdrive table. It edits fields in
 *     the driver's own buffers; the upload happens through the driver's
 *     official commit path (echo c > pp_od_clk_voltage).
 *  5. Every check must pass before anything is touched. A failed check
 *     means "refuse", never "act": all actions require the last full
 *     check run to have passed. dry_run defaults to 1.
 *
 * What it does:
 *   - SCLK soft max below the native -500 MHz floor (SMU_MSG_SetSoftMaxByFreq)
 *   - PPT percentage offset below the 210 W firmware floor (OD Ppt field,
 *     feature bit 3), staged only - committed by userspace
 *
 * Fan curve / acoustic / VF curve / MCLK are deliberately NOT handled here:
 * they are native on this kernel via gpu_od/fan_ctrl and pp_od_clk_voltage.
 *
 * Reset: echo auto > power_dpm_force_performance_level (soft max);
 *        ppt_offset=0 + ppt_apply=1 + echo c > pp_od_clk_voltage (PPT).
 * Nothing here persists; a power cycle returns the card to stock.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/mutex.h>
#include <linux/pm_runtime.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>

/* SMU14 driver interface (smu14_driver_if_v14_0.h), byte-identical 6.18 -> 7.2 */
#define OD_BIT_PPT		3
#define SMU_CLK_GFXCLK		0

/* ------------------------- configuration ------------------------- */

static char *pci = "0000:03:00.0";
static unsigned int sclk_max;		/* MHz, 0 = no change */
static int ppt_offset;		/* percent, -60..0 (0 = stock Ppt) */
static bool ppt_force;		/* make the next commit upload even if unchanged */
static bool dry_run = true;

/* offsets generated at run time by gen-offsets.sh */
static unsigned long ofs_pdev;		/* offsetof(amdgpu_device, pdev)            */
static unsigned long ofs_ddev;		/* offsetof(amdgpu_device, ddev)            */
static unsigned long ofs_pp_handle;	/* offsetof(amdgpu_device, powerplay.pp_handle) */
static unsigned long ofs_pm_mutex;	/* offsetof(amdgpu_device, pm.mutex)          */
static unsigned long ofs_reset_counter;	/* offsetof(amdgpu_device, gpu_reset_counter) */
static unsigned long ofs_smu_adev;	/* offsetof(smu_context, adev)                */
static unsigned long ofs_ppt_funcs;	/* offsetof(smu_context, ppt_funcs)           */
static unsigned long ofs_od_enabled;	/* offsetof(smu_context, od_enabled)          */
static unsigned long ofs_pm_enabled;	/* offsetof(smu_context, pm_enabled)          */
static unsigned long ofs_smu_table;	/* offsetof(smu_context, smu_table)           */
static unsigned long ofs_od_table;	/* offsetof(smu_table_context, overdrive_table) */
static unsigned long ofs_boot_od_table;	/* offsetof(smu_table_context, boot_overdrive_table) */
static unsigned long ofs_user_od_table;	/* offsetof(smu_table_context, user_overdrive_table) */
static unsigned long ofs_set_soft_freq;	/* offsetof(pptable_funcs, set_soft_freq_limited_range) */
static unsigned long od_size;		/* sizeof(OverDriveTableExternal_t)           */

/* intra-table offsets, also generated (the SMU14 OverDriveTable_t definition) */
static unsigned long od_fcm;		/* FeatureCtrlMask                  */
static unsigned long od_vo;		/* VoltageOffsetPerZoneBoundary[0]  */
static unsigned long od_ppt;		/* Ppt                              */
static unsigned long od_fminpwm;	/* FanMinimumPwm                    */
static unsigned long od_ac_target;	/* AcousticTargetRpmThreshold       */
static unsigned long od_ac_limit;	/* AcousticLimitRpmThreshold        */
static unsigned long od_fan_target;	/* FanTargetTemperature             */

/* optional: smu_table.tables[SMU_TABLE_OVERDRIVE].size cross-check */
static unsigned long ofs_tables;	/* offsetof(smu_table_context, tables) */
static unsigned long idx_overdrive;	/* enum smu_table_id OVERDRIVE index  */
static unsigned long sz_smutable;	/* sizeof(struct smu_table)           */
static unsigned long ofs_table_size;	/* offsetof(struct smu_table, size)   */

/* expected value of ppt_funcs->set_soft_freq_limited_range, read from kallsyms */
static unsigned long expect_sfr;

/* fingerprint values as currently shown by sysfs (passed in by the apply script) */
static int exp_fminpwm, exp_ac_target, exp_ac_limit, exp_fan_target, exp_vo0;

/* --------------------------- state ------------------------------- */

static struct pci_dev *pdev;
static u8 *adev;
static u8 *smu;
static u8 *od;
static u8 *od_user;
static bool verified;		/* last full run_checks() passed */

typedef int (*set_soft_freq_fn)(void *smu, int clk_type, u32 min, u32 max, bool automatic);

static u64 rd64(u8 *base, unsigned long off)
{
	return get_unaligned_le64(base + off);
}

static u32 rd32(u8 *base, unsigned long off)
{
	return get_unaligned_le32(base + off);
}

static u8 rd8(u8 *base, unsigned long off)
{
	return base[off];
}

static u16 rd16(u8 *base, unsigned long off)
{
	return get_unaligned_le16(base + off);
}

/* ppt_funcs->set_soft_freq_limited_range, read through the ppt_funcs table */
static u64 rd_sfr(void)
{
	u8 *funcs = (u8 *)(uintptr_t)rd64(smu, ofs_ppt_funcs);

	return funcs ? rd64(funcs, ofs_set_soft_freq) : 0;
}

/* ------------------------- self-checks --------------------------- */

static int check_pci(void)
{
	unsigned int domain, bus, slot, func;

	if (pdev)
		return 0;	/* already resolved, do not take another reference */

	if (sscanf(pci, "%x:%x:%x.%x", &domain, &bus, &slot, &func) != 4) {
		pr_err("r9700_tune_v2: bad pci='%s' (want domain:bus:slot.func)\n", pci);
		return -EINVAL;
	}

	pdev = pci_get_domain_bus_and_slot(domain, bus, PCI_DEVFN(slot, func));
	if (!pdev) {
		pr_err("r9700_tune_v2: no PCI device at %s\n", pci);
		return -ENODEV;
	}
	if (pdev->vendor != 0x1002 || pdev->device != 0x7551) {
		pr_err("r9700_tune_v2: %s is %04x:%04x, expected 1002:7551 (R9700)\n",
		       pci, pdev->vendor, pdev->device);
		pci_dev_put(pdev);
		pdev = NULL;
		return -ENODEV;
	}
	if (!pdev->driver || strcmp(pdev->driver->name, "amdgpu") != 0) {
		pr_err("r9700_tune_v2: %s is not bound to amdgpu\n", pci);
		pci_dev_put(pdev);
		pdev = NULL;
		return -ENODEV;
	}

	pr_info("r9700_tune_v2: check 1 ok - %s is 1002:7551, bound to amdgpu\n", pci);
	return 0;
}

static int check_pointers(void)
{
	void *ddev;

	/* pci_set_drvdata(pdev, ddev) in amdgpu_pci_probe */
	ddev = pci_get_drvdata(pdev);
	if (!ddev) {
		pr_err("r9700_tune_v2: check 2 failed - no drvdata on %s\n", pci);
		return -EINVAL;
	}

	adev = (u8 *)ddev - ofs_ddev;
	if (rd64(adev, ofs_pdev) != (u64)(uintptr_t)pdev) {
		pr_err("r9700_tune_v2: check 2 failed - adev+ofs_pdev (%lu) != pdev\n",
		       ofs_pdev);
		return -EINVAL;
	}
	pr_info("r9700_tune_v2: check 2 ok - adev=%px, pdev offset %lu\n", adev, ofs_pdev);

	smu = (u8 *)(uintptr_t)rd64(adev, ofs_pp_handle);
	if (!smu) {
		pr_err("r9700_tune_v2: check 3 failed - powerplay.pp_handle is NULL\n");
		return -EINVAL;
	}
	if (rd64(smu, ofs_smu_adev) != (u64)(uintptr_t)adev) {
		pr_err("r9700_tune_v2: check 3 failed - smu+ofs_smu_adev (%lu) != adev\n",
		       ofs_smu_adev);
		return -EINVAL;
	}
	pr_info("r9700_tune_v2: check 3 ok - smu=%px, adev back-pointer matches\n", smu);

	if (!rd8(smu, ofs_pm_enabled) || !rd8(smu, ofs_od_enabled)) {
		pr_err("r9700_tune_v2: check 4 failed - pm_enabled=%u od_enabled=%u (need both)\n",
		       rd8(smu, ofs_pm_enabled), rd8(smu, ofs_od_enabled));
		return -EINVAL;
	}
	pr_info("r9700_tune_v2: check 4 ok - pm_enabled, od_enabled\n");

	return 0;
}

static int check_function(void)
{
	u64 sfr;

	if (!expect_sfr) {
		pr_err("r9700_tune_v2: check 5 failed - expect_sfr not supplied\n");
		return -EINVAL;
	}

	if (!rd64(smu, ofs_ppt_funcs)) {
		pr_err("r9700_tune_v2: check 5 failed - ppt_funcs is NULL\n");
		return -EINVAL;
	}
	sfr = rd_sfr();
	if (sfr != expect_sfr) {
		pr_err("r9700_tune_v2: check 5 failed - ppt_funcs+ofs_set_soft_freq = 0x%llx, expected 0x%lx\n",
		       sfr, expect_sfr);
		return -EINVAL;
	}
	pr_info("r9700_tune_v2: check 5 ok - set_soft_freq_limited_range @ 0x%lx\n", expect_sfr);

	return 0;
}

/* the five fingerprint fields of an OD buffer must match the sysfs view */
static int fingerprint(u8 *t, const char *name)
{
	if (rd16(t, od_fminpwm) != (u16)exp_fminpwm) {
		pr_err("r9700_tune_v2: check 6 failed - %s FanMinimumPwm@%lu = %u, sysfs says %d\n",
		       name, od_fminpwm, rd16(t, od_fminpwm), exp_fminpwm);
		return -EINVAL;
	}
	if (rd16(t, od_ac_target) != (u16)exp_ac_target) {
		pr_err("r9700_tune_v2: check 6 failed - %s AcousticTargetRpm@%lu = %u, sysfs says %d\n",
		       name, od_ac_target, rd16(t, od_ac_target), exp_ac_target);
		return -EINVAL;
	}
	if (rd16(t, od_ac_limit) != (u16)exp_ac_limit) {
		pr_err("r9700_tune_v2: check 6 failed - %s AcousticLimitRpm@%lu = %u, sysfs says %d\n",
		       name, od_ac_limit, rd16(t, od_ac_limit), exp_ac_limit);
		return -EINVAL;
	}
	if (rd16(t, od_fan_target) != (u16)exp_fan_target) {
		pr_err("r9700_tune_v2: check 6 failed - %s FanTargetTemperature@%lu = %u, sysfs says %d\n",
		       name, od_fan_target, rd16(t, od_fan_target), exp_fan_target);
		return -EINVAL;
	}
	if ((s16)rd16(t, od_vo) != (s16)exp_vo0) {
		pr_err("r9700_tune_v2: check 6 failed - %s VoltageOffsetPerZoneBoundary[0]@%lu = %d, sysfs says %d\n",
		       name, od_vo, (s16)rd16(t, od_vo), exp_vo0);
		return -EINVAL;
	}
	return 0;
}

static int check_od(void)
{
	u8 *boot;
	int ret;

	od = (u8 *)(uintptr_t)rd64(smu, ofs_smu_table + ofs_od_table);
	boot = (u8 *)(uintptr_t)rd64(smu, ofs_smu_table + ofs_boot_od_table);
	od_user = (u8 *)(uintptr_t)rd64(smu, ofs_smu_table + ofs_user_od_table);

	if (!od || !boot || !od_user) {
		pr_err("r9700_tune_v2: check 6 failed - OD buffers NULL (%px/%px/%px)\n",
		       od, boot, od_user);
		return -EINVAL;
	}
	if (od == boot || od == od_user || boot == od_user) {
		pr_err("r9700_tune_v2: check 6 failed - OD buffers not distinct\n");
		return -EINVAL;
	}

	/* optional cross-check: the SMU table slot for OVERDRIVE must be od_size */
	if (ofs_tables && sz_smutable && idx_overdrive) {
		u8 *slot = smu + ofs_smu_table + ofs_tables + idx_overdrive * sz_smutable + ofs_table_size;
		u64 slotsize = rd64(slot, 0);

		if (slotsize != od_size) {
			pr_err("r9700_tune_v2: check 6 failed - tables[OVERDRIVE].size = %llu, expected %lu\n",
			       slotsize, od_size);
			return -EINVAL;
		}
		pr_info("r9700_tune_v2: check 6a ok - tables[OVERDRIVE].size = %lu\n", od_size);
	}

	/* Deviation from the port plan: the plan wanted all six
	 * VoltageOffsetPerZoneBoundary entries compared. smu_v14_0_2_emit_clk_levels
	 * prints only zone 0 for OD_VDDGFX_OFFSET, so sysfs gives us no way to know
	 * zones 1..5 on this kernel. Zone 0 plus the four fan fields is still enough
	 * to prove we are looking at the right buffer. */
	ret = fingerprint(od, "staging");
	if (ret)
		return ret;
	pr_info("r9700_tune_v2: check 6 ok - OD staging buffer %px fingerprint matches sysfs\n", od);

	return 0;
}

static int check_ranges(void)
{
	if (sclk_max && (sclk_max < 800 || sclk_max > 2350)) {
		pr_err("r9700_tune_v2: check 7 failed - sclk_max %u outside 0 or 800..2350\n", sclk_max);
		return -EINVAL;
	}
	if (ppt_offset < -60 || ppt_offset > 0) {
		pr_err("r9700_tune_v2: check 7 failed - ppt_offset %d outside -60..0\n", ppt_offset);
		return -EINVAL;
	}
	return 0;
}

static int run_checks(void)
{
	int ret;

	verified = false;

	ret = check_ranges();
	if (ret)
		goto fail;
	pr_info("r9700_tune_v2: check 7 ok - sclk_max=%u ppt_offset=%d\n", sclk_max, ppt_offset);
	ret = check_pci();
	if (ret)
		goto fail;
	ret = check_pointers();
	if (ret)
		goto fail;
	ret = check_function();
	if (ret)
		goto fail;
	ret = check_od();
	if (ret)
		goto fail;

	verified = true;
	return 0;

fail:
	adev = NULL;
	smu = NULL;
	od = NULL;
	od_user = NULL;
	return ret;
}

/* --------------------------- actions ----------------------------- */

static int do_sclk(void)
{
	set_soft_freq_fn fn;
	struct mutex *pm;
	u64 sfr;
	int ret;

	if (!verified)
		return -EINVAL;
	ret = check_ranges();
	if (ret)
		return ret;
	if (!sclk_max)
		return 0;

	if (dry_run) {
		pr_info("r9700_tune_v2: dry_run - would call set_soft_freq_limited_range(smu, SMU_GFXCLK, 0, %u, false)\n",
			sclk_max);
		return 0;
	}

	/* the SMU must be awake; same as amdgpu's own sysfs handlers */
	ret = pm_runtime_resume_and_get(&pdev->dev);
	if (ret < 0) {
		pr_err("r9700_tune_v2: runtime resume failed: %d\n", ret);
		return ret;
	}

	pm = (struct mutex *)(adev + ofs_pm_mutex);
	mutex_lock(pm);
	/* re-read and re-verify right before the indirect call */
	sfr = rd_sfr();
	if (sfr != expect_sfr) {
		mutex_unlock(pm);
		pm_runtime_put_autosuspend(&pdev->dev);
		pr_err("r9700_tune_v2: set_soft_freq_limited_range changed to 0x%llx (expected 0x%lx), refusing\n",
		       sfr, expect_sfr);
		verified = false;
		return -EINVAL;
	}
	fn = (set_soft_freq_fn)(uintptr_t)sfr;
	ret = fn(smu, SMU_CLK_GFXCLK, 0, sclk_max, false);
	mutex_unlock(pm);

	pm_runtime_mark_last_busy(&pdev->dev);
	pm_runtime_put_autosuspend(&pdev->dev);

	if (ret)
		pr_err("r9700_tune_v2: soft max %u MHz failed: %d\n", sclk_max, ret);
	else
		pr_info("r9700_tune_v2: SCLK soft max set to %u MHz\n", sclk_max);

	return ret;
}

/*
 * Stage ppt_offset (0 = stock) with the PPT feature bit. With ppt_force the
 * Ppt field of user_overdrive_table is also changed so the driver's commit
 * path sees a difference and uploads: the commit skips the upload when the
 * staging buffer equals the last committed table, which would otherwise make
 * re-applying the same Ppt after a GPU reset a no-op.
 */
static int do_ppt(void)
{
	struct mutex *pm;
	u32 mask;
	int ret;

	if (!verified)
		return -EINVAL;
	ret = check_ranges();
	if (ret)
		return ret;

	mask = rd32(od, od_fcm);

	if (dry_run) {
		pr_info("r9700_tune_v2: dry_run - would set Ppt@%lu = %d and FeatureCtrlMask bit %d (mask 0x%x -> 0x%x)%s\n",
			od_ppt, ppt_offset, OD_BIT_PPT, mask, mask | (1U << OD_BIT_PPT),
			ppt_force ? ", forcing the upload" : "");
		return 0;
	}

	pm = (struct mutex *)(adev + ofs_pm_mutex);
	mutex_lock(pm);
	if (ppt_force) {
		/* only touch the committed copy if it is recognisably the OD table */
		ret = fingerprint(od_user, "user");
		if (ret) {
			mutex_unlock(pm);
			return ret;
		}
		put_unaligned_le16((u16)(s16)(ppt_offset ? 0 : -1), od_user + od_ppt);
	}
	put_unaligned_le16((u16)(s16)ppt_offset, od + od_ppt);
	put_unaligned_le32(mask | (1U << OD_BIT_PPT), od + od_fcm);
	mutex_unlock(pm);

	pr_info("r9700_tune_v2: staged Ppt=%d%% (bit %d set%s) - commit with: echo c > pp_od_clk_voltage\n",
		ppt_offset, OD_BIT_PPT, ppt_force ? ", forced" : "");

	return 0;
}

static int param_apply(const char *val, int (*action)(void))
{
	unsigned int v;
	int ret = kstrtouint(val, 0, &v);

	if (ret)
		return ret;
	if (v != 1)
		return -EINVAL;
	return action();
}

static int param_apply_sclk(const char *val, const struct kernel_param *kp)
{
	return param_apply(val, do_sclk);
}

static const struct kernel_param_ops apply_sclk_ops = {
	.set = param_apply_sclk,
	.get = param_get_uint,
};

static int param_apply_ppt(const char *val, const struct kernel_param *kp)
{
	return param_apply(val, do_ppt);
}

static const struct kernel_param_ops apply_ppt_ops = {
	.set = param_apply_ppt,
	.get = param_get_uint,
};

static int param_check(const char *val, const struct kernel_param *kp)
{
	return param_apply(val, run_checks);
}

static const struct kernel_param_ops check_ops = {
	.set = param_check,
	.get = param_get_uint,
};

/* read-only: current Ppt in the driver OD staging buffer */
static int param_get_ppt_current(char *buf, const struct kernel_param *kp)
{
	if (!verified)
		return sysfs_emit(buf, "unknown\n");
	return sysfs_emit(buf, "%d\n", (s16)rd16(od, od_ppt));
}

static const struct kernel_param_ops ppt_current_ops = {
	.get = param_get_ppt_current,
};

/* read-only: adev->gpu_reset_counter, so the drift check can see GPU resets */
static int param_get_reset_count(char *buf, const struct kernel_param *kp)
{
	if (!verified || !ofs_reset_counter)
		return sysfs_emit(buf, "unknown\n");
	return sysfs_emit(buf, "%d\n", READ_ONCE(*(int *)(adev + ofs_reset_counter)));
}

static const struct kernel_param_ops reset_count_ops = {
	.get = param_get_reset_count,
};

static unsigned int apply_sclk_dummy, apply_ppt_dummy, check_dummy;

module_param_cb(sclk_apply, &apply_sclk_ops, &apply_sclk_dummy, 0644);
MODULE_PARM_DESC(sclk_apply, "write 1 to apply the SCLK soft max");

module_param_cb(ppt_apply, &apply_ppt_ops, &apply_ppt_dummy, 0644);
MODULE_PARM_DESC(ppt_apply, "write 1 to stage the Ppt offset (commit with echo c > pp_od_clk_voltage)");

module_param_cb(check, &check_ops, &check_dummy, 0644);
MODULE_PARM_DESC(check, "write 1 to re-run all self-checks");

module_param_cb(ppt_current, &ppt_current_ops, NULL, 0444);
MODULE_PARM_DESC(ppt_current, "current Ppt value in the driver OD staging buffer");

module_param_cb(reset_count, &reset_count_ops, NULL, 0444);
MODULE_PARM_DESC(reset_count, "amdgpu gpu_reset_counter");

module_param(dry_run, bool, 0644);
MODULE_PARM_DESC(dry_run, "1 = check and report only, do not touch the card (default 1)");

module_param(sclk_max, uint, 0644);
MODULE_PARM_DESC(sclk_max, "SCLK soft max in MHz, 0 = no change");

module_param(ppt_offset, int, 0644);
MODULE_PARM_DESC(ppt_offset, "PPT offset in percent, -60..0 (0 = stock)");

module_param(ppt_force, bool, 0644);
MODULE_PARM_DESC(ppt_force, "1 = make the next commit upload the Ppt even if unchanged");

module_param(pci, charp, 0444);
MODULE_PARM_DESC(pci, "PCI id of the R9700, domain:bus:slot.func");

module_param(ofs_pdev, ulong, 0444);
module_param(ofs_ddev, ulong, 0444);
module_param(ofs_pp_handle, ulong, 0444);
module_param(ofs_pm_mutex, ulong, 0444);
module_param(ofs_reset_counter, ulong, 0444);
module_param(ofs_smu_adev, ulong, 0444);
module_param(ofs_ppt_funcs, ulong, 0444);
module_param(ofs_smu_table, ulong, 0444);
module_param(ofs_od_table, ulong, 0444);
module_param(ofs_boot_od_table, ulong, 0444);
module_param(ofs_user_od_table, ulong, 0444);
module_param(ofs_od_enabled, ulong, 0444);
module_param(ofs_pm_enabled, ulong, 0444);
module_param(ofs_set_soft_freq, ulong, 0444);
module_param(od_size, ulong, 0444);
module_param(od_fcm, ulong, 0444);
module_param(od_vo, ulong, 0444);
module_param(od_ppt, ulong, 0444);
module_param(od_fminpwm, ulong, 0444);
module_param(od_ac_target, ulong, 0444);
module_param(od_ac_limit, ulong, 0444);
module_param(od_fan_target, ulong, 0444);
module_param(ofs_tables, ulong, 0444);
module_param(idx_overdrive, ulong, 0444);
module_param(sz_smutable, ulong, 0444);
module_param(ofs_table_size, ulong, 0444);
module_param(expect_sfr, ulong, 0444);

/* writable: the apply script refreshes them before every re-check */
module_param(exp_fminpwm, int, 0644);
module_param(exp_ac_target, int, 0644);
module_param(exp_ac_limit, int, 0644);
module_param(exp_fan_target, int, 0644);
module_param(exp_vo0, int, 0644);

static int __init r9700_tune_v2_init(void)
{
	int ret = run_checks();

	if (ret) {
		pr_err("r9700_tune_v2: self-checks failed, nothing done\n");
		if (pdev)
			pci_dev_put(pdev);
		return ret;
	}

	/* stage PPT first, then the soft max: the OD commit re-inits DPM and
	 * drops previously set soft limits, so the commit itself is done by
	 * userspace after this point. ppt_offset=0 at load means "no change". */
	if (ppt_offset)
		do_ppt();
	do_sclk();

	return 0;
}

static void __exit r9700_tune_v2_exit(void)
{
	if (pdev)
		pci_dev_put(pdev);
	pr_info("r9700_tune_v2: unloaded. Reset: echo auto > power_dpm_force_performance_level; "
		"Ppt stays until a Ppt=0 commit or reboot\n");
}

module_init(r9700_tune_v2_init);
module_exit(r9700_tune_v2_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("IBT-safe SCLK soft-max cap and below-floor PPT offset for AMD R9700 (Navi 48, SMU 14.0.2)");
MODULE_VERSION("1.1");
