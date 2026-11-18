/*
 * irplay: press queue and hold semantics. Decides which section goes on air next and
 * when. Time is passed in, so behaviour is deterministic; the caller serialises
 * access and reports when a unit starts and finishes on air.
 */
#ifndef IRPLAY_PLAYER_H_
#define IRPLAY_PLAYER_H_

#include <stdbool.h>
#include <stdint.h>

#include "irplay/signal.h"

#define IRP_QUEUE_DEPTH 8u
#define IRP_QUEUE_BYTES 2048u
#define IRP_PRESS_GAP_US 90000u
#define IRP_HOLD_WINDOW_MIN_US 200000u
#define IRP_HOLD_COUNT_MAX 20u

struct irp_press {
	struct irp_signal sig;
	uint32_t key;       /* PLAY: sig_id; legacy SEND: see irp_sirc_key() */
	uint8_t hold_units; /* units requested by HOLD while still queued */
};

struct irp_player {
	struct irp_press pending[IRP_QUEUE_DEPTH];
	uint8_t head;
	uint8_t count;
	uint16_t bytes;

	/* The press on air, or the last one once it has finished. */
	struct irp_press cur;
	bool active;     /* units left to play */
	bool on_air;
	bool fresh;      /* the next unit is the first of the press */
	bool hold_ok;    /* cur may still be resumed by HOLD */
	uint8_t units_left; /* including the unit on air */
	uint64_t last_done_us;
	bool any_done;
};

struct irp_unit {
	const struct irp_signal *sig;
	enum irp_section section;
};

void irp_player_init(struct irp_player *p);

/* Queues a new press. IRP_ERR_QUEUE_FULL at 8 presses or 2048 bytes of signals. */
int irp_player_play(struct irp_player *p, const struct irp_signal *sig, uint32_t key);

/*
 * Extends the press with this key so that `count` (1..20) units are played counting
 * from the unit on air; it never shortens what the press itself still has to play.
 * Applies to the press on air, the last one if it finished less than
 * max(200 ms, 2 x repeat unit) ago (resumed with repeat units only), or a press still
 * waiting in the queue. Returns IRP_ERR_NO_HOLD otherwise.
 */
int irp_player_hold(struct irp_player *p, uint32_t key, uint8_t count, uint64_t now_us);

/* Clears the queue; the unit on air finishes, nothing follows and HOLD cannot resume it. */
void irp_player_stop(struct irp_player *p);

/* The next unit and the earliest time it may start (0 = now). False if idle or on air. */
bool irp_player_peek(const struct irp_player *p, struct irp_unit *unit, uint64_t *not_before_us);

/* The unit returned by irp_player_peek() went on air. */
void irp_player_start(struct irp_player *p);

/* The unit on air has finished. */
void irp_player_done(struct irp_player *p, uint64_t now_us);

uint8_t irp_player_queue_free(const struct irp_player *p);

/* Something is on air, between units or waiting in the queue. */
bool irp_player_busy(const struct irp_player *p);

#endif /* IRPLAY_PLAYER_H_ */
