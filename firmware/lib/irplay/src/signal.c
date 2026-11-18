#include <string.h>

#include "irplay/signal.h"

static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

size_t irp_varint_decode(const uint8_t *in, size_t len, uint32_t *value)
{
	uint32_t v = 0;

	for (size_t i = 0; i < len && i < 5; i++) {
		uint32_t bits = in[i] & 0x7Fu;

		if (i == 4 && bits > 0x0Fu) {
			return 0;
		}
		v |= bits << (7 * i);
		if (!(in[i] & 0x80u)) {
			*value = v;
			return i + 1;
		}
	}
	return 0;
}

size_t irp_varint_encode(uint32_t value, uint8_t *out, size_t max)
{
	size_t n = 0;

	do {
		if (n == max) {
			return 0;
		}
		uint8_t byte = value & 0x7Fu;

		value >>= 7;
		out[n++] = value ? (uint8_t)(byte | 0x80u) : byte;
	} while (value);
	return n;
}

static size_t varint_size(uint32_t value)
{
	size_t n = 1;

	while (value >>= 7) {
		n++;
	}
	return n;
}

uint8_t irp_press_units(const struct irp_signal *s)
{
	if (s->count[IRP_INTRO] && s->count[IRP_REPEAT]) {
		return (uint8_t)(1 + s->min_repeats);
	}
	return s->min_repeats ? s->min_repeats : 1;
}

static int validate(struct irp_signal *s)
{
	uint32_t total = (uint32_t)s->count[IRP_INTRO] + s->count[IRP_REPEAT];

	if (s->carrier_hz < IRP_CARRIER_MIN_HZ || s->duty_pct < IRP_DUTY_MIN_PCT ||
	    s->duty_pct > IRP_DUTY_MAX_PCT || s->min_repeats > IRP_MIN_REPEATS_MAX ||
	    s->table_n < 1 || s->table_n > IRP_TABLE_MAX || total < 2 ||
	    total > IRP_SYMBOLS_MAX || (s->count[IRP_INTRO] % 2) || (s->count[IRP_REPEAT] % 2) ||
	    s->blob_len > IRP_BLOB_MAX) {
		return IRP_ERR_UNSUPPORTED;
	}
	for (unsigned int k = 0; k < s->table_n; k++) {
		if (s->table[k] < 1 || s->table[k] > IRP_DURATION_MAX_US) {
			return IRP_ERR_UNSUPPORTED;
		}
	}

	for (int sec = IRP_INTRO; sec <= IRP_REPEAT; sec++) {
		uint32_t sum = 0;

		for (uint16_t i = 0; i < s->count[sec]; i++) {
			uint8_t sym = irp_symbol(s, (enum irp_section)sec, i);

			if (sym >= s->table_n) {
				return IRP_ERR_UNSUPPORTED;
			}
			if (i % 2 == 0 && s->table[sym] > IRP_MARK_MAX_US) {
				return IRP_ERR_UNSUPPORTED;
			}
			sum += s->table[sym];
			if (sum > IRP_SECTION_MAX_US) {
				return IRP_ERR_UNSUPPORTED;
			}
		}
		s->section_us[sec] = sum;
	}
	return IRP_OK;
}

int irp_blob_parse(const uint8_t *blob, size_t len, struct irp_signal *out)
{
	size_t pos = IRP_BLOB_HEADER;

	if (len < IRP_BLOB_HEADER || len > IRP_BLOB_MAX) {
		return IRP_ERR_UNSUPPORTED;
	}

	memset(out, 0, sizeof(*out));
	out->carrier_hz = get_le16(&blob[0]);
	out->duty_pct = blob[2] ? blob[2] : IRP_DUTY_DEFAULT_PCT;
	out->min_repeats = blob[3];
	out->table_n = blob[4];
	out->count[IRP_INTRO] = get_le16(&blob[5]);
	out->count[IRP_REPEAT] = get_le16(&blob[7]);
	out->blob_len = (uint16_t)len;

	if (out->table_n > IRP_TABLE_MAX || (out->count[IRP_INTRO] % 2) ||
	    (out->count[IRP_REPEAT] % 2) ||
	    (uint32_t)out->count[IRP_INTRO] + out->count[IRP_REPEAT] > IRP_SYMBOLS_MAX) {
		return IRP_ERR_UNSUPPORTED;
	}
	for (unsigned int k = 0; k < out->table_n; k++) {
		size_t n = irp_varint_decode(&blob[pos], len - pos, &out->table[k]);

		if (n == 0) {
			return IRP_ERR_UNSUPPORTED;
		}
		pos += n;
	}

	size_t intro_bytes = (out->count[IRP_INTRO] + 1u) / 2u;
	size_t repeat_bytes = (out->count[IRP_REPEAT] + 1u) / 2u;

	if (pos + intro_bytes + repeat_bytes != len) {
		return IRP_ERR_UNSUPPORTED;
	}
	memcpy(out->symbols, &blob[pos], intro_bytes + repeat_bytes);
	return validate(out);
}

static int table_index(struct irp_signal *s, uint32_t d)
{
	for (unsigned int k = 0; k < s->table_n; k++) {
		if (s->table[k] == d) {
			return (int)k;
		}
	}
	if (s->table_n == IRP_TABLE_MAX) {
		return -1;
	}
	s->table[s->table_n] = d;
	return s->table_n++;
}

int irp_signal_build(struct irp_signal *out, uint16_t carrier_hz, uint8_t duty_pct,
		     uint8_t min_repeats, const uint32_t *intro, uint16_t intro_n,
		     const uint32_t *repeat, uint16_t repeat_n)
{
	const uint32_t *src[2] = {intro, repeat};
	size_t size = IRP_BLOB_HEADER;

	memset(out, 0, sizeof(*out));
	out->carrier_hz = carrier_hz;
	out->duty_pct = duty_pct ? duty_pct : IRP_DUTY_DEFAULT_PCT;
	out->min_repeats = min_repeats;
	out->count[IRP_INTRO] = intro_n;
	out->count[IRP_REPEAT] = repeat_n;

	if ((intro_n % 2) || (repeat_n % 2) || (uint32_t)intro_n + repeat_n > IRP_SYMBOLS_MAX) {
		return IRP_ERR_UNSUPPORTED;
	}
	for (int sec = IRP_INTRO; sec <= IRP_REPEAT; sec++) {
		uint16_t base = irp_section_offset(out, (enum irp_section)sec);

		for (uint16_t i = 0; i < out->count[sec]; i++) {
			int k = table_index(out, src[sec][i]);

			if (k < 0) {
				return IRP_ERR_UNSUPPORTED;
			}
			out->symbols[base + i / 2] |= (uint8_t)(i % 2 == 0 ? k << 4 : k);
		}
	}

	for (unsigned int k = 0; k < out->table_n; k++) {
		size += varint_size(out->table[k]);
	}
	size += (intro_n + 1u) / 2u + (repeat_n + 1u) / 2u;
	out->blob_len = size > UINT16_MAX ? UINT16_MAX : (uint16_t)size;
	return validate(out);
}

size_t irp_blob_encode(const struct irp_signal *s, uint8_t *out, size_t max)
{
	size_t symbol_bytes = (s->count[IRP_INTRO] + 1u) / 2u + (s->count[IRP_REPEAT] + 1u) / 2u;
	size_t pos = IRP_BLOB_HEADER;

	if (max < IRP_BLOB_HEADER) {
		return 0;
	}
	out[0] = (uint8_t)s->carrier_hz;
	out[1] = (uint8_t)(s->carrier_hz >> 8);
	out[2] = s->duty_pct;
	out[3] = s->min_repeats;
	out[4] = s->table_n;
	out[5] = (uint8_t)s->count[IRP_INTRO];
	out[6] = (uint8_t)(s->count[IRP_INTRO] >> 8);
	out[7] = (uint8_t)s->count[IRP_REPEAT];
	out[8] = (uint8_t)(s->count[IRP_REPEAT] >> 8);

	for (unsigned int k = 0; k < s->table_n; k++) {
		size_t n = irp_varint_encode(s->table[k], &out[pos], max - pos);

		if (n == 0) {
			return 0;
		}
		pos += n;
	}
	if (pos + symbol_bytes > max) {
		return 0;
	}
	memcpy(&out[pos], s->symbols, symbol_bytes);
	return pos + symbol_bytes;
}
