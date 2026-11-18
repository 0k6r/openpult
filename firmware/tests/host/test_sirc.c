#include "test.h"
#include "vectors.h"
#include "irplay/bridge.h"
#include "irplay/sirc.h"

static void test_reference_values(void)
{
	for (size_t k = 0; k < VEC_COUNT(vec_sirc); k++) {
		const struct vec_sirc *v = &vec_sirc[k];

		CHECK_EQ(irp_sirc_value(v->bits, v->device, v->command), v->value);
	}
}

static void test_matches_play_vector(void)
{
	const struct vec_signal *v = &vec_signals[0];
	struct irp_signal sig;
	uint8_t blob[IRP_BLOB_MAX];

	CHECK(strcmp(v->name, "sony-power-sirc12") == 0);
	CHECK_EQ(irp_sirc_signal(12, 1, 21, 3, &sig), IRP_OK);
	CHECK_EQ(sig.carrier_hz, v->carrier_hz);
	CHECK_EQ(sig.duty_pct, v->duty_pct);
	CHECK_EQ(sig.min_repeats, v->min_repeats);
	CHECK_EQ(sig.count[IRP_INTRO], 0);
	CHECK_EQ(sig.count[IRP_REPEAT], v->repeat_n);
	for (uint16_t i = 0; i < v->repeat_n; i++) {
		CHECK_EQ(irp_duration(&sig, IRP_REPEAT, i), v->repeat[i]);
	}
	CHECK_EQ(sig.section_us[IRP_REPEAT], IRP_SIRC_PERIOD_US);
	CHECK_EQ(irp_blob_encode(&sig, blob, sizeof(blob)), v->blob_len);
	CHECK_MEM(blob, v->blob, v->blob_len);
}

/* The legacy command queues the same signal as the PLAY vector. */
static void test_legacy_send_through_bridge(void)
{
	static struct irp_bridge b;
	const uint8_t send[] = {0x01, 0x00, 12, 1, 0, 21, 0};
	struct irp_signal ref;
	unsigned int act;

	irp_bridge_init(&b, IRP_CAP_PLAY | IRP_CAP_SEND);
	CHECK_EQ(irp_bridge_command(&b, send, sizeof(send), 0, &act), IRP_OK);
	CHECK(act & IRP_ACT_PLAYER);
	irp_blob_parse(vec_signals[0].blob, vec_signals[0].blob_len, &ref);
	CHECK_EQ(b.player.count, 1);
	CHECK_MEM(b.player.pending[0].sig.symbols, ref.symbols, sizeof(ref.symbols));
	CHECK_MEM(b.player.pending[0].sig.table, ref.table, sizeof(ref.table));
	CHECK_EQ(b.player.pending[0].sig.min_repeats, 3); /* frames 0 => 3 */
}

static void test_all_ones_20bit(void)
{
	struct irp_signal sig;

	CHECK_EQ(irp_sirc_signal(20, 0x1FFF, 127, 3, &sig), IRP_OK);
	CHECK_EQ(irp_sirc_value(20, 0x1FFF, 127), 0xFFFFF);
	CHECK_EQ(sig.count[IRP_REPEAT], 2 + 2 * 20);
	CHECK_EQ(sig.section_us[IRP_REPEAT], IRP_SIRC_PERIOD_US);
	/* last space still leaves a gap: 45000 - (2400 + 20 * 1800) */
	CHECK_EQ(irp_duration(&sig, IRP_REPEAT, 41), 6600);
}

static void test_20bit_order(void)
{
	const uint8_t device5 = 0x1A, extended8 = 0x96, cmd = 0x55;
	uint32_t expected = 0;

	for (int i = 0; i < 7; i++) {
		expected = (expected << 1) | ((cmd >> i) & 1u);
	}
	for (int i = 0; i < 5; i++) {
		expected = (expected << 1) | ((device5 >> i) & 1u);
	}
	for (int i = 0; i < 8; i++) {
		expected = (expected << 1) | ((extended8 >> i) & 1u);
	}
	CHECK_EQ(irp_sirc_value(20, (uint16_t)(device5 | (extended8 << 5)), cmd), expected);
}

static void test_bits_and_keys(void)
{
	struct irp_signal sig;

	CHECK_EQ(irp_sirc_signal(13, 1, 1, 3, &sig), IRP_ERR_SIRC_BITS);
	CHECK(!irp_sirc_bits_valid(0));
	CHECK_EQ(irp_sirc_value(12, 0xE1, 21), irp_sirc_value(12, 0x01, 21));
	CHECK_EQ(irp_sirc_key(12, 0xE1, 21), irp_sirc_key(12, 0x01, 21));
	CHECK(irp_sirc_key(12, 1, 21) != irp_sirc_key(15, 1, 21));
	CHECK(irp_sirc_key(12, 1, 21) > 0xFF);
}

TEST_MAIN({
	RUN(test_reference_values);
	RUN(test_matches_play_vector);
	RUN(test_legacy_send_through_bridge);
	RUN(test_all_ones_20bit);
	RUN(test_20bit_order);
	RUN(test_bits_and_keys);
})
