#include <string.h>

#include "irplay/player.h"

void irp_player_init(struct irp_player *p)
{
	memset(p, 0, sizeof(*p));
}

int irp_player_play(struct irp_player *p, const struct irp_signal *sig, uint32_t key)
{
	if (p->count == IRP_QUEUE_DEPTH || p->bytes + sig->blob_len > IRP_QUEUE_BYTES) {
		return IRP_ERR_QUEUE_FULL;
	}

	struct irp_press *e = &p->pending[(p->head + p->count) % IRP_QUEUE_DEPTH];

	e->sig = *sig;
	e->key = key;
	e->hold_units = 0;
	p->count++;
	p->bytes = (uint16_t)(p->bytes + sig->blob_len);
	return IRP_OK;
}

static uint64_t hold_window_us(const struct irp_signal *s)
{
	uint64_t twice_unit = 2ull * s->section_us[irp_unit_section(s)];

	return twice_unit > IRP_HOLD_WINDOW_MIN_US ? twice_unit : IRP_HOLD_WINDOW_MIN_US;
}

int irp_player_hold(struct irp_player *p, uint32_t key, uint8_t count, uint64_t now_us)
{
	if (count < 1) {
		count = 1;
	} else if (count > IRP_HOLD_COUNT_MAX) {
		count = IRP_HOLD_COUNT_MAX;
	}

	if (p->active && p->hold_ok && p->cur.key == key) {
		if (count > p->units_left) {
			p->units_left = count;
		}
		return IRP_OK;
	}
	for (int i = p->count - 1; i >= 0; i--) {
		struct irp_press *e = &p->pending[(p->head + i) % IRP_QUEUE_DEPTH];

		if (e->key == key) {
			if (count > e->hold_units) {
				e->hold_units = count;
			}
			return IRP_OK;
		}
	}
	if (!p->active && p->hold_ok && p->cur.key == key &&
	    now_us - p->last_done_us < hold_window_us(&p->cur.sig)) {
		p->active = true;
		p->fresh = false;
		p->units_left = count;
		return IRP_OK;
	}
	return IRP_ERR_NO_HOLD;
}

void irp_player_stop(struct irp_player *p)
{
	p->count = 0;
	p->bytes = 0;
	p->hold_ok = false;
	if (p->on_air) {
		p->units_left = 1;
	} else {
		p->active = false;
	}
}

bool irp_player_peek(const struct irp_player *p, struct irp_unit *unit, uint64_t *not_before_us)
{
	if (p->on_air) {
		return false;
	}
	if (p->active) {
		unit->sig = &p->cur.sig;
		unit->section = p->fresh ? irp_first_section(&p->cur.sig)
					 : irp_unit_section(&p->cur.sig);
		*not_before_us = 0;
		return true;
	}
	if (p->count > 0) {
		unit->sig = &p->pending[p->head].sig;
		unit->section = irp_first_section(unit->sig);
		*not_before_us = p->any_done ? p->last_done_us + IRP_PRESS_GAP_US : 0;
		return true;
	}
	return false;
}

void irp_player_start(struct irp_player *p)
{
	if (!p->active) {
		if (p->count == 0) {
			return;
		}
		const struct irp_press *e = &p->pending[p->head];
		uint8_t units = irp_press_units(&e->sig);

		p->cur = *e;
		p->units_left = e->hold_units > units ? e->hold_units : units;
		p->active = true;
		p->fresh = true;
		p->bytes = (uint16_t)(p->bytes - e->sig.blob_len);
		p->head = (uint8_t)((p->head + 1) % IRP_QUEUE_DEPTH);
		p->count--;
	}
	p->on_air = true;
	p->hold_ok = true;
}

void irp_player_done(struct irp_player *p, uint64_t now_us)
{
	p->on_air = false;
	p->fresh = false;
	p->last_done_us = now_us;
	p->any_done = true;
	if (p->units_left > 0) {
		p->units_left--;
	}
	if (p->units_left == 0) {
		p->active = false;
	}
}

uint8_t irp_player_queue_free(const struct irp_player *p)
{
	return (uint8_t)(IRP_QUEUE_DEPTH - p->count);
}

bool irp_player_busy(const struct irp_player *p)
{
	return p->active || p->count > 0;
}
