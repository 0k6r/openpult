#include "test.h"
#include "vectors.h"
#include "irplay/wave.h"

#define CLOCK_HZ 16000000u
#define TICKS_PER_US 16u
#define MARK 0x8085u
#define SPACE 0x8000u

static struct irp_signal sig;
static uint16_t out[70000]; /* a 1 s section at 65.5 kHz */

static size_t render(const struct irp_signal *s, enum irp_section sec, uint32_t top, size_t chunk)
{
	struct irp_wave w;
	size_t n = 0, k;

	irp_wave_init(&w, s, sec, TICKS_PER_US, top, MARK, SPACE);
	do {
		k = irp_wave_fill(&w, &out[n], chunk);
		n += k;
	} while (k == chunk);
	CHECK(w.finished);
	return n;
}

/*
 * Independent check: a carrier period lying entirely (with one period of margin on
 * both sides) inside a mark must be a mark value, inside a space a space value; so
 * every edge is within one period of its ideal time, with no drift along the
 * section. Symbols shorter than a period may vanish.
 */
static void check_edges(const struct irp_signal *s, enum irp_section sec, uint32_t top, size_t n)
{
	static uint64_t edge[IRP_SYMBOLS_MAX + 1]; /* cumulative ends, in 16 MHz ticks */
	uint16_t count = s->count[sec];
	uint16_t i = 0;

	edge[0] = 0;
	for (uint16_t k = 0; k < count; k++) {
		edge[k + 1] = edge[k] + (uint64_t)irp_duration(s, sec, k) * TICKS_PER_US;
	}
	CHECK_EQ(n, (edge[count] + top / 2) / top + (out[n - 1] == SPACE ? 0 : 1));

	for (size_t p = 0; p < n; p++) {
		uint64_t lo = p * top, hi = (p + 1) * top;

		if (lo < top || hi + top > edge[count]) {
			continue;
		}
		while (i < count && edge[i + 1] <= lo - top) {
			i++;
		}
		if (edge[i + 1] >= hi + top) { /* window inside symbol i */
			CHECK_EQ(out[p], i % 2 == 0 ? MARK : SPACE);
		}
	}
	CHECK_EQ(out[n - 1], SPACE);
}

static void test_vectors_quantised(void)
{
	for (size_t k = 0; k < VEC_COUNT(vec_signals); k++) {
		const struct vec_signal *v = &vec_signals[k];
		uint32_t top = irp_wave_period_ticks(CLOCK_HZ, v->carrier_hz);

		CHECK_EQ(irp_blob_parse(v->blob, v->blob_len, &sig), IRP_OK);
		for (int sec = IRP_INTRO; sec <= IRP_REPEAT; sec++) {
			if (sig.count[sec] == 0) {
				continue;
			}
			size_t n = render(&sig, (enum irp_section)sec, top, sizeof(out) / sizeof(out[0]));

			check_edges(&sig, (enum irp_section)sec, top, n);
		}
	}
}

static void test_sony_exact_at_40khz(void)
{
	/* 600 us = 24 periods of 25 us exactly */
	const struct vec_signal *v = &vec_signals[0];
	uint32_t top = irp_wave_period_ticks(CLOCK_HZ, 40000);
	size_t n, pos = 0;

	CHECK_EQ(top, 400);
	irp_blob_parse(v->blob, v->blob_len, &sig);
	n = render(&sig, IRP_REPEAT, top, 1u << 16);
	CHECK_EQ(n, 45000 / 25);
	for (uint16_t i = 0; i < v->repeat_n; i++) {
		for (uint32_t p = 0; p < v->repeat[i] / 25; p++) {
			CHECK_EQ(out[pos++], i % 2 == 0 ? MARK : SPACE);
		}
	}
}

static void test_chunking_is_transparent(void)
{
	static uint16_t whole[8192];
	const struct vec_signal *v = &vec_signals[1];
	uint32_t top = irp_wave_period_ticks(CLOCK_HZ, v->carrier_hz);
	size_t n_whole, chunks[] = {1, 7, 100, 2048};

	irp_blob_parse(v->blob, v->blob_len, &sig);
	n_whole = render(&sig, IRP_INTRO, top, sizeof(whole) / sizeof(whole[0]));
	memcpy(whole, out, n_whole * sizeof(whole[0]));
	for (size_t c = 0; c < sizeof(chunks) / sizeof(chunks[0]); c++) {
		CHECK_EQ(render(&sig, IRP_INTRO, top, chunks[c]), n_whole);
		CHECK_MEM(out, whole, n_whole * sizeof(whole[0]));
	}
}

static void test_exact_chunk_boundary(void)
{
	/* section of exactly 8 periods, filled in chunks of 8: the second call returns 0 */
	const uint32_t d[] = {100, 100};
	struct irp_wave w;
	uint16_t buf[8];

	CHECK_EQ(irp_signal_build(&sig, 40000, 33, 0, NULL, 0, d, 2), IRP_OK);
	irp_wave_init(&w, &sig, IRP_REPEAT, TICKS_PER_US, 400, MARK, SPACE);
	CHECK_EQ(irp_wave_fill(&w, buf, 8), 8);
	CHECK(!w.finished);
	CHECK_EQ(irp_wave_fill(&w, buf, 8), 0);
	CHECK(w.finished);
}

static void test_vanishing_trailing_space(void)
{
	/* 5 us space at 25 us periods rounds away; a space is still appended */
	const uint32_t d[] = {100, 5};
	struct irp_wave w;
	uint16_t buf[16];

	CHECK_EQ(irp_signal_build(&sig, 40000, 33, 0, NULL, 0, d, 2), IRP_OK);
	irp_wave_init(&w, &sig, IRP_REPEAT, TICKS_PER_US, 400, MARK, SPACE);
	CHECK_EQ(irp_wave_fill(&w, buf, 16), 5);
	CHECK_EQ(buf[3], MARK);
	CHECK_EQ(buf[4], SPACE);
}

static void test_period_ticks(void)
{
	CHECK_EQ(irp_wave_period_ticks(CLOCK_HZ, 38000), 421);
	CHECK_EQ(irp_wave_period_ticks(CLOCK_HZ, 20000), 800);
	CHECK_EQ(irp_wave_period_ticks(CLOCK_HZ, 65535), 244);
}

TEST_MAIN({
	RUN(test_vectors_quantised);
	RUN(test_sony_exact_at_40khz);
	RUN(test_chunking_is_transparent);
	RUN(test_exact_chunk_boundary);
	RUN(test_vanishing_trailing_space);
	RUN(test_period_ticks);
})
