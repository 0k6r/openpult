#include "test.h"
#include "vectors.h"
#include "irplay/player.h"

static struct irp_player p;
static uint64_t now;
static struct irp_signal sony, nec, intro_only;

static void setup(void)
{
	const uint32_t d[] = {9000, 4500, 560, 40000};

	irp_blob_parse(vec_signals[0].blob, vec_signals[0].blob_len, &sony); /* repeat x3, 45 ms */
	irp_blob_parse(vec_signals[1].blob, vec_signals[1].blob_len, &nec);  /* intro + 1 repeat */
	irp_signal_build(&intro_only, 38000, 33, 2, d, 4, NULL, 0);
	irp_player_init(&p);
	now = 5000000;
}

/* Plays the next unit like the transmitter: waits for not_before, then the section. */
static bool play(struct irp_unit *out)
{
	struct irp_unit u;
	uint64_t nb;

	if (!irp_player_peek(&p, &u, &nb)) {
		return false;
	}
	if (nb > now) {
		now = nb;
	}
	irp_player_start(&p);
	if (out) {
		*out = u;
		out->sig = &p.cur.sig;
	}
	now += u.sig->section_us[u.section];
	irp_player_done(&p, now);
	return true;
}

static int play_all(void)
{
	int n = 0;

	while (play(NULL)) {
		n++;
	}
	return n;
}

static void test_units_per_press(void)
{
	struct irp_unit u;

	setup();
	CHECK_EQ(irp_press_units(&sony), 3);
	CHECK_EQ(irp_press_units(&nec), 2);
	CHECK_EQ(irp_press_units(&intro_only), 2);

	CHECK_EQ(irp_player_play(&p, &nec, 1), IRP_OK);
	CHECK(play(&u));
	CHECK_EQ(u.section, IRP_INTRO);
	CHECK(play(&u));
	CHECK_EQ(u.section, IRP_REPEAT);
	CHECK(!play(NULL));

	CHECK_EQ(irp_player_play(&p, &intro_only, 2), IRP_OK);
	CHECK(play(&u));
	CHECK_EQ(u.section, IRP_INTRO);
	CHECK(play(&u));
	CHECK_EQ(u.section, IRP_INTRO);
	CHECK(!play(NULL));

	sony.min_repeats = 0; /* repeat only: max(1, min_repeats) */
	CHECK_EQ(irp_press_units(&sony), 1);
	nec.min_repeats = 0; /* intro + repeat x 0 */
	CHECK_EQ(irp_press_units(&nec), 1);
}

static void test_press_and_queue_free(void)
{
	struct irp_unit u;
	uint64_t nb;

	setup();
	CHECK(!irp_player_busy(&p));
	CHECK_EQ(irp_player_queue_free(&p), 8);
	irp_player_play(&p, &sony, 1);
	CHECK(irp_player_busy(&p));
	CHECK_EQ(irp_player_queue_free(&p), 7);
	CHECK(irp_player_peek(&p, &u, &nb));
	CHECK_EQ(nb, 0);
	irp_player_start(&p);
	CHECK_EQ(irp_player_queue_free(&p), 8);
	CHECK(!irp_player_peek(&p, &u, &nb)); /* on air */
	now += 45000;
	irp_player_done(&p, now);
	CHECK_EQ(play_all(), 2);
	CHECK(!irp_player_busy(&p));
}

static void test_gap_between_presses(void)
{
	struct irp_unit u;
	uint64_t nb, end;

	setup();
	irp_player_play(&p, &sony, 1);
	irp_player_play(&p, &nec, 2);
	for (int i = 0; i < 3; i++) {
		play(NULL);
	}
	end = now;
	CHECK(irp_player_peek(&p, &u, &nb));
	CHECK(u.sig == &p.pending[p.head].sig);
	CHECK_EQ(u.section, IRP_INTRO);
	CHECK_EQ(nb, end + IRP_PRESS_GAP_US);
	CHECK_EQ(play_all(), 2);
}

static void test_hold_on_air(void)
{
	setup();
	irp_player_play(&p, &sony, 7);
	play(NULL);
	irp_player_start(&p); /* unit 2 on air */
	CHECK_EQ(irp_player_hold(&p, 7, 5, now), IRP_OK);
	now += 45000;
	irp_player_done(&p, now);
	CHECK_EQ(play_all(), 4); /* 5 counting the one that was on air */

	irp_player_start(&p); /* empty queue: no-op */
	CHECK(!irp_player_busy(&p));
	CHECK_EQ(irp_player_queue_free(&p), 8);
}

static void test_hold_never_shortens_and_clamps(void)
{
	setup();
	sony.min_repeats = 20;
	irp_player_play(&p, &sony, 7);
	irp_player_start(&p);
	CHECK_EQ(irp_player_hold(&p, 7, 2, now), IRP_OK);
	CHECK_EQ(p.units_left, 20); /* the press itself still has 20 to play */
	now += 45000;
	irp_player_done(&p, now);
	CHECK_EQ(play_all(), 19);

	setup();
	irp_player_play(&p, &sony, 8);
	irp_player_start(&p);
	CHECK_EQ(irp_player_hold(&p, 8, 0, now), IRP_OK); /* clamped to 1: no change */
	CHECK_EQ(p.units_left, 3);

	irp_player_stop(&p);
	now += 45000;
	irp_player_done(&p, now);
	irp_player_play(&p, &sony, 9);
	play(NULL);
	irp_player_start(&p);
	CHECK_EQ(irp_player_hold(&p, 9, 200, now), IRP_OK); /* clamped to 20 */
	CHECK_EQ(p.units_left, 20);
}

static void test_hold_during_intro(void)
{
	struct irp_unit u;
	int n = 0;

	setup();
	irp_player_play(&p, &nec, 3); /* intro + 1 repeat */
	CHECK(irp_player_peek(&p, &u, &(uint64_t){0}));
	irp_player_start(&p);         /* intro on air */
	CHECK_EQ(irp_player_hold(&p, 3, 3, now), IRP_OK);
	now += nec.section_us[IRP_INTRO];
	irp_player_done(&p, now);
	while (play(&u)) {
		CHECK_EQ(u.section, IRP_REPEAT);
		n++;
	}
	CHECK_EQ(n, 2); /* the intro counted as the first of 3 units */
}

static void test_hold_extends_queued_press(void)
{
	struct irp_unit u;

	setup();
	irp_player_play(&p, &nec, 1);
	irp_player_play(&p, &sony, 2);
	irp_player_start(&p);
	CHECK_EQ(irp_player_hold(&p, 2, 6, now), IRP_OK); /* still queued */
	CHECK_EQ(irp_player_queue_free(&p), 7);
	now += nec.section_us[IRP_INTRO];
	irp_player_done(&p, now);
	play(NULL); /* NEC repeat */
	int n = 0;

	while (play(&u)) {
		n++;
	}
	CHECK_EQ(n, 6); /* max(3 of the press, 6 of the HOLD) */
}

static void test_resume_overtakes_queue(void)
{
	struct irp_unit u;
	uint64_t nb;

	setup();
	irp_player_play(&p, &sony, 1);
	play_all();
	irp_player_play(&p, &nec, 2);
	CHECK_EQ(irp_player_hold(&p, 1, 2, now + 1000), IRP_OK);
	CHECK(irp_player_peek(&p, &u, &nb));
	CHECK(u.sig == &p.cur.sig);
	CHECK_EQ(u.section, IRP_REPEAT);
}

static void test_hold_resumes_repeat_only(void)
{
	struct irp_unit u;
	uint64_t nb;

	setup();
	irp_player_play(&p, &nec, 3);
	CHECK_EQ(play_all(), 2);

	/* NEC unit 108 ms: window max(200, 216) ms */
	now += 215000;
	CHECK_EQ(irp_player_hold(&p, 3, 3, now), IRP_OK);
	CHECK(irp_player_peek(&p, &u, &nb));
	CHECK_EQ(u.section, IRP_REPEAT); /* no intro */
	CHECK_EQ(nb, 0);                 /* no press gap */
	int n = 0;

	while (play(&u)) {
		CHECK_EQ(u.section, IRP_REPEAT);
		n++;
	}
	CHECK_EQ(n, 3);
}

static void test_hold_window(void)
{
	setup();
	irp_player_play(&p, &nec, 3);
	play_all();
	CHECK_EQ(irp_player_hold(&p, 3, 3, now + 216000), IRP_ERR_NO_HOLD);
	CHECK_EQ(irp_player_hold(&p, 3, 3, now + 215999), IRP_OK);

	setup();
	irp_player_play(&p, &sony, 4); /* 45 ms unit: window 200 ms */
	play_all();
	CHECK_EQ(irp_player_hold(&p, 4, 3, now + 200000), IRP_ERR_NO_HOLD);
	CHECK_EQ(irp_player_hold(&p, 4, 3, now + 199999), IRP_OK);
}

static void test_hold_errors(void)
{
	setup();
	CHECK_EQ(irp_player_hold(&p, 1, 3, now), IRP_ERR_NO_HOLD); /* nothing played yet */
	irp_player_play(&p, &sony, 1);
	irp_player_start(&p);
	CHECK_EQ(irp_player_hold(&p, 2, 3, now), IRP_ERR_NO_HOLD); /* other sig_id */
	CHECK_EQ(irp_player_queue_free(&p), 8);                     /* nothing queued */
}

static void test_stop(void)
{
	struct irp_unit u;
	uint64_t nb;

	setup();
	irp_player_play(&p, &sony, 1);
	irp_player_play(&p, &nec, 2);
	irp_player_start(&p);
	irp_player_stop(&p);
	CHECK_EQ(irp_player_queue_free(&p), 8);
	CHECK(irp_player_busy(&p)); /* the unit on air finishes */
	CHECK_EQ(irp_player_hold(&p, 1, 5, now), IRP_ERR_NO_HOLD);
	now += 45000;
	irp_player_done(&p, now);
	CHECK(!irp_player_busy(&p));
	CHECK(!irp_player_peek(&p, &u, &nb));
	CHECK_EQ(irp_player_hold(&p, 1, 5, now + 1000), IRP_ERR_NO_HOLD);

	/* between units */
	irp_player_play(&p, &sony, 3);
	play(NULL);
	irp_player_stop(&p);
	CHECK(!irp_player_busy(&p));
}

static void test_queue_limits(void)
{
	struct irp_signal big;
	static uint32_t d[900];

	setup();
	for (unsigned int i = 0; i < IRP_QUEUE_DEPTH; i++) {
		CHECK_EQ(irp_player_play(&p, &sony, i + 1), IRP_OK);
	}
	CHECK_EQ(irp_player_queue_free(&p), 0);
	CHECK_EQ(irp_player_play(&p, &sony, 99), IRP_ERR_QUEUE_FULL);
	irp_player_start(&p);
	CHECK_EQ(irp_player_play(&p, &sony, 99), IRP_OK);

	/* 2048-byte budget: 4 signals of 475 bytes fit, the 5th does not */
	setup();
	for (int i = 0; i < 900; i++) {
		d[i] = (uint32_t)(500 + (i % 8) * 100);
	}
	CHECK_EQ(irp_signal_build(&big, 38000, 33, 0, NULL, 0, d, 900), IRP_OK);
	CHECK(big.blob_len * 4u <= IRP_QUEUE_BYTES && big.blob_len * 5u > IRP_QUEUE_BYTES);
	for (int i = 0; i < 4; i++) {
		CHECK_EQ(irp_player_play(&p, &big, (uint32_t)(i + 1)), IRP_OK);
	}
	CHECK_EQ(irp_player_play(&p, &big, 5), IRP_ERR_QUEUE_FULL);
	CHECK_EQ(irp_player_play(&p, &sony, 6), IRP_OK);
	irp_player_start(&p); /* frees the budget of the first one */
	CHECK_EQ(irp_player_play(&p, &big, 7), IRP_OK);
}

static void test_hold_count_formula(void)
{
	/* the app's count = clamp(ceil(180 ms / unit) + 1, 2, 20) keeps a held key
	 * transmitting with HOLDs every 120 ms */
	for (size_t k = 0; k < VEC_COUNT(vec_hold); k++) {
		uint32_t unit = vec_hold[k].unit_us;
		uint32_t count = (180000 + unit - 1) / unit + 1;

		count = count < 2 ? 2 : count > 20 ? 20 : count;
		CHECK_EQ(count, vec_hold[k].count);
		CHECK((count - 1) * unit >= 120000);
	}
}

TEST_MAIN({
	RUN(test_units_per_press);
	RUN(test_press_and_queue_free);
	RUN(test_gap_between_presses);
	RUN(test_hold_on_air);
	RUN(test_hold_never_shortens_and_clamps);
	RUN(test_hold_during_intro);
	RUN(test_hold_extends_queued_press);
	RUN(test_resume_overtakes_queue);
	RUN(test_hold_resumes_repeat_only);
	RUN(test_hold_window);
	RUN(test_hold_errors);
	RUN(test_stop);
	RUN(test_queue_limits);
	RUN(test_hold_count_formula);
})
