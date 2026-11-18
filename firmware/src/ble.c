#include <errno.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>
#include <zephyr/spinlock.h>
#include <zephyr/sys/atomic.h>

#include "ble.h"

LOG_MODULE_REGISTER(ble, CONFIG_OPENPULT_LOG_LEVEL);

#define PAIRING_WINDOW_MS 120000
#define ENCRYPT_TIMEOUT K_SECONDS(30)
#define IDLE_TIMEOUT K_MINUTES(10)
#define FAST_ADV_MS 30000
#define ADV_RETRY K_SECONDS(1)

/* 152.5 ms and 546.25 ms (Apple accessory design guidelines), in 0.625 ms units */
#define ADV_FAST_INT 244
#define ADV_SLOW_INT 874

#define OPENPULT_UUID(n) BT_UUID_128_ENCODE(0x7B2A0000 | (n), 0x5C1E, 0x4F6B, 0x9D3A, 0x8E4F1C2B7A10)

static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(OPENPULT_UUID(0x0001));
static const struct bt_uuid_128 cmd_uuid = BT_UUID_INIT_128(OPENPULT_UUID(0x0002));
static const struct bt_uuid_128 status_uuid = BT_UUID_INIT_128(OPENPULT_UUID(0x0003));
static const struct bt_uuid_128 capture_uuid = BT_UUID_INIT_128(OPENPULT_UUID(0x0004));

static const struct ble_callbacks *app;

struct conn_slot {
	struct bt_conn *conn;
	struct k_work_delayable encrypt_timeout;
	struct k_work_delayable idle_timeout;
	bool pairing;
};

static struct conn_slot slots[CONFIG_BT_MAX_CONN];
static struct k_spinlock slots_lock;

enum adv_mode {
	ADV_OFF,
	ADV_FAST,
	ADV_SLOW,
};

/* Advertising is driven towards the wanted state by one work item, so stopping it to
 * change the interval (which frees its connection object and fires recycled) does not
 * restart anything by itself. */
static struct k_work_delayable adv_work;
static atomic_t adv_mode;
static atomic_t adv_lost;       /* the controller stopped advertising for a connection */
static int64_t fast_until_ms;   /* fast interval until this uptime */
static struct k_spinlock fast_lock;
static struct k_work_delayable pairing_window_work;
static struct k_work client_ready_work;

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, OPENPULT_UUID(0x0001)),
};

static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

static const struct bt_le_adv_param adv_fast =
	BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONN, ADV_FAST_INT, ADV_FAST_INT, NULL);
static const struct bt_le_adv_param adv_slow =
	BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONN, ADV_SLOW_INT, ADV_SLOW_INT, NULL);

static struct conn_slot *slot_of(struct bt_conn *conn)
{
	return &slots[bt_conn_index(conn)];
}

/* Returns a new reference to the slot's connection, or NULL once it is gone. */
static struct bt_conn *slot_conn_get(struct conn_slot *slot)
{
	struct bt_conn *conn = NULL;
	k_spinlock_key_t key = k_spin_lock(&slots_lock);

	if (slot->conn) {
		conn = bt_conn_ref(slot->conn);
	}
	k_spin_unlock(&slots_lock, key);
	return conn;
}

static size_t conn_count(void)
{
	size_t n = 0;
	k_spinlock_key_t key = k_spin_lock(&slots_lock);

	ARRAY_FOR_EACH(slots, i) {
		n += slots[i].conn != NULL;
	}
	k_spin_unlock(&slots_lock, key);
	return n;
}

static void count_bond(const struct bt_bond_info *info, void *user_data)
{
	ARG_UNUSED(info);
	(*(size_t *)user_data)++;
}

bool ble_pairing_window_open(void)
{
	size_t bonds = 0;

	bt_foreach_bond(BT_ID_DEFAULT, count_bond, &bonds);
	return bonds == 0 || k_uptime_get() < PAIRING_WINDOW_MS;
}

/* GATT */

static ssize_t write_command(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			     const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(attr);

	/* Writes without response would never trigger pairing on iOS. */
	if (flags & BT_GATT_WRITE_FLAG_CMD) {
		return BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED);
	}
	if (offset != 0) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
	}
	if (flags & BT_GATT_WRITE_FLAG_PREPARE) {
		return 0;
	}

	k_work_reschedule(&slot_of(conn)->idle_timeout, IDLE_TIMEOUT);

	uint8_t err = app->command(conn, buf, len);

	return err ? BT_GATT_ERR(err) : len;
}

static ssize_t read_status(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
			   uint16_t len, uint16_t offset)
{
	uint8_t value[16];
	uint16_t n = app->status(value, sizeof(value));

	return bt_gatt_attr_read(conn, attr, buf, len, offset, value, n);
}

static ssize_t status_ccc_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
				uint16_t value)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(attr);

	/* The value is stored after this returns; notify from the work queue. */
	if (value & BT_GATT_CCC_NOTIFY) {
		k_work_submit(&client_ready_work);
	}
	return sizeof(value);
}

BT_GATT_SERVICE_DEFINE(openpult_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&cmd_uuid.uuid, BT_GATT_CHRC_WRITE, BT_GATT_PERM_WRITE_ENCRYPT,
			       NULL, write_command, NULL),
	BT_GATT_CHARACTERISTIC(&status_uuid.uuid, BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ_ENCRYPT, read_status, NULL, NULL),
	BT_GATT_CCC_WITH_WRITE_CB(NULL, status_ccc_write,
				  BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
	BT_GATT_CHARACTERISTIC(&capture_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE, NULL,
			       NULL, NULL),
	BT_GATT_CCC(NULL, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE_ENCRYPT),
);

#define STATUS_ATTR (&openpult_svc.attrs[4])
#define CAPTURE_ATTR (&openpult_svc.attrs[7])

void ble_notify_status(const uint8_t *data, uint16_t len)
{
	int err = bt_gatt_notify(NULL, STATUS_ATTR, data, len);

	if (err && err != -ENOTCONN) {
		LOG_DBG("status notify: %d", err);
	}
}

void ble_set_battery_level(uint8_t percent)
{
	(void)bt_bas_set_battery_level(percent);
}

uint16_t ble_notify_max(struct bt_conn *conn)
{
	return (uint16_t)(bt_gatt_get_mtu(conn) - 3);
}

int ble_notify_capture(struct bt_conn *conn, const uint8_t *data, uint16_t len)
{
	if (!bt_gatt_is_subscribed(conn, CAPTURE_ATTR, BT_GATT_CCC_NOTIFY)) {
		return -EINVAL;
	}
	return bt_gatt_notify(conn, CAPTURE_ATTR, data, len);
}

static void client_ready_fn(struct k_work *work)
{
	ARG_UNUSED(work);
	app->client_ready();
}

/* Advertising */

static void adv_fast_from_now(void)
{
	k_spinlock_key_t key = k_spin_lock(&fast_lock);

	fast_until_ms = k_uptime_get() + FAST_ADV_MS;
	k_spin_unlock(&fast_lock, key);
	k_work_reschedule(&adv_work, K_NO_WAIT);
}

static void adv_update(struct k_work *work)
{
	ARG_UNUSED(work);

	k_spinlock_key_t key = k_spin_lock(&fast_lock);
	int64_t fast_left = fast_until_ms - k_uptime_get();

	k_spin_unlock(&fast_lock, key);

	enum adv_mode want = conn_count() >= CONFIG_BT_MAX_CONN ? ADV_OFF
			     : fast_left > 0			  ? ADV_FAST
								  : ADV_SLOW;
	int err;

	if (atomic_clear(&adv_lost)) {
		atomic_set(&adv_mode, ADV_OFF);
	}
	if (want != (enum adv_mode)atomic_get(&adv_mode)) {
		if (atomic_get(&adv_mode) != ADV_OFF) {
			(void)bt_le_adv_stop();
			atomic_set(&adv_mode, ADV_OFF);
		}
		if (want != ADV_OFF) {
			err = bt_le_adv_start(want == ADV_FAST ? &adv_fast : &adv_slow, ad,
					      ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
			if (err) {
				/* e.g. no free connection object until recycled */
				LOG_DBG("adv start: %d", err);
				k_work_reschedule(&adv_work, ADV_RETRY);
				return;
			}
			atomic_set(&adv_mode, want);
		}
	}
	if (want == ADV_FAST) {
		k_work_reschedule(&adv_work, K_MSEC(fast_left));
	}
}

/* Connections */

static void encrypt_timeout_fn(struct k_work *work)
{
	struct conn_slot *slot =
		CONTAINER_OF(k_work_delayable_from_work(work), struct conn_slot, encrypt_timeout);
	struct bt_conn *conn = slot_conn_get(slot);

	if (!conn) {
		return;
	}
	if (bt_conn_get_security(conn) < BT_SECURITY_L2) {
		if (slot->pairing) {
			/* The user may still be looking at the iOS pairing dialog;
			 * SMP has its own 30 s timeout ending in pairing_failed. */
			k_work_reschedule(&slot->encrypt_timeout, ENCRYPT_TIMEOUT);
		} else {
			LOG_INF("not encrypted in time, disconnecting");
			(void)bt_conn_disconnect(conn, BT_HCI_ERR_AUTH_FAIL);
		}
	}
	bt_conn_unref(conn);
}

static void idle_timeout_fn(struct k_work *work)
{
	struct conn_slot *slot =
		CONTAINER_OF(k_work_delayable_from_work(work), struct conn_slot, idle_timeout);
	struct bt_conn *conn = slot_conn_get(slot);

	if (!conn) {
		return;
	}
	if (app->keep_alive()) {
		k_work_reschedule(&slot->idle_timeout, IDLE_TIMEOUT);
	} else {
		LOG_INF("no commands for 10 min, disconnecting");
		(void)bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
	}
	bt_conn_unref(conn);
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	struct conn_slot *slot;
	k_spinlock_key_t key;

	if (err) {
		LOG_WRN("connection failed: 0x%02x", err);
		atomic_set(&adv_lost, 1);
		k_work_reschedule(&adv_work, K_NO_WAIT);
		return;
	}

	slot = slot_of(conn);
	key = k_spin_lock(&slots_lock);
	slot->conn = bt_conn_ref(conn);
	slot->pairing = false;
	k_spin_unlock(&slots_lock, key);

	LOG_INF("connected");
	k_work_reschedule(&slot->encrypt_timeout, ENCRYPT_TIMEOUT);
	k_work_reschedule(&slot->idle_timeout, IDLE_TIMEOUT);
	atomic_set(&adv_lost, 1);
	k_work_reschedule(&adv_work, K_NO_WAIT); /* stay connectable for a second phone */
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	struct conn_slot *slot = slot_of(conn);
	struct bt_conn *old;
	k_spinlock_key_t key;

	LOG_INF("disconnected: 0x%02x", reason);

	k_work_cancel_delayable(&slot->encrypt_timeout);
	k_work_cancel_delayable(&slot->idle_timeout);

	key = k_spin_lock(&slots_lock);
	old = slot->conn;
	slot->conn = NULL;
	k_spin_unlock(&slots_lock, key);

	app->disconnected(conn);
	if (old) {
		bt_conn_unref(old);
	}
	adv_fast_from_now();
}

static void recycled(void)
{
	k_work_reschedule(&adv_work, K_NO_WAIT);
}

static void security_changed(struct bt_conn *conn, bt_security_t level, enum bt_security_err err)
{
	struct conn_slot *slot = slot_of(conn);

	LOG_INF("security level %d, err %d", level, err);
	if (err || level < BT_SECURITY_L2) {
		return;
	}
	slot->pairing = false;
	k_work_cancel_delayable(&slot->encrypt_timeout);
	k_work_submit(&client_ready_work);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
	.recycled = recycled,
	.security_changed = security_changed,
};

/* Pairing policy */

static enum bt_security_err pairing_accept(struct bt_conn *conn,
					   const struct bt_conn_pairing_feat *const feat)
{
	ARG_UNUSED(feat);

	if (!ble_pairing_window_open()) {
		LOG_WRN("pairing rejected: window closed");
		return BT_SECURITY_ERR_PAIR_NOT_ALLOWED;
	}
	slot_of(conn)->pairing = true;
	return BT_SECURITY_ERR_SUCCESS;
}

static const struct bt_conn_auth_cb auth_callbacks = {
	.pairing_accept = pairing_accept,
};

static void pairing_complete(struct bt_conn *conn, bool bonded)
{
	LOG_INF("paired, bonded %d", bonded);
	slot_of(conn)->pairing = false;
	app->pairing_changed();
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
	struct conn_slot *slot = slot_of(conn);

	LOG_WRN("pairing failed: %d", reason);
	slot->pairing = false;
	k_work_reschedule(&slot->encrypt_timeout, ENCRYPT_TIMEOUT);
}

static void bond_deleted(uint8_t id, const bt_addr_le_t *peer)
{
	ARG_UNUSED(id);
	ARG_UNUSED(peer);
	app->pairing_changed();
}

static struct bt_conn_auth_info_cb auth_info_callbacks = {
	.pairing_complete = pairing_complete,
	.pairing_failed = pairing_failed,
	.bond_deleted = bond_deleted,
};

static void pairing_window_fn(struct k_work *work)
{
	ARG_UNUSED(work);
	app->pairing_changed();
}

int ble_init(const struct ble_callbacks *cb)
{
	int err;

	app = cb;

	ARRAY_FOR_EACH(slots, i) {
		k_work_init_delayable(&slots[i].encrypt_timeout, encrypt_timeout_fn);
		k_work_init_delayable(&slots[i].idle_timeout, idle_timeout_fn);
	}
	k_work_init_delayable(&adv_work, adv_update);
	k_work_init_delayable(&pairing_window_work, pairing_window_fn);
	k_work_init(&client_ready_work, client_ready_fn);

	err = bt_conn_auth_cb_register(&auth_callbacks);
	if (!err) {
		err = bt_conn_auth_info_cb_register(&auth_info_callbacks);
	}
	if (!err) {
		err = bt_enable(NULL);
	}
	if (!err) {
		err = settings_load();
	}
	if (err) {
		LOG_ERR("init: %d", err);
		return err;
	}

	k_work_schedule(&pairing_window_work, K_MSEC(PAIRING_WINDOW_MS));
	adv_fast_from_now();
	return 0;
}
