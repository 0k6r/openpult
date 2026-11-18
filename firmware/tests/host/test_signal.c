#include "test.h"
#include "vectors.h"
#include "irplay/signal.h"

static struct irp_signal sig;

static void check_sections(const struct irp_signal *s, const struct vec_signal *v)
{
	CHECK_EQ(s->carrier_hz, v->carrier_hz);
	CHECK_EQ(s->duty_pct, v->duty_pct);
	CHECK_EQ(s->min_repeats, v->min_repeats);
	CHECK_EQ(s->count[IRP_INTRO], v->intro_n);
	CHECK_EQ(s->count[IRP_REPEAT], v->repeat_n);
	for (uint16_t i = 0; i < v->intro_n && i < s->count[IRP_INTRO]; i++) {
		CHECK_EQ(irp_duration(s, IRP_INTRO, i), v->intro[i]);
	}
	for (uint16_t i = 0; i < v->repeat_n && i < s->count[IRP_REPEAT]; i++) {
		CHECK_EQ(irp_duration(s, IRP_REPEAT, i), v->repeat[i]);
	}
}

static void test_parse_vectors(void)
{
	for (size_t k = 0; k < VEC_COUNT(vec_signals); k++) {
		const struct vec_signal *v = &vec_signals[k];
		uint32_t sum = 0;

		CHECK_EQ(irp_blob_parse(v->blob, v->blob_len, &sig), IRP_OK);
		check_sections(&sig, v);
		CHECK_EQ(sig.table_n, v->table_n);
		CHECK_MEM(sig.table, v->table, v->table_n * sizeof(uint32_t));
		CHECK_EQ(sig.blob_len, v->blob_len);
		for (uint16_t i = 0; i < v->repeat_n; i++) {
			sum += v->repeat[i];
		}
		CHECK_EQ(sig.section_us[IRP_REPEAT], sum);
	}
}

static void test_build_encodes_like_the_app(void)
{
	uint8_t out[IRP_BLOB_MAX];

	for (size_t k = 0; k < VEC_COUNT(vec_signals); k++) {
		const struct vec_signal *v = &vec_signals[k];

		CHECK_EQ(irp_signal_build(&sig, v->carrier_hz, v->duty_pct, v->min_repeats, v->intro,
					  v->intro_n, v->repeat, v->repeat_n),
			 IRP_OK);
		CHECK_EQ(sig.blob_len, v->blob_len);
		CHECK_EQ(irp_blob_encode(&sig, out, sizeof(out)), v->blob_len);
		CHECK_MEM(out, v->blob, v->blob_len);
	}
}

static void test_reference_sony_power(void)
{
	/* PROTOCOL.md: Sony Power as PLAY, 35 bytes with the 4-byte PLAY header. */
	const struct vec_signal *v = &vec_signals[0];

	CHECK(strcmp(v->name, "sony-power-sirc12") == 0);
	CHECK_EQ(v->play_n, 1);
	CHECK_EQ(v->play[0].len, 35);
	CHECK_EQ(v->blob_len, 31);
}

static void test_varint(void)
{
	uint8_t buf[8];
	uint32_t v;

	CHECK_EQ(irp_varint_encode(25800, buf, sizeof(buf)), 3);
	CHECK_EQ(buf[0], 0xC8);
	CHECK_EQ(buf[1], 0xC9);
	CHECK_EQ(buf[2], 0x01);
	CHECK_EQ(irp_varint_decode(buf, 3, &v), 3);
	CHECK_EQ(v, 25800);
	CHECK_EQ(irp_varint_decode(buf, 2, &v), 0); /* truncated */
	CHECK_EQ(irp_varint_encode(127, buf, 1), 1);
	CHECK_EQ(irp_varint_encode(128, buf, 1), 0);

	const uint8_t too_long[] = {0x80, 0x80, 0x80, 0x80, 0x80, 0x01};
	const uint8_t overflow[] = {0xFF, 0xFF, 0xFF, 0xFF, 0x1F};

	CHECK_EQ(irp_varint_decode(too_long, sizeof(too_long), &v), 0);
	CHECK_EQ(irp_varint_decode(overflow, sizeof(overflow), &v), 0);
	const uint8_t max32[] = {0xFF, 0xFF, 0xFF, 0xFF, 0x0F};

	CHECK_EQ(irp_varint_decode(max32, sizeof(max32), &v), 5);
	CHECK_EQ(v, UINT32_MAX);
}

/* Blob of the Sony vector with one header byte changed. */
static int parse_patched(size_t off, uint8_t value)
{
	uint8_t blob[IRP_BLOB_MAX];
	const struct vec_signal *v = &vec_signals[0];

	memcpy(blob, v->blob, v->blob_len);
	blob[off] = value;
	return irp_blob_parse(blob, v->blob_len, &sig);
}

static int build(uint16_t carrier, uint8_t duty, uint8_t min_repeats, const uint32_t *intro,
		 uint16_t intro_n, const uint32_t *repeat, uint16_t repeat_n)
{
	return irp_signal_build(&sig, carrier, duty, min_repeats, intro, intro_n, repeat, repeat_n);
}

static void test_limits(void)
{
	const uint32_t ok[] = {500, 1000};
	const uint32_t long_mark[] = {30001, 1000};
	const uint32_t max_mark[] = {30000, 1000};
	const uint32_t long_space[] = {100, 500001};
	const uint32_t zero[] = {0, 100};
	uint32_t many[18];

	CHECK_EQ(build(38000, 33, 0, NULL, 0, ok, 2), IRP_OK);
	CHECK_EQ(build(20000, 10, 20, NULL, 0, ok, 2), IRP_OK);
	CHECK_EQ(build(65535, 50, 0, ok, 2, NULL, 0), IRP_OK);
	CHECK_EQ(build(19999, 33, 0, NULL, 0, ok, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 9, 0, NULL, 0, ok, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 51, 0, NULL, 0, ok, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 0, 0, NULL, 0, ok, 2), IRP_OK); /* 0 => 33 */
	CHECK_EQ(sig.duty_pct, 33);
	CHECK_EQ(build(38000, 33, 21, NULL, 0, ok, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, long_mark, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, max_mark, 2), IRP_OK);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, long_space, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, zero, 2), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, ok, 0), IRP_ERR_UNSUPPORTED); /* < 2 symbols */
	CHECK_EQ(build(38000, 33, 0, ok, 1, ok, 1), IRP_ERR_UNSUPPORTED);   /* odd counts */

	for (int i = 0; i < 18; i++) {
		many[i] = (uint32_t)(100 + i);
	}
	CHECK_EQ(build(38000, 33, 0, NULL, 0, many, 16), IRP_OK);
	CHECK_EQ(build(38000, 33, 0, NULL, 0, many, 18), IRP_ERR_UNSUPPORTED); /* 17 distinct */
}

static void test_section_and_symbol_limits(void)
{
	static uint32_t d[1026];

	/* 1 s section: 500 x (1000 + 1000) us */
	for (int i = 0; i < 1000; i++) {
		d[i] = 1000;
	}
	CHECK_EQ(build(38000, 33, 0, NULL, 0, d, 1000), IRP_OK);
	CHECK_EQ(sig.section_us[IRP_REPEAT], 1000000);
	d[999] = 1001;
	CHECK_EQ(build(38000, 33, 0, NULL, 0, d, 1000), IRP_ERR_UNSUPPORTED);

	for (int i = 0; i < 1026; i++) {
		d[i] = 100;
	}
	CHECK_EQ(build(38000, 33, 0, d, 512, d, 512), IRP_OK);
	CHECK_EQ(build(38000, 33, 0, d, 514, d, 512), IRP_ERR_UNSUPPORTED);
	CHECK(sig.blob_len <= IRP_BLOB_MAX);
}

static void test_blob_size(void)
{
	static uint32_t d[1024];
	uint8_t blob[IRP_BLOB_MAX + 1];

	/* A large valid signal: 1024 symbols over 16 two-byte table entries. Canonical
	 * blobs stay below 576 bytes (three-byte entries are >= 16.4 ms, so only a few fit
	 * within the 1 s section limit); the limit only matters for padded varints. */
	for (int i = 0; i < 1024; i++) {
		d[i] = 128u + (uint32_t)(i % 16);
	}
	CHECK_EQ(build(38000, 33, 0, d, 512, d, 512), IRP_OK);
	CHECK_EQ(sig.blob_len, 9 + 16 * 2 + 512);
	CHECK_EQ(irp_blob_encode(&sig, blob, sizeof(blob)), sig.blob_len);
	CHECK_EQ(irp_blob_parse(blob, sig.blob_len, &sig), IRP_OK);

	/* odd counts at the 1024-symbol boundary must not overrun the symbol buffer */
	CHECK_EQ(build(38000, 33, 0, d, 1, d, 1023), IRP_ERR_UNSUPPORTED);
	memset(blob, 0, sizeof(blob));
	blob[0] = 0x40;
	blob[1] = 0x9C;
	blob[4] = 1;
	blob[5] = 1;            /* intro_n = 1 */
	blob[7] = 0xFF;
	blob[8] = 0x03;         /* repeat_n = 1023 */
	blob[9] = 100;
	CHECK_EQ(irp_blob_parse(blob, 10 + 1 + 512, &sig), IRP_ERR_UNSUPPORTED);

	/* padded (overlong) varints are valid LEB128 and accepted */
	const uint8_t padded[] = {0x40, 0x9C, 33, 0, 1, 0, 0, 2, 0, 0xE4, 0x80, 0x80, 0x00, 0x00};

	CHECK_EQ(irp_blob_parse(padded, sizeof(padded), &sig), IRP_OK);
	CHECK_EQ(sig.table[0], 100);

	/* Longer blobs are only possible with padded varints; rejected by size. */
	memset(blob, 0, sizeof(blob));
	CHECK_EQ(irp_blob_parse(blob, IRP_BLOB_MAX + 1, &sig), IRP_ERR_UNSUPPORTED);
}

static void test_malformed_blobs(void)
{
	const struct vec_signal *v = &vec_signals[0];
	uint8_t blob[IRP_BLOB_MAX];

	CHECK_EQ(irp_blob_parse(v->blob, 8, &sig), IRP_ERR_UNSUPPORTED);
	CHECK_EQ(irp_blob_parse(v->blob, v->blob_len - 1, &sig), IRP_ERR_UNSUPPORTED);
	memcpy(blob, v->blob, v->blob_len);
	blob[v->blob_len] = 0;
	CHECK_EQ(irp_blob_parse(blob, v->blob_len + 1u, &sig), IRP_ERR_UNSUPPORTED);

	CHECK_EQ(parse_patched(4, 0), IRP_ERR_UNSUPPORTED);   /* empty table */
	CHECK_EQ(parse_patched(4, 17), IRP_ERR_UNSUPPORTED);  /* table too large */
	CHECK_EQ(parse_patched(3, 21), IRP_ERR_UNSUPPORTED);  /* min_repeats */
	CHECK_EQ(parse_patched(2, 60), IRP_ERR_UNSUPPORTED);  /* duty */
	CHECK_EQ(parse_patched(1, 0x40), IRP_ERR_UNSUPPORTED); /* carrier 0x4040 = 16448 Hz */
	CHECK_EQ(parse_patched(7, 27), IRP_ERR_UNSUPPORTED);  /* odd repeat_n */
	CHECK_EQ(parse_patched(v->blob_len - 1, 0x14), IRP_ERR_UNSUPPORTED); /* symbol 4 >= table_n */
	CHECK_EQ(parse_patched(2, 0), IRP_OK);
	CHECK_EQ(sig.duty_pct, 33);
}

TEST_MAIN({
	RUN(test_parse_vectors);
	RUN(test_build_encodes_like_the_app);
	RUN(test_reference_sony_power);
	RUN(test_varint);
	RUN(test_limits);
	RUN(test_section_and_symbol_limits);
	RUN(test_blob_size);
	RUN(test_malformed_blobs);
})
