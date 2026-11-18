/* irplay: Sony SIRC builder for the legacy SEND (0x01) command. */
#ifndef IRPLAY_SIRC_H_
#define IRPLAY_SIRC_H_

#include <stdbool.h>
#include <stdint.h>

#include "irplay/signal.h"

#define IRP_SIRC_T_US 600u
#define IRP_SIRC_PERIOD_US 45000u
#define IRP_SIRC_CARRIER_HZ 40000u
#define IRP_SIRC_DUTY_PCT 33u
#define IRP_SIRC_FRAMES_DEFAULT 3u
#define IRP_SIRC_FRAMES_MIN 3u
#define IRP_SIRC_FRAMES_MAX 20u

bool irp_sirc_bits_valid(uint8_t bits);

/* Device bits above the (bits - 7)-bit field are not transmitted. */
uint16_t irp_sirc_device(uint8_t bits, uint16_t dev);

/* Bits in transmission order (7 command bits, then the device field, each LSB
 * first), written MSB-first. */
uint32_t irp_sirc_value(uint8_t bits, uint16_t dev, uint8_t cmd);

/*
 * The code as a repeat-only signal: start mark 4T, per bit space T + mark 2T/T, and a
 * final space completing the 45 ms period; min_repeats = frames.
 * Returns IRP_OK or IRP_ERR_SIRC_BITS.
 */
int irp_sirc_signal(uint8_t bits, uint16_t dev, uint8_t cmd, uint8_t frames,
		    struct irp_signal *out);

/* Press key of a legacy code, disjoint from PLAY sig_ids (1..255). */
uint32_t irp_sirc_key(uint8_t bits, uint16_t dev, uint8_t cmd);

#endif /* IRPLAY_SIRC_H_ */
