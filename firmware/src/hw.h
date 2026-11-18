/* The board wiring node (dts/bindings/openpult,ir-bridge.yaml). */
#ifndef HW_H_
#define HW_H_

#include <zephyr/devicetree.h>
#include <zephyr/toolchain.h>

BUILD_ASSERT(DT_HAS_COMPAT_STATUS_OKAY(openpult_ir_bridge),
	     "the board overlay must define an \"openpult,ir-bridge\" node");

#define OPENPULT_NODE DT_COMPAT_GET_ANY_STATUS_OKAY(openpult_ir_bridge)

#endif /* HW_H_ */
