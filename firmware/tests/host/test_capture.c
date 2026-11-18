#include "test.h"
#include "vectors.h"
#include "irplay/capture.h"
#include "irplay/signal.h"

static struct irp_capture c;
static uint32_t t;

/* Feeds a mark/space list as edges starting at t (the first edge starts a mark). */
static void feed(const uint32_t *d, size_t n)
{
	irp_capture_edge(&c, t);
	for (size_t i = 0; i < n; i++) {
		t += d[i];
		irp_capture_edge(&c, t);
	}
}

static void test_nec_frame_and_repeat(void)
{
	const struct vec_signal *v = &vec_signals[1];

	irp_capture_reset(&c);
	t = 0xFFFF0000u; /* crosses the 32-bit wrap */
	/* intro frame, its gap, the repeat code: all within one capture */
	feed(v->intro, v->intro_n - 1);
	t += v->intro[v->intro_n - 1];
	irp_capture_edge(&c, t);
	for (uint16_t i = 0; i + 1 < v->repeat_n; i++) {
		t += v->repeat[i];
		irp_capture_edge(&c, t);
	}
	CHECK(!irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US));
	CHECK(irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 1));
	CHECK(c.done);
	CHECK_EQ(c.flags, 0);
	CHECK_EQ(c.count, v->intro_n + v->repeat_n - 1);
	for (uint16_t i = 0; i < v->intro_n; i++) {
		CHECK_EQ(c.durations[i], v->intro[i]);
	}
	for (uint16_t i = 0; i + 1 < v->repeat_n; i++) {
		CHECK_EQ(c.durations[v->intro_n + i], v->repeat[i]);
	}
	CHECK_EQ(c.count % 2, 1); /* ends with a mark */
}

static void test_noise_ignored(void)
{
	const uint32_t noise[] = {300, 200, 400};
	const uint32_t sig[] = {9000, 4500, 560, 560, 560, 1690, 560};

	irp_capture_reset(&c);
	t = 1000;
	feed(noise, 3); /* mark, space, mark, back to idle: 3 durations */
	CHECK(!irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 5000));
	CHECK(!c.done);
	t += IRP_CAPTURE_END_SPACE_US + 10000;
	feed(sig, 7);
	CHECK(irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 1));
	CHECK_EQ(c.count, 7);
	CHECK_EQ(c.durations[0], 9000);
}

static void test_long_space_ends_at_next_edge(void)
{
	const uint32_t sig[] = {9000, 4500, 560, 560, 560, 1690, 560};

	irp_capture_reset(&c);
	t = 0;
	feed(sig, 7);
	t += IRP_CAPTURE_END_SPACE_US + 50;
	irp_capture_edge(&c, t); /* poll was missed; the gap is detected here */
	CHECK(c.done);
	CHECK_EQ(c.count, 7);
}

static void test_limits(void)
{
	irp_capture_reset(&c);
	t = 0;
	irp_capture_edge(&c, t);
	for (unsigned int i = 0; i < IRP_CAPTURE_MAX + 10; i++) {
		t += 500;
		irp_capture_edge(&c, t);
	}
	CHECK(c.done);
	CHECK_EQ(c.count, IRP_CAPTURE_MAX);
	CHECK_EQ(c.flags, IRP_CAPTURE_TRUNCATED);

	irp_capture_reset(&c);
	t = 0;
	irp_capture_edge(&c, t);
	for (unsigned int i = 0; i < 300; i++) {
		t += 5000; /* 1.5 s of 5 ms durations */
		irp_capture_edge(&c, t);
	}
	CHECK(c.done);
	CHECK_EQ(c.flags, IRP_CAPTURE_TRUNCATED);
	CHECK_EQ(c.count, IRP_CAPTURE_MAX_US / 5000 - 1);

	irp_capture_reset(&c);
	CHECK(!irp_capture_poll(&c, 123456)); /* nothing received */
}

static size_t decode_all(uint8_t frags[][32], const size_t *lens, size_t n, uint8_t *flags,
			 uint32_t *out)
{
	size_t count = 0;

	for (size_t f = 0; f < n; f++) {
		size_t pos = 2;

		CHECK_EQ(frags[f][0], 7);
		CHECK_EQ(frags[f][1] & 0x7F, f);
		CHECK_EQ((frags[f][1] & 0x80) != 0, f + 1 == n);
		if (f == 0) {
			*flags = frags[f][2];
			pos = 5;
		}
		while (pos < lens[f]) {
			size_t k = irp_varint_decode(&frags[f][pos], lens[f] - pos, &out[count]);

			CHECK(k > 0);
			if (k == 0) {
				break;
			}
			pos += k;
			count++;
		}
	}
	return count;
}

static void test_encoding_roundtrip(void)
{
	const struct vec_signal *v = &vec_signals[1];
	uint8_t frags[64][32];
	size_t lens[64], n = 0;
	uint16_t pos = 0;
	bool last = false;
	uint32_t back[IRP_CAPTURE_MAX];
	uint8_t flags;

	while (!last) {
		lens[n] = irp_capture_fragment(v->intro, v->intro_n, 0, 7, (uint8_t)n, &pos,
					       frags[n], 20, &last);
		CHECK(lens[n] > 0 && lens[n] <= 20);
		if (lens[n] == 0) {
			return;
		}
		n++;
	}
	CHECK(n > 1);
	CHECK_EQ(frags[0][3] | (frags[0][4] << 8), v->intro_n);
	CHECK_EQ(decode_all(frags, lens, n, &flags, back), v->intro_n);
	CHECK_EQ(flags, 0);
	CHECK_MEM(back, v->intro, v->intro_n * sizeof(uint32_t));
}

static void test_encoding_timeout_and_sizes(void)
{
	uint8_t out[244];
	uint16_t pos = 0;
	bool last = false;
	const uint32_t big[] = {1000000, 130001, 1};

	CHECK_EQ(irp_capture_fragment(NULL, 0, IRP_CAPTURE_TIMEOUT, 3, 0, &pos, out, 20, &last), 5);
	CHECK(last);
	CHECK_EQ(out[0], 3);
	CHECK_EQ(out[1], 0x80);
	CHECK_EQ(out[2], IRP_CAPTURE_TIMEOUT);
	CHECK_EQ(out[3], 0);
	CHECK_EQ(out[4], 0);

	pos = 0;
	CHECK_EQ(irp_capture_fragment(big, 3, 0, 1, 0, &pos, out, 244, &last), 5 + 3 + 3 + 1);
	CHECK(last);
	/* no room for even one varint */
	pos = 0;
	CHECK_EQ(irp_capture_fragment(big, 3, 0, 1, 0, &pos, out, 7, &last), 0);
}

static void test_polarity_after_discarded_noise(void)
{
	const uint32_t sig[] = {9000, 4500, 560, 560, 560, 1690, 560};

	/* a stuck-low burst: mark, space, then a mark lasting past the 1 s limit */
	irp_capture_reset(&c);
	t = 0;
	irp_capture_edge(&c, t);
	irp_capture_edge(&c, t += 100000);
	irp_capture_edge(&c, t += 100000);
	CHECK(!irp_capture_poll(&c, t + 900000)); /* 2 durations: noise, dropped */
	CHECK(!c.started);
	irp_capture_edge(&c, t += 1000000); /* end of the long mark: not a start */
	CHECK(!c.started);
	t += 200000;
	feed(sig, 7);
	CHECK(irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 1));
	CHECK_EQ(c.count, 7);
	CHECK_EQ(c.durations[0], 9000);
	CHECK_EQ(c.durations[1], 4500);
}

static void test_edges_after_done_ignored(void)
{
	const uint32_t sig[] = {9000, 4500, 560, 560, 560, 1690, 560};

	irp_capture_reset(&c);
	t = 0;
	feed(sig, 7);
	CHECK(irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 1));
	irp_capture_edge(&c, t + 200000);
	irp_capture_edge(&c, t + 201000);
	CHECK_EQ(c.count, 7);
	CHECK(c.done);
}

static void test_one_second_limit_by_poll(void)
{
	irp_capture_reset(&c);
	t = 0;
	irp_capture_edge(&c, t);
	for (int i = 0; i < 9; i++) {
		irp_capture_edge(&c, t += 1000);
	}
	/* still in a space: ends normally after 130 ms; keep it a mark instead */
	irp_capture_edge(&c, t += 1000);
	CHECK(!irp_capture_poll(&c, IRP_CAPTURE_MAX_US - 1));
	CHECK(irp_capture_poll(&c, IRP_CAPTURE_MAX_US));
	CHECK_EQ(c.flags, IRP_CAPTURE_TRUNCATED);
	CHECK_EQ(c.count, 10);
}

static void test_start_while_receiving(void)
{
	const uint32_t sig[] = {9000, 4500, 560, 560, 560, 1690, 560};

	/* capture armed while the remote is already sending: output active */
	irp_capture_reset(&c);
	irp_capture_set_level(&c, true);
	t = 0;
	irp_capture_edge(&c, t += 300); /* end of a mark: not a start */
	CHECK(!c.started);
	t += 200000;
	feed(sig, 7);
	CHECK(irp_capture_poll(&c, t + IRP_CAPTURE_END_SPACE_US + 1));
	CHECK_EQ(c.count, 7);
	CHECK_EQ(c.durations[0], 9000);
}

TEST_MAIN({
	RUN(test_start_while_receiving);
	RUN(test_polarity_after_discarded_noise);
	RUN(test_edges_after_done_ignored);
	RUN(test_one_second_limit_by_poll);
	RUN(test_nec_frame_and_repeat);
	RUN(test_noise_ignored);
	RUN(test_long_space_ends_at_next_edge);
	RUN(test_limits);
	RUN(test_encoding_roundtrip);
	RUN(test_encoding_timeout_and_sizes);
})
