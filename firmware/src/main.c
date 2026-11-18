#include <zephyr/bluetooth/conn.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/util.h>

#include "battery.h"
#include "battery_curve.h"
#include "ble.h"
#include "hw.h"
#include "ir.h"
#include "irplay/bridge.h"
#include "irplay/capture.h"
#include "platform.h"

LOG_MODULE_REGISTER(main, CONFIG_OPENPULT_LOG_LEVEL);

#define BATTERY_PERIOD K_MINUTES(10)
#define BATTERY_RETRY K_MSEC(200)
#define BOOTLOADER_DELAY K_MSEC(150)
#define CAPTURE_RETRY K_MSEC(20)
#define CHEMISTRY (IS_ENABLED(CONFIG_OPENPULT_BATT_LI_ION) ? BATTERY_LI_ION : BATTERY_ALKALINE)

static uint16_t battery_mv;
static bool battery_measured;
static struct k_work_delayable battery_work;
static struct k_work_delayable reboot_work;

static struct k_work status_work;
static atomic_t status_force;
static uint8_t notified_flags = 0xFF;
static uint8_t notified_queue_free = 0xFF;

/* Capture notifications go to the client that started learning. */
static K_MUTEX_DEFINE(capture_lock);
static struct bt_conn *learn_conn;
static const struct ir_capture_result *capture;
static struct k_work_delayable capture_work;
static uint8_t capture_id;
static uint8_t capture_frag;
static uint16_t capture_pos;

#if defined(CONFIG_OPENPULT_DEBUG_LED) && DT_NODE_EXISTS(DT_ALIAS(led0))
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
#else
static const struct gpio_dt_spec led;
#endif

static uint8_t status_flags(void)
{
	uint8_t flags = 0;

	if (ir_transmitting()) {
		flags |= IRP_FLAG_TRANSMITTING;
	}
	if (ble_pairing_window_open()) {
		flags |= IRP_FLAG_PAIRING;
	}
	if (ir_learning()) {
		flags |= IRP_FLAG_LEARNING;
	}
	if (IS_ENABLED(CONFIG_OPENPULT_USB_POWERED)) {
		flags |= IRP_FLAG_EXT_POWER;
	} else if (battery_measured && battery_low(battery_mv, CONFIG_OPENPULT_BATT_CELLS, CHEMISTRY)) {
		flags |= IRP_FLAG_BATTERY_LOW;
	}
	return flags;
}

static uint16_t on_status(uint8_t *buf, uint16_t size)
{
	const struct irp_status st = {
		.flags = status_flags(),
		.battery_mv = battery_mv,
		.queue_free = ir_queue_free(),
		.last_error = ir_last_error(),
		.uptime_min = irp_uptime_min((uint64_t)k_uptime_get()),
		.caps = ir_caps(),
	};

	if (size < IRP_STATUS_LEN) {
		return 0;
	}
	irp_status_encode(&st, buf);
	return IRP_STATUS_LEN;
}

static void status_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint8_t buf[IRP_STATUS_LEN];

	on_status(buf, sizeof(buf));
	if (led.port) {
		(void)gpio_pin_set_dt(&led, (buf[1] & IRP_FLAG_TRANSMITTING) != 0);
	}
	if (atomic_clear(&status_force) || buf[1] != notified_flags ||
	    buf[4] != notified_queue_free) {
		notified_flags = buf[1];
		notified_queue_free = buf[4];
		ble_notify_status(buf, sizeof(buf));
	}
}

static void status_changed(void)
{
	k_work_submit(&status_work);
}

static void status_notify(void)
{
	atomic_set(&status_force, 1);
	k_work_submit(&status_work);
}

/* Battery: never measured while transmitting, the LED current sags the cells. */
static void battery_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint32_t activity = ir_activity();
	uint16_t mv;

	if (ir_transmitting()) {
		k_work_reschedule(&battery_work, BATTERY_RETRY);
		return;
	}
	if (battery_measure_mv(&mv) != 0) {
		k_work_reschedule(&battery_work, BATTERY_PERIOD);
		return;
	}
	if (ir_transmitting() || ir_activity() != activity) {
		k_work_reschedule(&battery_work, BATTERY_RETRY);
		return;
	}

	battery_mv = mv;
	battery_measured = true;
	ble_set_battery_level(battery_percent(mv, CONFIG_OPENPULT_BATT_CELLS, CHEMISTRY));
	LOG_INF("battery %u mV", mv);
	status_notify();
	k_work_reschedule(&battery_work, BATTERY_PERIOD);
}

static void reboot_fn(struct k_work *work)
{
	ARG_UNUSED(work);
	platform_enter_uf2_bootloader();
}

static void capture_release(void)
{
	if (learn_conn) {
		bt_conn_unref(learn_conn);
		learn_conn = NULL;
	}
	capture = NULL;
}

static void capture_fn(struct k_work *work)
{
	ARG_UNUSED(work);

	uint8_t buf[IRP_WRITE_MAX];
	bool last = false;

	k_mutex_lock(&capture_lock, K_FOREVER);
	while (capture && learn_conn && !last) {
		uint16_t pos = capture_pos;
		uint16_t max = MIN(ble_notify_max(learn_conn), sizeof(buf));
		size_t len = irp_capture_fragment(capture->durations, capture->count,
						  capture->flags, capture_id, capture_frag, &pos,
						  buf, max, &last);
		int err;

		if (len == 0) {
			break;
		}
		err = ble_notify_capture(learn_conn, buf, (uint16_t)len);
		if (err == -ENOMEM) {
			k_work_reschedule(&capture_work, CAPTURE_RETRY);
			k_mutex_unlock(&capture_lock);
			return;
		}
		if (err) {
			LOG_WRN("capture notify: %d", err);
			break;
		}
		capture_pos = pos;
		capture_frag++;
	}
	capture_release();
	k_mutex_unlock(&capture_lock);
}

static void on_captured(const struct ir_capture_result *result)
{
	k_mutex_lock(&capture_lock, K_FOREVER);
	capture = result;
	capture_id++;
	capture_frag = 0;
	capture_pos = 0;
	k_work_reschedule(&capture_work, K_NO_WAIT);
	k_mutex_unlock(&capture_lock);
}

static uint8_t on_command(struct bt_conn *conn, const uint8_t *data, uint16_t len)
{
	unsigned int actions;
	uint8_t err = ir_command(data, len, &actions);

	if (actions & (IRP_ACT_LEARN_START | IRP_ACT_LEARN_STOP)) {
		k_mutex_lock(&capture_lock, K_FOREVER);
		k_work_cancel_delayable(&capture_work);
		capture_release();
		if (actions & IRP_ACT_LEARN_START) {
			learn_conn = bt_conn_ref(conn);
		}
		k_mutex_unlock(&capture_lock);
	}
	if (actions & IRP_ACT_BOOTLOADER) {
		/* the write response goes out first */
		k_work_reschedule(&reboot_work, BOOTLOADER_DELAY);
	}
	return err;
}

static void on_client_ready(void)
{
	status_notify();
	if (!IS_ENABLED(CONFIG_OPENPULT_USB_POWERED)) {
		k_work_reschedule(&battery_work, K_NO_WAIT);
	}
}

static bool keep_alive(void)
{
	return ir_learning();
}

static void on_disconnected(struct bt_conn *conn)
{
	bool learning_client;

	k_mutex_lock(&capture_lock, K_FOREVER);
	learning_client = conn == learn_conn;
	if (learning_client) {
		k_work_cancel_delayable(&capture_work);
		capture_release();
	}
	k_mutex_unlock(&capture_lock);
	if (learning_client && ir_learning()) {
		ir_learn_cancel();
	}
}

static const struct ble_callbacks ble_cb = {
	.command = on_command,
	.status = on_status,
	.client_ready = on_client_ready,
	.pairing_changed = status_changed,
	.keep_alive = keep_alive,
	.disconnected = on_disconnected,
};

#define SUSPEND_DEVICE(node, prop, idx)                                                            \
	(void)pm_device_action_run(DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, idx)),             \
				   PM_DEVICE_ACTION_SUSPEND);

static void suspend_unused_devices(void)
{
#if defined(CONFIG_PM_DEVICE) && DT_NODE_HAS_PROP(OPENPULT_NODE, suspend_devices)
	DT_FOREACH_PROP_ELEM(OPENPULT_NODE, suspend_devices, SUSPEND_DEVICE)
#endif
}

int main(void)
{
	int err;

	LOG_INF("openpult-ir %s on %s", CONFIG_BT_DIS_FW_REV_STR, CONFIG_BOARD_TARGET);

	suspend_unused_devices();
	k_work_init(&status_work, status_fn);
	k_work_init_delayable(&battery_work, battery_fn);
	k_work_init_delayable(&reboot_work, reboot_fn);
	k_work_init_delayable(&capture_work, capture_fn);

	if (led.port) {
		(void)gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	}

	err = ir_init(status_changed, on_captured);
	if (err) {
		LOG_ERR("ir: %d", err);
	}
	if (!IS_ENABLED(CONFIG_OPENPULT_USB_POWERED)) {
		err = battery_init();
		if (err) {
			LOG_ERR("battery: %d", err);
		}
	}
	err = ble_init(&ble_cb);
	if (err) {
		LOG_ERR("ble: %d", err);
	}

	if (IS_ENABLED(CONFIG_OPENPULT_USB_POWERED)) {
		ble_set_battery_level(100);
	} else {
		k_work_schedule(&battery_work, K_NO_WAIT);
	}
	return 0;
}
