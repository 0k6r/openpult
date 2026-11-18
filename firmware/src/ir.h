/* IR service: protocol state, transmission scheduling and learning on top of ir_hal. */
#ifndef IR_H_
#define IR_H_

#include <stdbool.h>
#include <stdint.h>

#include "irplay/capture.h"

struct ir_capture_result {
	uint32_t durations[IRP_CAPTURE_MAX];
	uint16_t count;
	uint8_t flags;
};

/* State visible in Status changed (transmitting, queue, learning). Thread context. */
typedef void (*ir_changed_cb_t)(void);
/* Learning finished with a capture or a timeout. System work queue. */
typedef void (*ir_captured_cb_t)(const struct ir_capture_result *result);

int ir_init(ir_changed_cb_t changed, ir_captured_cb_t captured);

/* One Command write. Returns 0 or an ATT error code; *actions gets IRP_ACT_* bits. */
uint8_t ir_command(const uint8_t *data, uint16_t len, unsigned int *actions);

/* Ends learning without a capture (the requesting client went away). */
void ir_learn_cancel(void);

bool ir_transmitting(void);
bool ir_learning(void);
uint8_t ir_queue_free(void);
uint8_t ir_last_error(void);
uint8_t ir_caps(void);

/* Incremented whenever a section goes on air. */
uint32_t ir_activity(void);

#endif /* IR_H_ */
