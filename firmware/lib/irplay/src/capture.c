#include "irplay/capture.h"
#include "irplay/signal.h"

static void discard(struct irp_capture *c)
{
	c->count = 0;
	c->flags = 0;
	c->started = false;
	c->done = false;
}

void irp_capture_reset(struct irp_capture *c)
{
	discard(c);
	c->mark = false; /* receiver idle */
}

void irp_capture_set_level(struct irp_capture *c, bool mark)
{
	if (!c->started) {
		c->mark = mark;
	}
}

/* A burst ended; keeps it if long enough, otherwise drops it as noise. */
static bool end_burst(struct irp_capture *c, uint8_t flags)
{
	if (c->count < IRP_CAPTURE_MIN_DURATIONS) {
		discard(c);
		return false;
	}
	c->flags |= flags;
	c->done = true;
	return true;
}

void irp_capture_edge(struct irp_capture *c, uint32_t t_us)
{
	uint32_t d = t_us - c->last_us;
	bool was_mark = c->mark;

	if (c->done) {
		return;
	}
	/* The receiver level is tracked across discarded bursts, so a capture always
	 * starts on an edge into a mark. */
	c->mark = !c->mark;

	if (c->started) {
		if (!was_mark && d > IRP_CAPTURE_END_SPACE_US) {
			if (end_burst(c, 0)) {
				return;
			}
		} else if (t_us - c->first_us >= IRP_CAPTURE_MAX_US) {
			if (end_burst(c, IRP_CAPTURE_TRUNCATED)) {
				return;
			}
		} else {
			c->durations[c->count++] = d;
			c->last_us = t_us;
			if (c->count == IRP_CAPTURE_MAX) {
				c->flags |= IRP_CAPTURE_TRUNCATED;
				c->done = true;
			}
			return;
		}
	}

	c->last_us = t_us;
	if (c->mark) {
		c->started = true;
		c->first_us = t_us;
	}
}

bool irp_capture_poll(struct irp_capture *c, uint32_t now_us)
{
	if (c->done || !c->started) {
		return c->done;
	}
	if (!c->mark && now_us - c->last_us > IRP_CAPTURE_END_SPACE_US) {
		return end_burst(c, 0);
	}
	if (now_us - c->first_us >= IRP_CAPTURE_MAX_US) {
		return end_burst(c, IRP_CAPTURE_TRUNCATED);
	}
	return false;
}

size_t irp_capture_fragment(const uint32_t *durations, uint16_t count, uint8_t flags,
			    uint8_t capture_id, uint8_t index, uint16_t *pos, uint8_t *out,
			    size_t max, bool *last)
{
	size_t n = 0;
	uint16_t start = *pos;

	if (max < (index == 0 ? 5u : 2u) || index > 0x7F) {
		return 0;
	}
	out[n++] = capture_id;
	out[n++] = index;
	if (index == 0) {
		out[n++] = flags;
		out[n++] = (uint8_t)count;
		out[n++] = (uint8_t)(count >> 8);
	}

	while (*pos < count) {
		size_t k = irp_varint_encode(durations[*pos], &out[n], max - n);

		if (k == 0) {
			break;
		}
		n += k;
		(*pos)++;
	}
	if (*pos == start && start < count) {
		return 0;
	}

	*last = *pos == count;
	if (*last) {
		out[1] |= 0x80u;
	}
	return n;
}
