#include <stddef.h>

#include "battery_curve.h"

struct point {
	uint16_t cell_mv;
	uint8_t pct;
};

static const struct point alkaline[] = {
	{1500, 100}, {1300, 60}, {1200, 35}, {1100, 15}, {1000, 0},
};

static const struct point li_ion[] = {
	{4200, 100}, {4000, 80}, {3870, 60}, {3780, 40}, {3700, 20}, {3600, 8}, {3300, 0},
};

static const struct {
	const struct point *points;
	size_t n;
	uint16_t low_cell_mv;
} curves[] = {
	[BATTERY_ALKALINE] = {alkaline, sizeof(alkaline) / sizeof(alkaline[0]), 1100},
	[BATTERY_LI_ION] = {li_ion, sizeof(li_ion) / sizeof(li_ion[0]), 3500},
};

uint8_t battery_percent(uint32_t stack_mv, uint8_t cells, enum battery_chemistry chem)
{
	const struct point *c = curves[chem].points;

	if (cells == 0) {
		return 0;
	}
	if (stack_mv >= (uint32_t)c[0].cell_mv * cells) {
		return c[0].pct;
	}
	for (size_t i = 1; i < curves[chem].n; i++) {
		uint32_t lo = (uint32_t)c[i].cell_mv * cells;

		if (stack_mv >= lo) {
			uint32_t span = (uint32_t)c[i - 1].cell_mv * cells - lo;
			uint32_t gain = (uint32_t)(c[i - 1].pct - c[i].pct);

			return (uint8_t)(c[i].pct + ((stack_mv - lo) * gain + span / 2) / span);
		}
	}
	return 0;
}

bool battery_low(uint32_t stack_mv, uint8_t cells, enum battery_chemistry chem)
{
	return stack_mv < (uint32_t)curves[chem].low_cell_mv * cells;
}
