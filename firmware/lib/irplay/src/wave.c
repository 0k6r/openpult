#include "irplay/wave.h"

uint32_t irp_wave_period_ticks(uint32_t clock_hz, uint32_t carrier_hz)
{
	return (clock_hz + carrier_hz / 2) / carrier_hz;
}

uint32_t irp_wave_edge(const struct irp_wave *w, uint64_t t_us)
{
	uint64_t ticks = t_us * w->ticks_per_us;

	return (uint32_t)((ticks + w->period_ticks / 2) / w->period_ticks);
}

static void load_symbol(struct irp_wave *w)
{
	w->t_us += irp_duration(w->sig, w->sec, w->idx);
	w->sym_end = irp_wave_edge(w, w->t_us);
}

void irp_wave_init(struct irp_wave *w, const struct irp_signal *sig, enum irp_section sec,
		   uint32_t ticks_per_us, uint32_t period_ticks, uint16_t mark, uint16_t space)
{
	*w = (struct irp_wave){
		.sig = sig,
		.sec = sec,
		.ticks_per_us = ticks_per_us,
		.period_ticks = period_ticks,
		.mark = mark,
		.space = space,
	};
	if (sig->count[sec] == 0) {
		w->finished = true;
		return;
	}
	load_symbol(w);
}

size_t irp_wave_fill(struct irp_wave *w, uint16_t *out, size_t n)
{
	size_t k = 0;

	while (k < n && !w->finished) {
		while (w->pos >= w->sym_end && w->idx < w->sig->count[w->sec]) {
			if (++w->idx < w->sig->count[w->sec]) {
				load_symbol(w);
			}
		}
		if (w->idx >= w->sig->count[w->sec]) {
			/* Sections end with a space; it only vanishes if shorter than half a
			 * period, and the output must still return low. */
			if (w->last_mark || w->pos == 0) {
				out[k++] = w->space;
				w->pos++;
				w->last_mark = false;
			}
			w->finished = true;
			break;
		}

		bool mark = (w->idx % 2) == 0;

		out[k++] = mark ? w->mark : w->space;
		w->pos++;
		w->last_mark = mark;
	}
	return k;
}
