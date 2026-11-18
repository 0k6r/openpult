#include <errno.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/adc/voltage_divider.h>
#include <zephyr/sys/util.h>

#include "battery.h"
#include "hw.h"

#if DT_NODE_HAS_PROP(OPENPULT_NODE, battery)

static const struct voltage_divider_dt_spec divider =
	VOLTAGE_DIVIDER_DT_SPEC_GET(DT_PHANDLE(OPENPULT_NODE, battery));

int battery_init(void)
{
	if (!adc_is_ready_dt(&divider.port)) {
		return -ENODEV;
	}
	return adc_channel_setup_dt(&divider.port);
}

int battery_measure_mv(uint16_t *mv)
{
	int16_t raw;
	struct adc_sequence seq = {
		.buffer = &raw,
		.buffer_size = sizeof(raw),
		.calibrate = true,
	};
	int32_t val;
	int err;

	err = adc_sequence_init_dt(&divider.port, &seq);
	if (err == 0) {
		err = adc_read_dt(&divider.port, &seq);
	}
	if (err) {
		return err;
	}

	val = MAX(raw, 0);
	err = adc_raw_to_millivolts_dt(&divider.port, &val);
	if (err == 0) {
		err = voltage_divider_scale_dt(&divider, &val);
	}
	if (err) {
		return err;
	}

	*mv = (uint16_t)CLAMP(val + CONFIG_OPENPULT_BATT_DIODE_MV, 0, UINT16_MAX);
	return 0;
}

#else

#if !defined(CONFIG_OPENPULT_USB_POWERED)
#error "the openpult node has no battery property: add one or set CONFIG_OPENPULT_USB_POWERED"
#endif

int battery_init(void)
{
	return 0;
}

int battery_measure_mv(uint16_t *mv)
{
	ARG_UNUSED(mv);
	return -ENOTSUP;
}

#endif
