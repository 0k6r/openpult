#include "test.h"
#include "vectors.h"
#include "irplay/bridge.h"

#define ALL_CAPS (IRP_CAP_PLAY | IRP_CAP_LEARN | IRP_CAP_SEND | IRP_CAP_UF2)

static struct irp_bridge b;
static unsigned int act;

static uint8_t cmd(const uint8_t *d, size_t len, uint64_t now_us)
{
	return irp_bridge_command(&b, d, len, now_us, &act);
}

#define CMD(now, ...)                                                                              \
	({                                                                                         \
		const uint8_t d_[] = {__VA_ARGS__};                                                \
		cmd(d_, sizeof(d_), now);                                                          \
	})

static void check_queued(const struct irp_signal *s, const struct vec_signal *v)
{
	CHECK_EQ(s->carrier_hz, v->carrier_hz);
	CHECK_EQ(s->duty_pct, v->duty_pct);
	CHECK_EQ(s->min_repeats, v->min_repeats);
	CHECK_EQ(s->count[IRP_INTRO], v->intro_n);
	CHECK_EQ(s->count[IRP_REPEAT], v->repeat_n);
	for (uint16_t i = 0; i < v->intro_n; i++) {
		CHECK_EQ(irp_duration(s, IRP_INTRO, i), v->intro[i]);
	}
	for (uint16_t i = 0; i < v->repeat_n; i++) {
		CHECK_EQ(irp_duration(s, IRP_REPEAT, i), v->repeat[i]);
	}
}

static void play_writes(const struct vec_write *w, uint8_t n, uint64_t step_us)
{
	for (uint8_t i = 0; i < n; i++) {
		CHECK_EQ(cmd(w[i].data, w[i].len, i * step_us), IRP_OK);
		CHECK_EQ((act & IRP_ACT_PLAYER) != 0, i + 1 == n);
	}
}

static void test_play_vectors(void)
{
	for (size_t k = 0; k < VEC_COUNT(vec_signals); k++) {
		const struct vec_signal *v = &vec_signals[k];

		irp_bridge_init(&b, ALL_CAPS);
		play_writes(v->play, v->play_n, 0);
		CHECK_EQ(b.player.count, 1);
		check_queued(&b.player.pending[0].sig, v);
		CHECK_EQ(b.player.pending[0].key, 1);

		irp_bridge_init(&b, ALL_CAPS);
		CHECK(v->play_mtu23_n > 1);
		play_writes(v->play_mtu23, v->play_mtu23_n, 1900000); /* < 2 s apart */
		CHECK_EQ(b.player.count, 1);
		check_queued(&b.player.pending[0].sig, v);
		for (uint8_t i = 0; i < v->play_mtu23_n; i++) {
			CHECK(v->play_mtu23[i].len <= 20);
		}
	}
}

static void test_fragment_errors(void)
{
	const struct vec_signal *v = &vec_signals[1];
	const struct vec_write *w = v->play_mtu23;
	uint8_t buf[32];

	irp_bridge_init(&b, ALL_CAPS);
	/* skipped index */
	CHECK_EQ(cmd(w[0].data, w[0].len, 0), IRP_OK);
	CHECK_EQ(cmd(w[2].data, w[2].len, 0), IRP_ERR_MALFORMED);
	/* buffer was reset: continuing is an error too */
	CHECK_EQ(cmd(w[1].data, w[1].len, 0), IRP_ERR_MALFORMED);

	/* different sig_id */
	CHECK_EQ(cmd(w[0].data, w[0].len, 0), IRP_OK);
	memcpy(buf, w[1].data, w[1].len);
	buf[2] = 2;
	CHECK_EQ(cmd(buf, w[1].len, 0), IRP_ERR_MALFORMED);

	/* reassembly timeout */
	CHECK_EQ(cmd(w[0].data, w[0].len, 0), IRP_OK);
	CHECK_EQ(cmd(w[1].data, w[1].len, 2000001), IRP_ERR_MALFORMED);

	/* fragment 0 restarts a reassembly in progress */
	CHECK_EQ(cmd(w[0].data, w[0].len, 0), IRP_OK);
	CHECK_EQ(cmd(w[1].data, w[1].len, 0), IRP_OK);
	play_writes(w, v->play_mtu23_n, 0);
	CHECK_EQ(b.player.count, 1);

	/* header errors */
	CHECK_EQ(CMD(0, 0x10, 0x00, 0x01), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x10, 0x00, 0x00, 0x80, 0x40), IRP_ERR_MALFORMED); /* sig_id 0 */
}

static void test_blob_errors(void)
{
	uint8_t buf[IRP_WRITE_MAX];
	const struct vec_signal *v = &vec_signals[0];

	irp_bridge_init(&b, ALL_CAPS);
	memcpy(buf, v->play[0].data, v->play[0].len);
	buf[4] = 0x10;
	buf[5] = 0x27; /* 10 kHz carrier */
	CHECK_EQ(cmd(buf, v->play[0].len, 0), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(b.last_error, IRP_ERR_UNSUPPORTED);

	/* more than 576 bytes over fragments */
	memset(buf, 0, sizeof(buf));
	buf[0] = 0x10;
	buf[2] = 5;
	CHECK_EQ(cmd(buf, IRP_WRITE_MAX, 0), IRP_OK);
	buf[3] = 1;
	CHECK_EQ(cmd(buf, IRP_WRITE_MAX, 0), IRP_OK);
	buf[3] = 0x82;
	CHECK_EQ(cmd(buf, IRP_WRITE_MAX, 0), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(b.player.count, 0);
}

static void test_queue_full(void)
{
	const struct vec_write *w = vec_signals[0].play;
	uint8_t buf[64];

	irp_bridge_init(&b, ALL_CAPS);
	memcpy(buf, w[0].data, w[0].len);
	for (uint8_t i = 1; i <= IRP_QUEUE_DEPTH; i++) {
		buf[2] = i;
		CHECK_EQ(cmd(buf, w[0].len, 0), IRP_OK);
	}
	buf[2] = 9;
	CHECK_EQ(cmd(buf, w[0].len, 0), IRP_ERR_QUEUE_FULL);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 3), IRP_ERR_QUEUE_FULL);
}

static void test_hold_commands(void)
{
	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(CMD(0, 0x11, 0x01, 5), IRP_ERR_NO_HOLD);
	CHECK_EQ(b.last_error, IRP_ERR_NO_HOLD);
	CHECK_EQ(CMD(0, 0x11, 0x01), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x11, 0x00, 5), IRP_ERR_MALFORMED);

	play_writes(vec_signals[0].play, 1, 0);
	irp_player_start(&b.player);
	CHECK_EQ(CMD(0, 0x11, 0x01, 5), IRP_OK);
	CHECK(act & IRP_ACT_PLAYER);
	CHECK_EQ(b.player.units_left, 5);
	CHECK_EQ(b.last_error, 0);

	/* resume after the press finished, within the window */
	while (b.player.units_left) {
		irp_player_done(&b.player, 1000);
		if (b.player.active) {
			irp_player_start(&b.player);
		}
	}
	CHECK(!irp_player_busy(&b.player));
	CHECK_EQ(CMD(1000 + 199999, 0x11, 0x01, 3), IRP_OK);
	CHECK(irp_player_busy(&b.player));
	irp_player_stop(&b.player);
	CHECK_EQ(CMD(1000 + 1, 0x11, 0x01, 3), IRP_ERR_NO_HOLD); /* STOP ends it */
}

static void test_legacy_send(void)
{
	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(CMD(0, 0x01, 0x00, 13, 1, 0, 21, 3), IRP_ERR_SIRC_BITS);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 128, 3), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 3, 0), IRP_ERR_MALFORMED);

	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 25), IRP_OK);
	CHECK_EQ(b.player.pending[0].sig.min_repeats, 20); /* clamped */
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 1), IRP_OK);
	CHECK_EQ(b.player.pending[1].sig.min_repeats, 3);

	/* HOLD on air extends; HOLD of another code is a new press, never 0x83 */
	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 3), IRP_OK);
	irp_player_start(&b.player);
	CHECK_EQ(CMD(0, 0x01, 0x01, 12, 1, 0, 21, 5), IRP_OK);
	CHECK_EQ(b.player.units_left, 5);
	CHECK_EQ(b.player.count, 0);
	CHECK_EQ(CMD(0, 0x01, 0x01, 12, 1, 0, 18, 5), IRP_OK);
	CHECK_EQ(b.player.count, 1);
}

static void test_stop_and_learning(void)
{
	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(CMD(0, 0x02, 0x00), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x20), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x20, 61), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x21, 0x00), IRP_ERR_MALFORMED);

	CHECK_EQ(CMD(0, 0x20, 0), IRP_OK);
	CHECK(act & IRP_ACT_LEARN_START);
	CHECK(b.learning);
	CHECK_EQ(b.learn_timeout_s, 20);
	CHECK_EQ(CMD(0, 0x21), IRP_OK);
	CHECK(act & IRP_ACT_LEARN_STOP);
	CHECK(!b.learning);

	CHECK_EQ(CMD(0, 0x20, 60), IRP_OK);
	CHECK_EQ(b.learn_timeout_s, 60);
	CHECK_EQ(CMD(0, 0x02), IRP_OK);
	CHECK(act & IRP_ACT_LEARN_STOP);
	CHECK(act & IRP_ACT_PLAYER);

	CHECK_EQ(CMD(0, 0x20, 5), IRP_OK);
	play_writes(vec_signals[0].play, 1, 0);
	CHECK(!b.learning); /* PLAY ends learning */

	/* SEND and HOLD transmit too: they end learning as well */
	CHECK_EQ(CMD(0, 0x20, 5), IRP_OK);
	CHECK_EQ(CMD(0, 0x01, 0x00, 12, 1, 0, 21, 3), IRP_OK);
	CHECK(act & IRP_ACT_LEARN_STOP);
	CHECK(!b.learning);
	/* a rejected PLAY does not */
	CHECK_EQ(CMD(0, 0x20, 5), IRP_OK);
	CHECK_EQ(CMD(0, 0x10, 0x00, 0x07, 0x80, 0x00), IRP_ERR_UNSUPPORTED);
	CHECK(b.learning);
	CHECK_EQ(CMD(0, 0x20, 30), IRP_OK); /* restart with a new timeout */
	CHECK_EQ(b.learn_timeout_s, 30);
	CHECK_EQ(CMD(0, 0x02), IRP_OK);
	CHECK_EQ(CMD(0, 0x02), IRP_OK);

	/* STOP clears the queue */
	play_writes(vec_signals[0].play, 1, 0);
	CHECK_EQ(b.player.count, 1);
	CHECK_EQ(CMD(0, 0x02), IRP_OK);
	CHECK_EQ(b.player.count, 0);
}

static void test_fragment_edges(void)
{
	const struct vec_signal *v = &vec_signals[0];

	irp_bridge_init(&b, ALL_CAPS);
	/* exactly 2 s after the previous fragment is still in time */
	CHECK_EQ(cmd(v->play_mtu23[0].data, v->play_mtu23[0].len, 0), IRP_OK);
	CHECK_EQ(cmd(v->play_mtu23[1].data, v->play_mtu23[1].len, 2000000), IRP_OK);
	CHECK_EQ(b.player.count, 1);

	/* empty chunks are allowed */
	CHECK_EQ(CMD(0, 0x10, 0x00, 0x09, 0x00), IRP_OK);
	CHECK_EQ(b.frag.len, 0);

	/* at most 128 fragments */
	irp_bridge_init(&b, ALL_CAPS);
	for (unsigned int i = 0; i < 127; i++) {
		const uint8_t d[] = {0x10, 0x00, 0x09, (uint8_t)i};

		CHECK_EQ(cmd(d, sizeof(d), 0), IRP_OK);
	}
	CHECK_EQ(CMD(0, 0x10, 0x00, 0x09, 0x7F), IRP_ERR_MALFORMED);
}

static void test_not_available(void)
{
	irp_bridge_init(&b, IRP_CAP_PLAY | IRP_CAP_SEND);
	CHECK_EQ(CMD(0, 0x20, 10), IRP_ERR_NOT_AVAILABLE);
	CHECK_EQ(CMD(0, 0x21), IRP_ERR_NOT_AVAILABLE);
	CHECK_EQ(CMD(0, 0xF0, 0x55, 0xAA), IRP_ERR_NOT_AVAILABLE);
	CHECK_EQ(b.last_error, IRP_ERR_NOT_AVAILABLE);

	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(CMD(0, 0xF0, 0x55, 0xAB), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0xF0, 0x55), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0xF0, 0x55, 0xAA), IRP_OK);
	CHECK(act & IRP_ACT_BOOTLOADER);
}

static void test_malformed(void)
{
	irp_bridge_init(&b, ALL_CAPS);
	CHECK_EQ(cmd(NULL, 0, 0), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0x03), IRP_ERR_MALFORMED);
	CHECK_EQ(CMD(0, 0xFF, 0x00), IRP_ERR_MALFORMED);
	CHECK_EQ(act, 0);
}

static void test_status_encoding(void)
{
	const struct irp_status st = {
		.flags = IRP_FLAG_TRANSMITTING | IRP_FLAG_LEARNING,
		.battery_mv = 4321,
		.queue_free = 7,
		.last_error = 0x83,
		.uptime_min = 1234,
		.caps = IRP_CAP_PLAY | IRP_CAP_SEND | IRP_CAP_UF2,
	};
	const uint8_t expected[IRP_STATUS_LEN] = {2,    0x09, 0xE1, 0x10, 7, 0x83,
						  0xD2, 0x04, 0x0D, 0x40, 0x02, 0};
	uint8_t out[IRP_STATUS_LEN];

	irp_status_encode(&st, out);
	CHECK_MEM(out, expected, IRP_STATUS_LEN);

	CHECK_EQ(irp_uptime_min(0), 0);
	CHECK_EQ(irp_uptime_min(59999), 0);
	CHECK_EQ(irp_uptime_min(60000), 1);
	CHECK_EQ(irp_uptime_min(65535ull * 60000), 65535);
	CHECK_EQ(irp_uptime_min(100000ull * 60000), 65535);
}

TEST_MAIN({
	RUN(test_play_vectors);
	RUN(test_fragment_errors);
	RUN(test_blob_errors);
	RUN(test_queue_full);
	RUN(test_hold_commands);
	RUN(test_legacy_send);
	RUN(test_stop_and_learning);
	RUN(test_fragment_edges);
	RUN(test_not_available);
	RUN(test_malformed);
	RUN(test_status_encoding);
})
