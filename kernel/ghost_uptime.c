#include <linux/random.h> // Thêm thư viện để lấy số ngẫu nhiên
#include <linux/ghost_uptime.h>

u64 arch_sys_boot_offset = 0;
// ... các phần khác ...

void ghost_uptime_init(void) {
    uint64_t random_days;
    
    // Lấy số ngẫu nhiên từ 10 đến 20
    get_random_bytes(&random_days, sizeof(random_days));
    random_days = 10 + (random_days % 11); 

    // Chuyển sang Nano giây và gán vào biến toàn cục
    arch_sys_boot_offset = random_days * 86400ULL * 1000000000ULL;
}
