/*
 * IR transmitter/receiver backend. One implementation per SoC family
 * (src/hal/<family>/); the rest of the firmware only uses this interface.
 */
#ifndef IR_HAL_H_
#define IR_HAL_H_

#include <stdbool.h>
#include <stdint.h>

#include "irplay/signal.h"

/* A section finished (err 0) or was aborted (-EIO: the backend could not keep up). */
typedef void (*ir_hal_tx_done_t)(int err);
/* An edge on the receiver output; t_us from a free-running microsecond counter. */
typedef void (*ir_hal_rx_edge_t)(uint32_t t_us);
typedef void (*ir_hal_ready_t)(void);

/* Callbacks may run in interrupt context. */
int ir_hal_init(ir_hal_tx_done_t tx_done, ir_hal_rx_edge_t rx_edge);

/*
 * Keeps the transmitter ready while on (nRF: the crystal oscillator for an accurate
 * carrier). ready() is called once it is, possibly before this returns.
 */
int ir_hal_tx_power(bool on, ir_hal_ready_t ready);

/* Plays one section. The signal must stay unchanged until tx_done. */
int ir_hal_tx_start(const struct irp_signal *sig, enum irp_section sec);

bool ir_hal_rx_present(void);

/* Supplies the receiver module. */
int ir_hal_rx_power(bool on);

/* Starts or stops edge capture (rx_edge callbacks). */
int ir_hal_rx_capture(bool on);

/* Now, in the time base of the rx_edge timestamps (valid while capturing). */
uint32_t ir_hal_rx_now_us(void);

/* True while the receiver output is active (a carrier is being received). */
bool ir_hal_rx_level(void);

#endif /* IR_HAL_H_ */
