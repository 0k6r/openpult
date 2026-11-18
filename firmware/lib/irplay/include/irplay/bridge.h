/*
 * irplay: openpult protocol v2 command handling and Status encoding, independent of
 * the BLE stack and the transmitter hardware. The caller serialises access.
 */
#ifndef IRPLAY_BRIDGE_H_
#define IRPLAY_BRIDGE_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "irplay/frag.h"
#include "irplay/player.h"
#include "irplay/signal.h"

#define IRP_PROTO_VERSION 2u
#define IRP_STATUS_LEN 12u
#define IRP_WRITE_MAX 244u

enum irp_opcode {
	IRP_OP_SEND = 0x01,
	IRP_OP_STOP = 0x02,
	IRP_OP_PLAY = 0x10,
	IRP_OP_HOLD = 0x11,
	IRP_OP_LEARN_START = 0x20,
	IRP_OP_LEARN_STOP = 0x21,
	IRP_OP_ENTER_BOOTLOADER = 0xF0,
};

/* Status flags */
#define IRP_FLAG_TRANSMITTING 0x01u
#define IRP_FLAG_PAIRING 0x02u
#define IRP_FLAG_BATTERY_LOW 0x04u
#define IRP_FLAG_LEARNING 0x08u
#define IRP_FLAG_EXT_POWER 0x10u

/* Status caps */
#define IRP_CAP_PLAY 0x01u
#define IRP_CAP_LEARN 0x02u
#define IRP_CAP_SEND 0x04u
#define IRP_CAP_UF2 0x08u

#define IRP_LEARN_TIMEOUT_DEFAULT_S 20u
#define IRP_LEARN_TIMEOUT_MAX_S 60u

/* What the caller has to do after a command (bit mask). */
#define IRP_ACT_PLAYER 0x01u        /* queue changed: start or keep transmitting */
#define IRP_ACT_LEARN_START 0x02u
#define IRP_ACT_LEARN_STOP 0x04u
#define IRP_ACT_BOOTLOADER 0x08u

struct irp_bridge {
	struct irp_frag frag;
	struct irp_player player;
	struct irp_signal scratch;
	uint8_t caps;
	uint8_t last_error;
	bool learning;
	uint8_t learn_timeout_s;
};

void irp_bridge_init(struct irp_bridge *b, uint8_t caps);

/* Handles one Command write. Returns IRP_OK or an error code; *actions gets IRP_ACT_*. */
uint8_t irp_bridge_command(struct irp_bridge *b, const uint8_t *data, size_t len,
			   uint64_t now_us, unsigned int *actions);

/* Learning ended (capture, timeout or error). */
void irp_bridge_learn_done(struct irp_bridge *b);

struct irp_status {
	uint8_t flags;
	uint16_t battery_mv;
	uint8_t queue_free;
	uint8_t last_error;
	uint16_t uptime_min;
	uint8_t caps;
};

void irp_status_encode(const struct irp_status *s, uint8_t out[IRP_STATUS_LEN]);

/* Saturating minutes of uptime. */
uint16_t irp_uptime_min(uint64_t uptime_ms);

#endif /* IRPLAY_BRIDGE_H_ */
