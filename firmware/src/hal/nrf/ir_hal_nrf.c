/*
 * nRF52 IR backend.
 *
 * TX: the PWM peripheral at 16 MHz plays one value per carrier period
 * (COUNTERTOP = carrier period, REFRESH = 0). A section is streamed through two
 * halves (SEQ0/SEQ1) refilled from the SEQEND interrupts, so sections of any length
 * need only a few KiB of RAM and the CPU has a whole half (>= 15 ms) to refill.
 *
 * RX: GPIOTE IN events on both edges trigger a TIMER capture through PPI, so edge
 * timestamps do not depend on interrupt latency.
 */
#include <errno.h>
#include <zephyr/device.h>
#include <zephyr/drivers/clock_control/nrf_clock_control.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/gpio/gpio_nrf.h>
#include <zephyr/dt-bindings/gpio/nordic-nrf-gpio.h>
#include <zephyr/irq.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/onoff.h>
#include <helpers/nrfx_gppi.h>
#include <hal/nrf_timer.h>
#include <nrfx_gpiote.h>
#include <nrfx_pwm.h>
#include <soc.h>

#include "hw.h"
#include "ir_hal.h"
#include "irplay/wave.h"

#define PWM_NODE DT_PHANDLE(OPENPULT_NODE, ir_pwm)

BUILD_ASSERT(!DT_NODE_HAS_STATUS_OKAY(PWM_NODE),
	     "ir-pwm must be disabled so that no Zephyr PWM driver claims it");

#define PWM_CLOCK_HZ 16000000u
#define TICKS_PER_US (PWM_CLOCK_HZ / 1000000u)
/* Refills run with a whole half as deadline; keep them below the radio interrupts. */
#define PWM_IRQ_PRIO 5
#define HALF_PERIODS 1024u
/* bit 15 = 1: output high from the period start until COMPARE (see nRF52840 PS, PWM) */
#define POLARITY_FALLING 0x8000u
#define TX_ACTIVE_LOW ((DT_GPIO_FLAGS(OPENPULT_NODE, ir_tx_gpios) & GPIO_ACTIVE_LOW) != 0)
#define TX_DRIVE (IS_ENABLED(CONFIG_OPENPULT_TX_HIGH_DRIVE) ? NRF_GPIO_DRIVE_H0H1 : 0)

static const struct gpio_dt_spec tx_gpio = GPIO_DT_SPEC_GET(OPENPULT_NODE, ir_tx_gpios);
static const struct device *const hfclk = DEVICE_DT_GET(DT_NODELABEL(hfclk));

static nrfx_pwm_t pwm = NRFX_PWM_INSTANCE(DT_REG_ADDR(PWM_NODE));
static nrfx_pwm_config_t pwm_cfg = {
	.output_pins = {
		NRF_DT_GPIOS_TO_PSEL(OPENPULT_NODE, ir_tx_gpios),
		NRF_PWM_PIN_NOT_CONNECTED,
		NRF_PWM_PIN_NOT_CONNECTED,
		NRF_PWM_PIN_NOT_CONNECTED,
	},
	.irq_priority = PWM_IRQ_PRIO,
	.base_clock = NRF_PWM_CLK_16MHz,
	.top_value = 421,
	.count_mode = NRF_PWM_MODE_UP,
	.load_mode = NRF_PWM_LOAD_COMMON,
	.step_mode = NRF_PWM_STEP_AUTO,
	/* drive strength and idle level come from the GPIO configuration */
	.skip_gpio_cfg = true,
};

static uint16_t halves[2][HALF_PERIODS];
static nrf_pwm_sequence_t seq[2] = {
	{.values.p_common = halves[0]},
	{.values.p_common = halves[1]},
};

static struct {
	struct irp_wave wave;
	uint16_t space;
	int8_t final_half; /* half holding the end of the section, -1 if not reached yet */
	bool busy;
	uint32_t start_cyc;
	uint64_t end_periods[2]; /* cumulative periods at the end of each half's play */
} tx;

static ir_hal_tx_done_t tx_done_cb;
static ir_hal_rx_edge_t rx_edge_cb;

static struct onoff_client clk_cli;
static ir_hal_ready_t clk_ready;

/* A whole half of spaces: played only if the stop after the final half comes late, and
 * long enough that the PWM never wraps around to stale marks before it stops. */
static void blank_half(int n)
{
	for (unsigned int i = 0; i < HALF_PERIODS; i++) {
		halves[n][i] = tx.space;
	}
	seq[n].length = HALF_PERIODS;
}

static uint16_t fill_half(int n)
{
	uint16_t k = (uint16_t)irp_wave_fill(&tx.wave, halves[n], HALF_PERIODS);

	if (k == 0) {
		blank_half(n);
	} else {
		seq[n].length = k;
	}
	return k;
}

static uint64_t periods_to_us(uint64_t periods)
{
	return periods * pwm_cfg.top_value / TICKS_PER_US;
}

/* Stop in hardware at the end of the final half; the interrupt only backs it up. */
static void stop_after(int n)
{
	nrf_pwm_shorts_enable(pwm.p_reg, n == 0 ? NRF_PWM_SHORT_SEQEND0_STOP_MASK
						 : NRF_PWM_SHORT_SEQEND1_STOP_MASK);
}

static void on_seq_end(int n)
{
	int other = n ^ 1;

	if (tx.final_half == -2) {
		return; /* aborted, stopping */
	}
	if (tx.final_half == n) {
		nrfx_pwm_stop(&pwm, false); /* after the period now playing */
		return;
	}
	if (tx.final_half == other) {
		blank_half(n);
		nrfx_pwm_sequence_update(&pwm, (uint8_t)n, &seq[n]);
		return;
	}

	uint16_t k = fill_half(n);

	nrfx_pwm_sequence_update(&pwm, (uint8_t)n, &seq[n]);
	tx.end_periods[n] = tx.end_periods[other] + k;
	if (k == 0) {
		tx.final_half = (int8_t)other;
		stop_after(other);
		stop_after(n);
	} else if (tx.wave.finished) {
		tx.final_half = (int8_t)n;
		stop_after(n);
	}

	/* The refill must be done before the other half ends, or the PWM replays stale
	 * values from this one. Abort rather than transmit garbage. */
	uint64_t elapsed_us = k_cyc_to_us_floor64(k_cycle_get_32() - tx.start_cyc);

	if (elapsed_us >= periods_to_us(tx.end_periods[other])) {
		tx.final_half = -2;
		nrfx_pwm_stop(&pwm, false);
	}
}

static void pwm_handler(nrfx_pwm_event_type_t event, void *ctx)
{
	ARG_UNUSED(ctx);

	switch (event) {
	case NRFX_PWM_EVENT_END_SEQ0:
		on_seq_end(0);
		break;
	case NRFX_PWM_EVENT_END_SEQ1:
		on_seq_end(1);
		break;
	case NRFX_PWM_EVENT_STOPPED:
		tx.busy = false;
		tx_done_cb(tx.final_half == -2 ? -EIO : 0);
		break;
	default:
		break;
	}
}

int ir_hal_tx_start(const struct irp_signal *sig, enum irp_section sec)
{
	uint32_t top = irp_wave_period_ticks(PWM_CLOCK_HZ, sig->carrier_hz);
	uint16_t compare = (uint16_t)((top * sig->duty_pct + 50) / 100);
	uint16_t invert = TX_ACTIVE_LOW ? POLARITY_FALLING : 0;
	int err;

	if (tx.busy) {
		return -EBUSY;
	}
	if (top != pwm_cfg.top_value) {
		pwm_cfg.top_value = (uint16_t)top;
		err = nrfx_pwm_reconfigure(&pwm, &pwm_cfg);
		if (err) {
			return err;
		}
	}

	tx.space = POLARITY_FALLING ^ invert;
	irp_wave_init(&tx.wave, sig, sec, TICKS_PER_US, top,
		      (uint16_t)((POLARITY_FALLING | compare) ^ invert), tx.space);
	tx.busy = true;
	tx.start_cyc = k_cycle_get_32();

	uint16_t n0 = fill_half(0);

	tx.end_periods[0] = n0;
	if (tx.wave.finished || fill_half(1) == 0) {
		tx.final_half = 0;
		nrfx_pwm_simple_playback(&pwm, &seq[0], 1,
					 NRFX_PWM_FLAG_STOP | NRFX_PWM_FLAG_NO_EVT_FINISHED);
		return 0;
	}

	tx.end_periods[1] = tx.end_periods[0] + seq[1].length;
	tx.final_half = tx.wave.finished ? 1 : -1;
	nrfx_pwm_complex_playback(&pwm, &seq[0], &seq[1], UINT16_MAX,
				  NRFX_PWM_FLAG_SIGNAL_END_SEQ0 | NRFX_PWM_FLAG_SIGNAL_END_SEQ1 |
					  NRFX_PWM_FLAG_NO_EVT_FINISHED);
	if (tx.final_half == 1) {
		stop_after(1); /* half 0 is full, so this is set long before SEQEND1 */
	}
	return 0;
}

static void clk_notify(struct onoff_manager *mgr, struct onoff_client *cli, uint32_t state,
		       int res)
{
	ARG_UNUSED(mgr);
	ARG_UNUSED(cli);
	ARG_UNUSED(state);
	ARG_UNUSED(res);

	/* On failure the PWM still runs from the internal oscillator (+-1.5 %). */
	clk_ready();
}

int ir_hal_tx_power(bool on, ir_hal_ready_t ready)
{
	if (!on) {
		return nrf_clock_control_cancel_or_release(hfclk, NULL, &clk_cli);
	}
	clk_ready = ready;
	sys_notify_init_callback(&clk_cli.notify, clk_notify);
	return nrf_clock_control_request(hfclk, NULL, &clk_cli);
}

#if DT_NODE_HAS_PROP(OPENPULT_NODE, ir_rx_gpios) && defined(CONFIG_OPENPULT_LEARN)

BUILD_ASSERT(DT_NODE_HAS_PROP(OPENPULT_NODE, ir_rx_timer), "ir-rx-gpios needs ir-rx-timer");

#define RX_TIMER_NODE DT_PHANDLE(OPENPULT_NODE, ir_rx_timer)
#define RX_TIMER ((NRF_TIMER_Type *)DT_REG_ADDR(RX_TIMER_NODE))

BUILD_ASSERT(!DT_NODE_HAS_STATUS_OKAY(RX_TIMER_NODE),
	     "ir-rx-timer must be disabled so that no Zephyr driver claims it");

static const struct gpio_dt_spec rx_gpio = GPIO_DT_SPEC_GET(OPENPULT_NODE, ir_rx_gpios);
static const struct gpio_dt_spec rx_power = GPIO_DT_SPEC_GET_OR(OPENPULT_NODE, ir_rx_power_gpios, {0});
static const struct gpio_dt_spec rx_gnd = GPIO_DT_SPEC_GET_OR(OPENPULT_NODE, ir_rx_gnd_gpios, {0});
static const uint32_t rx_pin = NRF_DT_GPIOS_TO_PSEL(OPENPULT_NODE, ir_rx_gpios);

static nrfx_gpiote_t *rx_gpiote;
static uint8_t rx_channel;
static nrfx_gppi_handle_t rx_ppi;
static bool rx_capturing;

bool ir_hal_rx_present(void)
{
	return true;
}

static int rx_init(void)
{
	int err = 0;

	if (!gpio_is_ready_dt(&rx_gpio)) {
		return -ENODEV;
	}
	rx_gpiote = gpio_nrf_gpiote_by_port_get(rx_gpio.port);
	if (rx_power.port) {
		err = gpio_pin_configure_dt(&rx_power, GPIO_OUTPUT_INACTIVE);
	}
	if (!err && rx_gnd.port) {
		err = gpio_pin_configure_dt(&rx_gnd, GPIO_OUTPUT_ACTIVE);
	}
	return err;
}

int ir_hal_rx_power(bool on)
{
	return rx_power.port ? gpio_pin_set_dt(&rx_power, on) : 0;
}

static void rx_edge(nrfx_gpiote_pin_t pin, nrfx_gpiote_trigger_t trigger, void *ctx)
{
	ARG_UNUSED(pin);
	ARG_UNUSED(trigger);
	ARG_UNUSED(ctx);

	rx_edge_cb(nrf_timer_cc_get(RX_TIMER, NRF_TIMER_CC_CHANNEL0));
}

static int rx_capture_on(void)
{
	static const nrf_gpio_pin_pull_t pull = NRF_GPIO_PIN_NOPULL; /* module has a pull-up */
	nrfx_gpiote_trigger_config_t trigger = {
		.trigger = NRFX_GPIOTE_TRIGGER_TOGGLE,
		.p_in_channel = &rx_channel,
	};
	static const nrfx_gpiote_handler_config_t handler = {.handler = rx_edge};
	const nrfx_gpiote_input_pin_config_t input = {
		.p_pull_config = &pull,
		.p_trigger_config = &trigger,
		.p_handler_config = &handler,
	};
	int err;

	err = nrfx_gpiote_channel_alloc(rx_gpiote, &rx_channel);
	if (err) {
		return err;
	}
	err = nrfx_gpiote_input_configure(rx_gpiote, rx_pin, &input);
	if (!err) {
		err = nrfx_gppi_conn_alloc(
			nrfx_gpiote_in_event_address_get(rx_gpiote, rx_pin),
			nrf_timer_task_address_get(RX_TIMER, NRF_TIMER_TASK_CAPTURE0), &rx_ppi);
	}
	if (err) {
		(void)nrfx_gpiote_pin_uninit(rx_gpiote, rx_pin);
		(void)nrfx_gpiote_channel_free(rx_gpiote, rx_channel);
		return err;
	}
	nrf_timer_mode_set(RX_TIMER, NRF_TIMER_MODE_TIMER);
	nrf_timer_bit_width_set(RX_TIMER, NRF_TIMER_BIT_WIDTH_32);
	nrf_timer_prescaler_set(RX_TIMER, NRF_TIMER_PRESCALER_CALCULATE(
						    NRF_TIMER_BASE_FREQUENCY_GET(RX_TIMER), 1000000));
	nrf_timer_task_trigger(RX_TIMER, NRF_TIMER_TASK_CLEAR);
	nrf_timer_task_trigger(RX_TIMER, NRF_TIMER_TASK_START);

	nrfx_gppi_conn_enable(rx_ppi);
	nrfx_gpiote_trigger_enable(rx_gpiote, rx_pin, true);
	return 0;
}

bool ir_hal_rx_level(void)
{
	/* The pin is set up through nrfx, so the Zephyr driver knows nothing of its
	 * active level: apply the devicetree flag here. */
	bool high = nrf_gpio_pin_read(rx_pin) != 0;

	return (rx_gpio.dt_flags & GPIO_ACTIVE_LOW) ? !high : high;
}

static void rx_capture_off(void)
{
	uint32_t eep = nrfx_gpiote_in_event_address_get(rx_gpiote, rx_pin);
	uint32_t tep = nrf_timer_task_address_get(RX_TIMER, NRF_TIMER_TASK_CAPTURE0);

	nrfx_gpiote_trigger_disable(rx_gpiote, rx_pin);
	nrfx_gppi_conn_disable(rx_ppi);
	nrfx_gppi_conn_free(eep, tep, rx_ppi);
	(void)nrfx_gpiote_pin_uninit(rx_gpiote, rx_pin); /* input buffer disconnected */
	(void)nrfx_gpiote_channel_free(rx_gpiote, rx_channel);
	nrf_timer_task_trigger(RX_TIMER, NRF_TIMER_TASK_STOP);
	nrf_timer_task_trigger(RX_TIMER, NRF_TIMER_TASK_SHUTDOWN);
}

int ir_hal_rx_capture(bool on)
{
	int err = 0;

	if (on == rx_capturing) {
		return 0;
	}
	if (on) {
		err = rx_capture_on();
	} else {
		rx_capture_off();
	}
	if (!err) {
		rx_capturing = on;
	}
	return err;
}

uint32_t ir_hal_rx_now_us(void)
{
	nrf_timer_task_trigger(RX_TIMER, NRF_TIMER_TASK_CAPTURE1);
	return nrf_timer_cc_get(RX_TIMER, NRF_TIMER_CC_CHANNEL1);
}

#else

bool ir_hal_rx_present(void)
{
	return false;
}

static int rx_init(void)
{
	return 0;
}

int ir_hal_rx_power(bool on)
{
	ARG_UNUSED(on);
	return -ENOTSUP;
}

int ir_hal_rx_capture(bool on)
{
	ARG_UNUSED(on);
	return -ENOTSUP;
}

uint32_t ir_hal_rx_now_us(void)
{
	return 0;
}

bool ir_hal_rx_level(void)
{
	return false;
}

#endif

int ir_hal_init(ir_hal_tx_done_t tx_done, ir_hal_rx_edge_t rx_edge)
{
	int err;

	tx_done_cb = tx_done;
	rx_edge_cb = rx_edge;

	if (!gpio_is_ready_dt(&tx_gpio)) {
		return -ENODEV;
	}
	err = gpio_pin_configure_dt(&tx_gpio, GPIO_OUTPUT_INACTIVE | TX_DRIVE);
	if (err) {
		return err;
	}

	IRQ_CONNECT(DT_IRQN(PWM_NODE), PWM_IRQ_PRIO, nrfx_pwm_irq_handler, &pwm, 0);
	err = nrfx_pwm_init(&pwm, &pwm_cfg, pwm_handler, NULL);
	if (err) {
		return err;
	}
	return rx_init();
}
