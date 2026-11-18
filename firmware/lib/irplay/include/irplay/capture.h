/*
 * irplay: learning. Turns edge timestamps from a demodulating receiver into a list of
 * durations and encodes it as Capture notifications.
 */
#ifndef IRPLAY_CAPTURE_H_
#define IRPLAY_CAPTURE_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define IRP_CAPTURE_MAX 512u
#define IRP_CAPTURE_END_SPACE_US 130000u
#define IRP_CAPTURE_MAX_US 1000000u
#define IRP_CAPTURE_MIN_DURATIONS 6u

#define IRP_CAPTURE_TRUNCATED 0x01u
#define IRP_CAPTURE_TIMEOUT 0x02u

struct irp_capture {
	uint32_t durations[IRP_CAPTURE_MAX];
	uint16_t count;
	uint8_t flags;
	bool started;
	bool mark; /* level since the last edge */
	bool done;
	uint32_t first_us;
	uint32_t last_us;
};

/* Clears the capture; the receiver is assumed idle (output inactive). */
void irp_capture_reset(struct irp_capture *c);

/* Sets the current receiver level (true = mark) before the first edge, e.g. read
 * from the pin when capturing starts. */
void irp_capture_set_level(struct irp_capture *c, bool mark);

/*
 * An edge of the receiver output at t_us (free-running microsecond counter, may wrap).
 * Edges toggle the tracked level; a capture starts on an edge into a mark.
 */
void irp_capture_edge(struct irp_capture *c, uint32_t t_us);

/* Applies the end conditions at now_us; returns true once the capture is complete. */
bool irp_capture_poll(struct irp_capture *c, uint32_t now_us);

/*
 * Encodes notification number `index` (0, 1, ...) of a capture into out[0..max) and
 * returns its length; *pos tracks the next duration (start with 0) and *last is set
 * on the final fragment. Durations are LEB128 varints, never split across fragments.
 * Returns 0 if max is too small to make progress.
 */
size_t irp_capture_fragment(const uint32_t *durations, uint16_t count, uint8_t flags,
			    uint8_t capture_id, uint8_t index, uint16_t *pos, uint8_t *out,
			    size_t max, bool *last);

#endif /* IRPLAY_CAPTURE_H_ */
