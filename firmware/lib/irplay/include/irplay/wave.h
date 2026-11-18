/*
 * irplay: streams a section as one value per carrier period, for transmitters that
 * replay a buffer of per-period samples (e.g. nRF PWM with EasyDMA).
 *
 * Edges are placed at the carrier period nearest to their ideal time, computed from
 * the cumulative duration, so the error stays within half a period and never
 * accumulates. The output always ends with a space value.
 */
#ifndef IRPLAY_WAVE_H_
#define IRPLAY_WAVE_H_

#include <stddef.h>
#include <stdint.h>

#include "irplay/signal.h"

struct irp_wave {
	const struct irp_signal *sig;
	enum irp_section sec;
	uint32_t ticks_per_us;
	uint32_t period_ticks;
	uint16_t mark;
	uint16_t space;
	uint16_t idx;     /* current symbol */
	uint32_t sym_end; /* period index at which the current symbol ends */
	uint64_t t_us;    /* cumulative time at the end of the current symbol */
	uint32_t pos;     /* periods emitted */
	bool last_mark;
	bool finished;
};

/* Period of the carrier in ticks of a clock_hz timebase (rounded). */
uint32_t irp_wave_period_ticks(uint32_t clock_hz, uint32_t carrier_hz);

void irp_wave_init(struct irp_wave *w, const struct irp_signal *sig, enum irp_section sec,
		   uint32_t ticks_per_us, uint32_t period_ticks, uint16_t mark, uint16_t space);

/* Writes up to n values; fewer means the section is complete. */
size_t irp_wave_fill(struct irp_wave *w, uint16_t *out, size_t n);

/* Period index of the edge at cumulative time t_us. */
uint32_t irp_wave_edge(const struct irp_wave *w, uint64_t t_us);

#endif /* IRPLAY_WAVE_H_ */
