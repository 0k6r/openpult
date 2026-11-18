#include "irplay/sirc.h"

bool irp_sirc_bits_valid(uint8_t bits)
{
	return bits == 12 || bits == 15 || bits == 20;
}

uint16_t irp_sirc_device(uint8_t bits, uint16_t dev)
{
	return (uint16_t)(dev & ((1u << (bits - 7u)) - 1u));
}

uint32_t irp_sirc_value(uint8_t bits, uint16_t dev, uint8_t cmd)
{
	uint32_t value = 0;

	for (unsigned int i = 0; i < 7; i++) {
		value = (value << 1) | ((cmd >> i) & 1u);
	}
	for (unsigned int i = 0; i < bits - 7u; i++) {
		value = (value << 1) | ((dev >> i) & 1u);
	}
	return value;
}

int irp_sirc_signal(uint8_t bits, uint16_t dev, uint8_t cmd, uint8_t frames,
		    struct irp_signal *out)
{
	uint32_t d[2 + 2 * 20];
	uint32_t value, frame_us = 4 * IRP_SIRC_T_US;
	uint16_t n = 0;

	if (!irp_sirc_bits_valid(bits)) {
		return IRP_ERR_SIRC_BITS;
	}

	value = irp_sirc_value(bits, dev, cmd);
	d[n++] = 4 * IRP_SIRC_T_US;
	for (int i = bits - 1; i >= 0; i--) {
		uint32_t mark = ((value >> i) & 1u) ? 2 * IRP_SIRC_T_US : IRP_SIRC_T_US;

		d[n++] = IRP_SIRC_T_US;
		d[n++] = mark;
		frame_us += IRP_SIRC_T_US + mark;
	}
	d[n++] = IRP_SIRC_PERIOD_US - frame_us;

	return irp_signal_build(out, IRP_SIRC_CARRIER_HZ, IRP_SIRC_DUTY_PCT, frames, NULL, 0, d, n);
}

uint32_t irp_sirc_key(uint8_t bits, uint16_t dev, uint8_t cmd)
{
	return 0x80000000u | ((uint32_t)bits << 24) | ((uint32_t)irp_sirc_device(bits, dev) << 8) |
	       cmd;
}
