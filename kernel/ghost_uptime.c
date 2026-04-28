#include <linux/types.h>
#include <linux/random.h>
#include <linux/init.h>
#include <linux/ghost_uptime.h>

u64 arch_sys_boot_offset = 0;

void ghost_uptime_init(void)
{
	u32 random_days;

	get_random_bytes(&random_days, sizeof(random_days));
	random_days = 15 + (random_days % 11);

	arch_sys_boot_offset = (u64)random_days * 86400ULL * 1000000000ULL;
}

static int __init ghost_uptime_module_init(void)
{
	ghost_uptime_init();
	return 0;
}
early_initcall(ghost_uptime_module_init);
