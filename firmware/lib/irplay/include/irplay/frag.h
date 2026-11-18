/* irplay: reassembly of a signal blob from PLAY fragments. */
#ifndef IRPLAY_FRAG_H_
#define IRPLAY_FRAG_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "irplay/signal.h"

#define IRP_FRAG_LAST 0x80u
#define IRP_FRAG_INDEX_MASK 0x7Fu
/* Measured from the previous fragment: a 576-byte blob at the minimum MTU takes
 * ~36 writes with response, which can exceed 2 s in total. */
#define IRP_FRAG_TIMEOUT_US 2000000u

struct irp_frag {
	uint8_t buf[IRP_BLOB_MAX];
	uint16_t len;
	uint8_t sig_id;
	uint8_t next;
	bool active;
	uint64_t last_us;
};

void irp_frag_reset(struct irp_frag *f);

/*
 * Adds one fragment. Returns IRP_OK, IRP_ERR_MALFORMED (wrong order, sig_id or
 * timeout) or IRP_ERR_UNSUPPORTED (blob too large); on errors the buffer is reset.
 * *complete is set when the LAST fragment arrived: the blob is f->buf[0..f->len).
 */
int irp_frag_push(struct irp_frag *f, uint8_t sig_id, uint8_t frag, const uint8_t *chunk,
		  size_t len, uint64_t now_us, bool *complete);

#endif /* IRPLAY_FRAG_H_ */
