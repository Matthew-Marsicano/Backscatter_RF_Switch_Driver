# Makefile for cocotb simulation
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = ../src

PROJECT_SOURCES = tt_um_ble_backscatter_modem.v \
                  ble_modem_top.v \
                  sync_reset.v \
                  spi_slave.v \
                  config_regs.v \
                  payload_fifo.v \
                  pdu_assembler.v \
                  packet_fsm.v \
                  crc24.v \
                  whitening_lfsr.v \
                  symbol_timing.v \
                  phase_generator.v \
                  modulator.v

ifneq ($(GATES),yes)

SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES += gate_level_netlist.v

endif

COMPILE_ARGS 		+= -I$(SRC_DIR)
VERILOG_SOURCES += tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
