/*
 * irplay: protocol-independent IR signal model (openpult protocol v2).
 *
 * A signal is a carrier, a duty cycle and two sections of alternating mark/space
 * symbols (intro, played once, and repeat), each symbol an index into a table of up
 * to 16 durations. Each section ends with a space that already contains the gap to
 * the next frame.
 *
 * Pure C99, no OS dependencies.
 */
#ifndef IRPLAY_SIGNAL_H_
#define IRPLAY_SIGNAL_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ATT application error codes of the protocol. */
enum irp_err {
	IRP_OK = 0,
	IRP_ERR_MALFORMED = 0x80,
	IRP_ERR_QUEUE_FULL = 0x81,
	IRP_ERR_SIRC_BITS = 0x82,
	IRP_ERR_NO_HOLD = 0x83,
	IRP_ERR_UNSUPPORTED = 0x84,
	IRP_ERR_NOT_AVAILABLE = 0x85,
};

#define IRP_BLOB_MAX 576u
#define IRP_BLOB_HEADER 9u
#define IRP_TABLE_MAX 16u
#define IRP_SYMBOLS_MAX 1024u
#define IRP_CARRIER_MIN_HZ 20000u
#define IRP_DUTY_MIN_PCT 10u
#define IRP_DUTY_MAX_PCT 50u
#define IRP_DUTY_DEFAULT_PCT 33u
#define IRP_MIN_REPEATS_MAX 20u
#define IRP_DURATION_MAX_US 500000u
#define IRP_MARK_MAX_US 30000u
#define IRP_SECTION_MAX_US 1000000u

enum irp_section {
	IRP_INTRO = 0,
	IRP_REPEAT = 1,
};

struct irp_signal {
	uint32_t table[IRP_TABLE_MAX];
	uint32_t section_us[2]; /* total duration of each section */
	uint16_t carrier_hz;
	uint16_t count[2];      /* symbols per section */
	uint16_t blob_len;      /* encoded size, counted against the queue budget */
	uint8_t duty_pct;
	uint8_t min_repeats;
	uint8_t table_n;
	/* 4-bit symbols, high nibble first; the repeat section starts on a byte boundary */
	uint8_t symbols[IRP_SYMBOLS_MAX / 2];
};

static inline uint16_t irp_section_offset(const struct irp_signal *s, enum irp_section sec)
{
	return sec == IRP_INTRO ? 0 : (uint16_t)((s->count[IRP_INTRO] + 1) / 2);
}

static inline uint8_t irp_symbol(const struct irp_signal *s, enum irp_section sec, uint16_t i)
{
	uint8_t byte = s->symbols[irp_section_offset(s, sec) + i / 2];

	return (i % 2 == 0) ? (uint8_t)(byte >> 4) : (uint8_t)(byte & 0x0F);
}

static inline uint32_t irp_duration(const struct irp_signal *s, enum irp_section sec, uint16_t i)
{
	return s->table[irp_symbol(s, sec, i)];
}

/* The section repeated while a button is held: repeat, or intro if there is none. */
static inline enum irp_section irp_unit_section(const struct irp_signal *s)
{
	return s->count[IRP_REPEAT] ? IRP_REPEAT : IRP_INTRO;
}

/* The section a press starts with. */
static inline enum irp_section irp_first_section(const struct irp_signal *s)
{
	return s->count[IRP_INTRO] ? IRP_INTRO : IRP_REPEAT;
}

/* Units (sections) one press plays: intro once then repeat x min_repeats, or the
 * only section x max(1, min_repeats). */
uint8_t irp_press_units(const struct irp_signal *s);

/* Parses and validates a signal blob. Returns IRP_OK or IRP_ERR_UNSUPPORTED. */
int irp_blob_parse(const uint8_t *blob, size_t len, struct irp_signal *out);

/*
 * Builds a signal from plain duration lists (table in order of first appearance,
 * as the app does) with the same validation as the parser. duty_pct 0 means 33.
 */
int irp_signal_build(struct irp_signal *out, uint16_t carrier_hz, uint8_t duty_pct,
		     uint8_t min_repeats, const uint32_t *intro, uint16_t intro_n,
		     const uint32_t *repeat, uint16_t repeat_n);

/* Encodes a signal as a blob. Returns its length, or 0 if it does not fit. */
size_t irp_blob_encode(const struct irp_signal *s, uint8_t *out, size_t max);

/* LEB128. Returns bytes used/written, 0 on error or lack of space. */
size_t irp_varint_decode(const uint8_t *in, size_t len, uint32_t *value);
size_t irp_varint_encode(uint32_t value, uint8_t *out, size_t max);

#endif /* IRPLAY_SIGNAL_H_ */
