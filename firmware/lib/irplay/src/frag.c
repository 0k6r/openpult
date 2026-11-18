#include <string.h>

#include "irplay/frag.h"

void irp_frag_reset(struct irp_frag *f)
{
	f->len = 0;
	f->next = 0;
	f->active = false;
}

int irp_frag_push(struct irp_frag *f, uint8_t sig_id, uint8_t frag, const uint8_t *chunk,
		  size_t len, uint64_t now_us, bool *complete)
{
	uint8_t index = frag & IRP_FRAG_INDEX_MASK;

	*complete = false;

	if (index == 0) {
		irp_frag_reset(f);
		f->active = true;
		f->sig_id = sig_id;
	} else if (!f->active || f->sig_id != sig_id || index != f->next ||
		   now_us - f->last_us > IRP_FRAG_TIMEOUT_US) {
		irp_frag_reset(f);
		return IRP_ERR_MALFORMED;
	}

	if (f->len + len > sizeof(f->buf)) {
		irp_frag_reset(f);
		return IRP_ERR_UNSUPPORTED;
	}
	memcpy(&f->buf[f->len], chunk, len);
	f->len = (uint16_t)(f->len + len);
	f->next = (uint8_t)(index + 1);
	f->last_us = now_us;

	if (frag & IRP_FRAG_LAST) {
		f->active = false;
		*complete = true;
	} else if (f->next > IRP_FRAG_INDEX_MASK) {
		irp_frag_reset(f);
		return IRP_ERR_MALFORMED;
	}
	return IRP_OK;
}
