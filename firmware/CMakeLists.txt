cmake_minimum_required(VERSION 3.20.0)

# The production overlays disable the USB controller; the debug build needs it back.
if(EXTRA_CONF_FILE MATCHES "debug\\.conf")
  list(APPEND EXTRA_DTC_OVERLAY_FILE ${CMAKE_CURRENT_SOURCE_DIR}/debug.overlay)
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(openpult_ir)

# Protocol logic, OS independent (host-tested in tests/host).
file(GLOB IRPLAY_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/lib/irplay/src/*.c)
target_include_directories(app PRIVATE src lib/irplay/include)

target_sources(app PRIVATE
  ${IRPLAY_SOURCES}
  src/main.c
  src/ble.c
  src/ir.c
  src/battery.c
  src/battery_curve.c
)

if(CONFIG_SOC_FAMILY_NORDIC_NRF)
  target_sources(app PRIVATE
    src/hal/nrf/ir_hal_nrf.c
    src/hal/nrf/platform_nrf.c
  )
endif()
