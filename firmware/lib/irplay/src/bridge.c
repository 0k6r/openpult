#include <string.h>

#include "irplay/bridge.h"
#include "irplay/sirc.h"

void irp_bridge_init(struct irp_bridge *b, uint8_t caps)
{
	memset(b, 0, sizeof(*b));
	b->caps = caps;
	irp_player_init(&b->player);
}

static uint8_t stop_learning(struct irp_bridge *b)
{
	if (!b->learning) {
		return 0;
	}
	b->learning = false;
	return IRP_ACT_LEARN_STOP;
}

static uint8_t cmd_play(struct irp_bridge *b, const uint8_t *d, size_t len, uint64_t now_us,
			unsigned int *actions)
{
	bool complete;
	int err;

	if (len < 4 || d[2] == 0) {
		irp_frag_reset(&b->frag);
		return IRP_ERR_MALFORMED;
	}
	err = irp_frag_push(&b->frag, d[2], d[3], &d[4], len - 4, now_us, &complete);
	if (err || !complete) {
		return (uint8_t)err;
	}
	err = irp_blob_parse(b->frag.buf, b->frag.len, &b->scratch);
	if (!err) {
		err = irp_player_play(&b->player, &b->scratch, d[2]);
	}
	if (err) {
		return (uint8_t)err;
	}
	*actions |= IRP_ACT_PLAYER | stop_learning(b);
	return IRP_OK;
}

static uint8_t cmd_send(struct irp_bridge *b, const uint8_t *d, size_t len, uint64_t now_us,
			unsigned int *actions)
{
	uint8_t bits, cmd, frames;
	uint16_t dev;
	uint32_t key;
	int err;

	if (len != 7 || d[5] > 0x7F) {
		return IRP_ERR_MALFORMED;
	}
	bits = d[2];
	dev = (uint16_t)(d[3] | (d[4] << 8));
	cmd = d[5];
	frames = d[6] ? d[6] : IRP_SIRC_FRAMES_DEFAULT;
	if (frames < IRP_SIRC_FRAMES_MIN) {
		frames = IRP_SIRC_FRAMES_MIN;
	} else if (frames > IRP_SIRC_FRAMES_MAX) {
		frames = IRP_SIRC_FRAMES_MAX;
	}
	if (!irp_sirc_bits_valid(bits)) {
		return IRP_ERR_SIRC_BITS;
	}

	key = irp_sirc_key(bits, dev, cmd);
	if ((d[1] & 0x01) && irp_player_hold(&b->player, key, frames, now_us) == IRP_OK) {
		*actions |= IRP_ACT_PLAYER | stop_learning(b);
		return IRP_OK;
	}
	err = irp_sirc_signal(bits, dev, cmd, frames, &b->scratch);
	if (!err) {
		err = irp_player_play(&b->player, &b->scratch, key);
	}
	if (err) {
		return (uint8_t)err;
	}
	*actions |= IRP_ACT_PLAYER | stop_learning(b);
	return IRP_OK;
}

static uint8_t handle(struct irp_bridge *b, const uint8_t *d, size_t len, uint64_t now_us,
		      unsigned int *actions)
{
	if (len == 0) {
		return IRP_ERR_MALFORMED;
	}

	switch (d[0]) {
	case IRP_OP_PLAY:
		return cmd_play(b, d, len, now_us, actions);

	case IRP_OP_HOLD:
		if (len != 3 || d[1] == 0) {
			return IRP_ERR_MALFORMED;
		}
		if (irp_player_hold(&b->player, d[1], d[2], now_us) != IRP_OK) {
			return IRP_ERR_NO_HOLD;
		}
		*actions |= IRP_ACT_PLAYER | stop_learning(b);
		return IRP_OK;

	case IRP_OP_STOP:
		if (len != 1) {
			return IRP_ERR_MALFORMED;
		}
		irp_player_stop(&b->player);
		irp_frag_reset(&b->frag);
		*actions |= IRP_ACT_PLAYER | stop_learning(b);
		return IRP_OK;

	case IRP_OP_LEARN_START: {
		uint8_t timeout_s = len == 2 && d[1] ? d[1] : IRP_LEARN_TIMEOUT_DEFAULT_S;

		if (len != 2 || timeout_s > IRP_LEARN_TIMEOUT_MAX_S) {
			return IRP_ERR_MALFORMED;
		}
		if (!(b->caps & IRP_CAP_LEARN)) {
			return IRP_ERR_NOT_AVAILABLE;
		}
		b->learning = true;
		b->learn_timeout_s = timeout_s;
		*actions |= IRP_ACT_LEARN_START;
		return IRP_OK;
	}

	case IRP_OP_LEARN_STOP:
		if (len != 1) {
			return IRP_ERR_MALFORMED;
		}
		if (!(b->caps & IRP_CAP_LEARN)) {
			return IRP_ERR_NOT_AVAILABLE;
		}
		*actions |= stop_learning(b);
		return IRP_OK;

	case IRP_OP_ENTER_BOOTLOADER:
		if (len != 3 || d[1] != 0x55 || d[2] != 0xAA) {
			return IRP_ERR_MALFORMED;
		}
		if (!(b->caps & IRP_CAP_UF2)) {
			return IRP_ERR_NOT_AVAILABLE;
		}
		*actions |= IRP_ACT_BOOTLOADER;
		return IRP_OK;

	case IRP_OP_SEND:
		return cmd_send(b, d, len, now_us, actions);

	default:
		return IRP_ERR_MALFORMED;
	}
}

uint8_t irp_bridge_command(struct irp_bridge *b, const uint8_t *data, size_t len,
			   uint64_t now_us, unsigned int *actions)
{
	*actions = 0;
	b->last_error = handle(b, data, len, now_us, actions);
	return b->last_error;
}

void irp_bridge_learn_done(struct irp_bridge *b)
{
	b->learning = false;
}

void irp_status_encode(const struct irp_status *s, uint8_t out[IRP_STATUS_LEN])
{
	out[0] = IRP_PROTO_VERSION;
	out[1] = s->flags;
	out[2] = (uint8_t)s->battery_mv;
	out[3] = (uint8_t)(s->battery_mv >> 8);
	out[4] = s->queue_free;
	out[5] = s->last_error;
	out[6] = (uint8_t)s->uptime_min;
	out[7] = (uint8_t)(s->uptime_min >> 8);
	out[8] = s->caps;
	out[9] = (uint8_t)IRP_BLOB_MAX;
	out[10] = (uint8_t)(IRP_BLOB_MAX >> 8);
	out[11] = 0;
}

uint16_t irp_uptime_min(uint64_t uptime_ms)
{
	uint64_t min = uptime_ms / 60000u;

	return min > UINT16_MAX ? UINT16_MAX : (uint16_t)min;
}
