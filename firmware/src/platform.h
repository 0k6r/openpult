/* SoC-specific services outside the IR path (src/hal/<family>/platform_*.c). */
#ifndef PLATFORM_H_
#define PLATFORM_H_

/* Resets into the UF2 bootloader's USB drive mode. Does not return. */
void platform_enter_uf2_bootloader(void);

#endif /* PLATFORM_H_ */
