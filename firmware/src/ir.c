#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/spinlock.h>
#include <zephyr/sys/atomic.h>

#include "hw.h"
#include "ir.h"
#include "ir_hal.h"
#include "irplay/bridge.h"
#include "irplay/capture.h"

LOG_MODULE_REGISTER(ir, CONFIG_OPENPULT_LOG_LEVEL);

#define WARMUP K_MSEC(20)
#define POLL_PERIOD K_MSEC(10)

enum clock_state {
	CLOCK_OFF,
	CLOCK_REQUESTED,
	CLOCK_ON,
};

enum learn_state {
	LEARN_IDLE,
	LEARN_WARMUP,
	LEARN_CAPTURE,
};

static ir_changed_cb_t changed_cb;
static ir_captured_cb_t captured_cb;

/* Protocol state; touched by the Bluetooth thread and the IR work queue. */
static struct irp_bridge bridge;
static K_MUTEX_DEFINE(bridge_lock);

/* Transmission runs on its own cooperative work queue: the system work queue can be
 * blocked by flash writes. Interrupt handlers only submit kick_work. */
static K_THREAD_STACK_DEFINE(wq_stack, 1024);
static struct k_work_q wq;
static struct k_work kick_work;
static struct k_timer gap_timer;
static atomic_t clock_state;
static atomic_t done_pending;
static atomic_t activity;
static bool on_air;

/* Learning control runs in the Bluetooth thread and the system work queue. */
static K_MUTEX_DEFINE(learn_lock);
static struct irp_capture capture;
static struct k_spinlock capture_lock;
static atomic_t learn_state;
static atomic_t learn_timed_out;
static struct k_work_delayable learn_arm_work;
static struct k_work learn_end_work;
static struct k_timer learn_poll_timer;
static struct k_timer learn_timeout_timer;
static struct ir_capture_result result;
static uint32_t armed_us; /* edges up to this time are already in the level read at arming */

static uint64_t now_us(void)
{
	return k_ticks_to_us_floor64(k_uptime_ticks());
}

static void kick(void)
{
	k_work_submit_to_queue(&wq, &kick_work);
}

static void tx_done(int err)
{
	if (err) {
		LOG_WRN("section aborted: %d", err);
	}
	atomic_set(&done_pending, 1);
	kick();
}

static void clock_ready(void)
{
	/* ignore a completion racing with the release */
	if (atomic_cas(&clock_state, CLOCK_REQUESTED, CLOCK_ON)) {
		kick();
	}
}

static void gap_expired(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	kick();
}

/* Starts the next unit if one is due. Called with bridge_lock held. */
static void schedule(uint64_t now)
{
	struct irp_player *p = &bridge.player;
	struct irp_unit unit;
	uint64_t not_before;

	while (irp_player_peek(p, &unit, &not_before)) {
		if (atomic_get(&clock_state) != CLOCK_ON) {
			if (atomic_cas(&clock_state, CLOCK_OFF, CLOCK_REQUESTED) &&
			    ir_hal_tx_power(true, clock_ready) < 0) {
				/* run from the internal oscillator rather than not at all */
				atomic_set(&clock_state, CLOCK_ON);
				continue;
			}
			return;
		}
		if (not_before > now) {
			k_timer_start(&gap_timer, K_USEC(not_before - now), K_NO_WAIT);
			return;
		}

		irp_player_start(p);
		if (ir_hal_tx_start(&p->cur.sig, unit.section) == 0) {
			on_air = true;
			atomic_inc(&activity);
			return;
		}
		LOG_WRN("section rejected by the transmitter");
		irp_player_done(p, now);
	}

	if (atomic_set(&clock_state, CLOCK_OFF) != CLOCK_OFF) {
		(void)ir_hal_tx_power(false, NULL);
	}
}

static void kick_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint64_t now = now_us();

	k_mutex_lock(&bridge_lock, K_FOREVER);
	if (atomic_clear(&done_pending)) {
		irp_player_done(&bridge.player, now);
		on_air = false;
	}
	if (!on_air) {
		schedule(now);
	}
	k_mutex_unlock(&bridge_lock);
	changed_cb();
}

/* Learning */

static void rx_edge(uint32_t t_us)
{
	bool done;
	k_spinlock_key_t key;

	if (atomic_get(&learn_state) != LEARN_CAPTURE) {
		return;
	}
	key = k_spin_lock(&capture_lock);
	if ((int32_t)(t_us - armed_us) <= 0) {
		k_spin_unlock(&capture_lock, key);
		return;
	}
	irp_capture_edge(&capture, t_us);
	done = capture.done;
	k_spin_unlock(&capture_lock, key);
	if (done) {
		k_work_submit(&learn_end_work);
	}
}

static void learn_poll(struct k_timer *timer)
{
	ARG_UNUSED(timer);

	bool done;
	k_spinlock_key_t key = k_spin_lock(&capture_lock);

	done = irp_capture_poll(&capture, ir_hal_rx_now_us());
	k_spin_unlock(&capture_lock, key);
	if (done) {
		k_work_submit(&learn_end_work);
	}
}

static void learn_timeout(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	atomic_set(&learn_timed_out, 1);
	k_work_submit(&learn_end_work);
}

static void learn_arm_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	k_mutex_lock(&learn_lock, K_FOREVER);
	if (atomic_get(&learn_state) == LEARN_WARMUP) {
		if (ir_hal_rx_capture(true) == 0) {
			k_spinlock_key_t key = k_spin_lock(&capture_lock);

			/* a remote already sending must not invert the capture */
			irp_capture_set_level(&capture, ir_hal_rx_level());
			armed_us = ir_hal_rx_now_us();
			atomic_set(&learn_state, LEARN_CAPTURE);
			k_spin_unlock(&capture_lock, key);
			k_timer_start(&learn_poll_timer, POLL_PERIOD, POLL_PERIOD);
		} else {
			LOG_ERR("capture start failed");
			atomic_set(&learn_timed_out, 1);
			k_work_submit(&learn_end_work);
		}
	}
	k_mutex_unlock(&learn_lock);
}

static void learn_hw_off(void)
{
	atomic_set(&learn_state, LEARN_IDLE);
	k_timer_stop(&learn_poll_timer);
	k_timer_stop(&learn_timeout_timer);
	k_work_cancel_delayable(&learn_arm_work);
	(void)ir_hal_rx_capture(false);
	(void)ir_hal_rx_power(false);
}

static void learn_stop(void)
{
	k_mutex_lock(&learn_lock, K_FOREVER);
	learn_hw_off();
	k_mutex_unlock(&learn_lock);
}

static void learn_start(uint8_t timeout_s)
{
	k_mutex_lock(&learn_lock, K_FOREVER);
	learn_hw_off();
	irp_capture_reset(&capture);
	atomic_set(&learn_timed_out, 0);
	(void)ir_hal_rx_power(true);
	atomic_set(&learn_state, LEARN_WARMUP);
	k_work_reschedule(&learn_arm_work, WARMUP);
	k_timer_start(&learn_timeout_timer, K_SECONDS(timeout_s), K_NO_WAIT);
	k_mutex_unlock(&learn_lock);
	LOG_INF("learning for %u s", timeout_s);
}

static void learn_end_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	k_mutex_lock(&learn_lock, K_FOREVER);
	if (atomic_get(&learn_state) == LEARN_IDLE ||
	    (!capture.done && !atomic_get(&learn_timed_out))) {
		k_mutex_unlock(&learn_lock);
		return;
	}
	learn_hw_off(); /* no more edges: the capture is stable from here on */

	if (capture.done) {
		result.count = capture.count;
		result.flags = capture.flags;
		memcpy(result.durations, capture.durations, capture.count * sizeof(uint32_t));
	} else {
		result.count = 0;
		result.flags = IRP_CAPTURE_TIMEOUT;
	}
	k_mutex_unlock(&learn_lock);
	LOG_INF("capture: %u durations, flags 0x%02x", result.count, result.flags);

	k_mutex_lock(&bridge_lock, K_FOREVER);
	irp_bridge_learn_done(&bridge);
	k_mutex_unlock(&bridge_lock);
	changed_cb();
	captured_cb(&result);
}

uint8_t ir_command(const uint8_t *data, uint16_t len, unsigned int *actions)
{
	uint8_t err;
	uint8_t timeout_s;

	k_mutex_lock(&bridge_lock, K_FOREVER);
	err = irp_bridge_command(&bridge, data, len, now_us(), actions);
	timeout_s = bridge.learn_timeout_s;
	k_mutex_unlock(&bridge_lock);

	if (*actions & IRP_ACT_LEARN_STOP) {
		learn_stop();
	}
	if (*actions & IRP_ACT_LEARN_START) {
		learn_start(timeout_s);
	}
	if (*actions & IRP_ACT_PLAYER) {
		kick();
	}
	changed_cb();
	return err;
}

void ir_learn_cancel(void)
{
	learn_stop();
	k_mutex_lock(&bridge_lock, K_FOREVER);
	irp_bridge_learn_done(&bridge);
	k_mutex_unlock(&bridge_lock);
	changed_cb();
}

bool ir_transmitting(void)
{
	bool busy;

	k_mutex_lock(&bridge_lock, K_FOREVER);
	busy = irp_player_busy(&bridge.player);
	k_mutex_unlock(&bridge_lock);
	return busy;
}

bool ir_learning(void)
{
	return bridge.learning;
}

uint8_t ir_queue_free(void)
{
	uint8_t n;

	k_mutex_lock(&bridge_lock, K_FOREVER);
	n = irp_player_queue_free(&bridge.player);
	k_mutex_unlock(&bridge_lock);
	return n;
}

uint8_t ir_last_error(void)
{
	return bridge.last_error;
}

uint8_t ir_caps(void)
{
	return bridge.caps;
}

uint32_t ir_activity(void)
{
	return (uint32_t)atomic_get(&activity);
}

int ir_init(ir_changed_cb_t changed, ir_captured_cb_t captured)
{
	uint8_t caps = IRP_CAP_PLAY | IRP_CAP_SEND;
	int err;

	changed_cb = changed;
	captured_cb = captured;

	if (IS_ENABLED(CONFIG_OPENPULT_LEARN) && ir_hal_rx_present()) {
		caps |= IRP_CAP_LEARN;
	}
	if (DT_PROP(OPENPULT_NODE, uf2_bootloader)) {
		caps |= IRP_CAP_UF2;
	}
	irp_bridge_init(&bridge, caps);

	const struct k_work_queue_config wq_cfg = {.name = "ir"};

	k_work_queue_start(&wq, wq_stack, K_THREAD_STACK_SIZEOF(wq_stack), K_PRIO_COOP(5),
			   &wq_cfg);
	k_work_init(&kick_work, kick_fn);
	k_timer_init(&gap_timer, gap_expired, NULL);
	k_work_init_delayable(&learn_arm_work, learn_arm_fn);
	k_work_init(&learn_end_work, learn_end_fn);
	k_timer_init(&learn_poll_timer, learn_poll, NULL);
	k_timer_init(&learn_timeout_timer, learn_timeout, NULL);

	err = ir_hal_init(tx_done, rx_edge);
	if (err) {
		LOG_ERR("hal init: %d", err);
	}
	return err;
}
