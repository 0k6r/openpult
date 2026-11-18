#include "test.h"
#include "battery_curve.h"

static void test_breakpoints(void)
{
	CHECK_EQ(battery_percent(4500, 3, BATTERY_ALKALINE), 100);
	CHECK_EQ(battery_percent(3900, 3, BATTERY_ALKALINE), 60);
	CHECK_EQ(battery_percent(3600, 3, BATTERY_ALKALINE), 35);
	CHECK_EQ(battery_percent(3300, 3, BATTERY_ALKALINE), 15);
	CHECK_EQ(battery_percent(3000, 3, BATTERY_ALKALINE), 0);
}

static void test_interpolation(void)
{
	CHECK_EQ(battery_percent(4200, 3, BATTERY_ALKALINE), 80);  /* 1.40 V/cell */
	CHECK_EQ(battery_percent(3750, 3, BATTERY_ALKALINE), 48);  /* 1.25 V/cell: 47.5 rounds up */
	CHECK_EQ(battery_percent(3450, 3, BATTERY_ALKALINE), 25);  /* 1.15 V/cell */
	CHECK_EQ(battery_percent(3150, 3, BATTERY_ALKALINE), 8);   /* 1.05 V/cell: 7.5 rounds up */
	CHECK_EQ(battery_percent(4499, 3, BATTERY_ALKALINE), 100); /* 99.93 */
	CHECK_EQ(battery_percent(3001, 3, BATTERY_ALKALINE), 0);
}

static void test_clamping(void)
{
	CHECK_EQ(battery_percent(5000, 3, BATTERY_ALKALINE), 100);
	CHECK_EQ(battery_percent(2999, 3, BATTERY_ALKALINE), 0);
	CHECK_EQ(battery_percent(0, 3, BATTERY_ALKALINE), 0);
	CHECK_EQ(battery_percent(4000, 0, BATTERY_ALKALINE), 0);
}

static void test_other_cell_counts(void)
{
	CHECK_EQ(battery_percent(3000, 2, BATTERY_ALKALINE), 100);
	CHECK_EQ(battery_percent(2600, 2, BATTERY_ALKALINE), 60);
	CHECK_EQ(battery_percent(1300, 1, BATTERY_ALKALINE), 60);
	CHECK_EQ(battery_percent(6000, 4, BATTERY_ALKALINE), 100);
}

static void test_monotonic(void)
{
	uint8_t prev = 0;

	for (uint32_t mv = 2800; mv <= 4800; mv++) {
		uint8_t pct = battery_percent(mv, 3, BATTERY_ALKALINE);

		CHECK(pct >= prev);
		prev = pct;
	}
}

static void test_low_flag(void)
{
	CHECK(battery_low(3299, 3, BATTERY_ALKALINE));
	CHECK(!battery_low(3300, 3, BATTERY_ALKALINE));
	CHECK(!battery_low(4500, 3, BATTERY_ALKALINE));
	CHECK(battery_low(2199, 2, BATTERY_ALKALINE));
	CHECK(!battery_low(2200, 2, BATTERY_ALKALINE));
}

static void test_li_ion(void)
{
	CHECK_EQ(battery_percent(4250, 1, BATTERY_LI_ION), 100);
	CHECK_EQ(battery_percent(4200, 1, BATTERY_LI_ION), 100);
	CHECK_EQ(battery_percent(3870, 1, BATTERY_LI_ION), 60);
	CHECK_EQ(battery_percent(3740, 1, BATTERY_LI_ION), 30);
	CHECK_EQ(battery_percent(3300, 1, BATTERY_LI_ION), 0);
	CHECK_EQ(battery_percent(3000, 1, BATTERY_LI_ION), 0);
	CHECK(battery_low(3499, 1, BATTERY_LI_ION));
	CHECK(!battery_low(3500, 1, BATTERY_LI_ION));

	uint8_t prev = 0;

	for (uint32_t mv = 3000; mv <= 4300; mv++) {
		uint8_t pct = battery_percent(mv, 1, BATTERY_LI_ION);

		CHECK(pct >= prev);
		prev = pct;
	}
}

TEST_MAIN({
	RUN(test_li_ion);
	RUN(test_breakpoints);
	RUN(test_interpolation);
	RUN(test_clamping);
	RUN(test_other_cell_counts);
	RUN(test_monotonic);
	RUN(test_low_flag);
})
