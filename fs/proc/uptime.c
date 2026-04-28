// SPDX-License-Identifier: GPL-2.0
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/time.h>
#include <linux/kernel_stat.h>
#include <linux/timekeeping.h>
#include <linux/time64.h>
#include <linux/jiffies.h>

extern uint64_t arch_sys_boot_offset;

static int uptime_proc_show(struct seq_file *m, void *v)
{
	struct timespec64 uptime;
	u64 total_uptime_nsec;
	u64 idle_nsec;
	u32 variator;

	ktime_get_boottime_ts64(&uptime);

	/* --- GHOST UPTIME OFFSET --- */
	if (arch_sys_boot_offset > 0) {
		// Cộng thêm số giây ảo vào uptime
		uptime.tv_sec += (arch_sys_boot_offset / 1000000000ULL);
	}
	/* --------------------------- */

	/* Tính tổng số nano giây uptime (ĐÃ BAO GỒM THỜI GIAN FAKE) */
	total_uptime_nsec = ((u64)uptime.tv_sec * NSEC_PER_SEC) + uptime.tv_nsec;

	/* Fake Idle time: Giao động 72% - 74% của tổng Uptime */
	variator = (u32)(jiffies % 3); 
	idle_nsec = (total_uptime_nsec * (72 + variator)) / 100; 

	/* In ra file /proc/uptime theo chuẩn: <uptime_giây> <idle_giây> */
	seq_printf(m, "%lu.%02lu %lu.%02lu\n",
		(unsigned long) uptime.tv_sec,
		(uptime.tv_nsec / (NSEC_PER_SEC / 100)),
		(unsigned long) (idle_nsec / NSEC_PER_SEC),
		(unsigned long) ((idle_nsec % NSEC_PER_SEC) / (NSEC_PER_SEC / 100)));
		
	return 0;
}

static int __init proc_uptime_init(void)
{
	proc_create_single("uptime", 0, NULL, uptime_proc_show);
	return 0;
}
fs_initcall(proc_uptime_init);
