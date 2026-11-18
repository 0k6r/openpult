#ifndef BLE_H_
#define BLE_H_

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/bluetooth/conn.h>

struct ble_callbacks {
	/* Command characteristic write. Returns 0 or an ATT application error code. */
	uint8_t (*command)(struct bt_conn *conn, const uint8_t *data, uint16_t len);
	/* Fills the current Status value, returns its length. */
	uint16_t (*status)(uint8_t *buf, uint16_t size);
	/* A link became encrypted or a client subscribed to Status. */
	void (*client_ready)(void);
	/* Bonds or the pairing window changed. */
	void (*pairing_changed)(void);
	/* True while the idle disconnect must not happen (learning). */
	bool (*keep_alive)(void);
	/* A link went down; references to conn must be dropped. */
	void (*disconnected)(struct bt_conn *conn);
};

int ble_init(const struct ble_callbacks *cb);

/* New pairing is accepted only without bonds or during the window after power-on. */
bool ble_pairing_window_open(void);

void ble_notify_status(const uint8_t *data, uint16_t len);
void ble_set_battery_level(uint8_t percent);

/* Largest notification payload for this connection. */
uint16_t ble_notify_max(struct bt_conn *conn);

/* One Capture notification. -ENOMEM: retry later; -ENOTCONN/-EINVAL: give up. */
int ble_notify_capture(struct bt_conn *conn, const uint8_t *data, uint16_t len);

#endif /* BLE_H_ */
