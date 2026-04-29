#include <linux/types.h>
#include <linux/random.h>
#include <linux/init.h>

extern u64 arch_sys_boot_offset;

void ghost_uptime_init(void)
{
	u32 rand;
	u64 min_secs;
	u64 range_secs;
	u64 offset_secs;

	get_random_bytes(&rand, sizeof(rand));

	/* 15 ngày -> 20 ngày, không bị số ngày tròn */
	min_secs = 15ULL * 86400ULL;
	range_secs = 5ULL * 86400ULL;

	offset_secs = min_secs + (rand % range_secs);

	arch_sys_boot_offset = offset_secs * 1000000000ULL;
}

static int __init ghost_uptime_module_init(void)
{
	ghost_uptime_init();
	return 0;
}
early_initcall(ghost_uptime_module_init);
