CC ?= cc
PYTHON ?= python3
CFLAGS ?= -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wshadow -Wconversion -Wno-sign-conversion \
	-fsanitize=address,undefined -fno-omit-frame-pointer -fstrict-flex-arrays=3
LIB := ../../lib/irplay
SRC := ../../src
VECTORS := ../../../testdata/ir_vectors.json
BUILD := build

TESTS := test_signal test_wave test_player test_bridge test_sirc test_capture test_battery_curve

IRPLAY := $(wildcard $(LIB)/src/*.c)
test_battery_curve_SRCS := $(SRC)/battery_curve.c

.PHONY: test clean
test: $(addprefix $(BUILD)/,$(TESTS))
	@set -e; for t in $^; do echo "== $$t"; ./$$t; done

$(BUILD)/vectors.h: gen_vectors.py $(VECTORS) | $(BUILD)
	$(PYTHON) -I gen_vectors.py $(VECTORS) $@

$(BUILD)/%: %.c test.h $(BUILD)/vectors.h $(IRPLAY) $(wildcard $(LIB)/include/irplay/*.h) \
		$(wildcard $(SRC)/battery_curve.*) | $(BUILD)
	$(CC) $(CFLAGS) -I$(LIB)/include -I$(SRC) -I$(BUILD) -o $@ $< \
		$(if $($*_SRCS),$($*_SRCS),$(IRPLAY))

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
