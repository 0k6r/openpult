/* Cell-stack voltage -> state of charge. Pure C (host tests). */
#ifndef BATTERY_CURVE_H_
#define BATTERY_CURVE_H_

#include <stdbool.h>
#include <stdint.h>

enum battery_chemistry {
	/* PROTOCOL.md: 1.50 V 100 %, 1.30 V 60 %, 1.20 V 35 %, 1.10 V 15 %, 1.00 V 0 %;
	 * low below 1.10 V per cell */
	BATTERY_ALKALINE,
	/* 4.20 V 100 % ... 3.30 V 0 %; low below 3.50 V per cell */
	BATTERY_LI_ION,
};

/* Piecewise linear over the per-cell voltage, rounded to the nearest percent. */
uint8_t battery_percent(uint32_t stack_mv, uint8_t cells, enum battery_chemistry chem);

bool battery_low(uint32_t stack_mv, uint8_t cells, enum battery_chemistry chem);

#endif /* BATTERY_CURVE_H_ */
