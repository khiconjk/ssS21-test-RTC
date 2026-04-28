#include <linux/types.h>
#include <linux/moduleparam.h>

/* mặc định = 0 → không fake */
extern uint64_t arch_sys_boot_offset;

/* cho phép chỉnh runtime hoặc boot cmdline */
module_param_named(arch_sys_boot_offset,
                   arch_sys_boot_offset,
                   ullong, 0644);
