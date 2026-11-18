#include <zephyr/sys/reboot.h>
#include <soc.h>

#include "platform.h"

/* Adafruit nRF52 bootloader (and its forks): DFU_MAGIC_UF2_RESET */
#define UF2_GPREGRET_MAGIC 0x57

void platform_enter_uf2_bootloader(void)
{
	NRF_POWER->GPREGRET = UF2_GPREGRET_MAGIC;
	sys_reboot(SYS_REBOOT_COLD);
}
