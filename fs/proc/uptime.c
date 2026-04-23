// SPDX-License-Identifier: GPL-2.0
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/time.h>
#include <linux/kernel_stat.h>
#include <linux/timekeeping.h>
#include <linux/time64.h> // Header quan trọng cho ns_to_timespec64

static int uptime_proc_show(struct seq_file *m, void *v)
{
	struct timespec64 uptime;
	u64 nsec, idle_nsec;
    u32 variator;

	nsec = ktime_get_boot_fast_ns();
    
    /* Sửa tên hàm ở đây */
	uptime = ns_to_timespec64(nsec); 
	
	/* Fake Idle time: 75% */
	variator = (u32)(jiffies % 3); 
    idle_nsec = (nsec * (72 + variator)) / 100; 

	seq_printf(m, "%lu.%02lu %lu.%02lu\n",
        (unsigned long) uptime.tv_sec,
        (uptime.tv_nsec / (NSEC_PER_SEC / 100)),
        (unsigned long) (idle_nsec / NSEC_PER_SEC),
        ((idle_nsec % NSEC_PER_SEC) / (NSEC_PER_SEC / 100)));
    return 0;
}

static int __init proc_uptime_init(void)
{
	proc_create_single("uptime", 0, NULL, uptime_proc_show);
	return 0;
}
fs_initcall(proc_uptime_init);
