#ifndef BATTERY_H_
#define BATTERY_H_

#include <stdint.h>

int battery_init(void);

/*
 * One SAADC measurement of the battery node, scaled by the divider and corrected by
 * CONFIG_OPENPULT_BATT_DIODE_MV. Blocks for well under a millisecond.
 * Returns -ENOTSUP when the board has no battery measurement.
 */
int battery_measure_mv(uint16_t *mv);

#endif /* BATTERY_H_ */
