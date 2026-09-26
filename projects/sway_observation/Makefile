.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
.NOTPARALLEL:

PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_NAME := sway_observation
# Resolve unchanged in blueyosys/projects/sway_observation or a sibling Sway checkout.
ROOTDIR ?= $(if $(wildcard $(PROJECT_DIR)/../../build.mk),$(abspath $(PROJECT_DIR)/../..),$(abspath $(PROJECT_DIR)/../../blueyosys))
BOARD ?= ulx3s-85f
RESULTS_DIR ?= $(PROJECT_DIR)/results

# Project Top preserves the baseline's PLL reset polarity and release sequence.
# Simulation drives the same baseline core directly with local golden fixtures.
TOP_SOURCE := $(PROJECT_DIR)/Top.bsv
TOP_MODULE := mkTop
NEEDS_INOUT_FIX := 0
BSIM_TOP_SOURCE := $(PROJECT_DIR)/sim/TbSway.bsv
BSIM_TOP_MODULE := mkTbSway
EXTRA_BSV_PATHS := $(PROJECT_DIR) $(PROJECT_DIR)/bsv $(PROJECT_DIR)/generated $(PROJECT_DIR)/sim
BSIM_CPPFILES :=
BSIM_CXXFLAGS := -Xc++ -O1
POST_RUN = $(PYTHON) "$(PROJECT_DIR)/reference/check_sim.py" system.log --output "$(RESULTS_DIR)/$(SIM_BACKEND).json" --backend "$(SIM_BACKEND)" --stderr output.log && cp system.log "$(RESULTS_DIR)/$(SIM_BACKEND).log"
BSC_RUNTIME_DIR ?= $(shell $(BSC) -help 2>/dev/null | sed -n 's/^Bluespec directory: //p')/Verilog

ifeq ($(wildcard $(ROOTDIR)/build.mk),)
$(error blueYosys not found at $(ROOTDIR). Set ROOTDIR=/absolute/path/to/blueyosys)
endif
include $(ROOTDIR)/build.mk

# Icarus executables embed their installation-time vvp path. Invoke the runtime
# from PATH so copied projects also work with user-local tool installations.
ifeq ($(SIM_BACKEND),iverilog)
.PHONY: sim-runner
sim-runner: bsim
	mv "$(BSIM_DIR)/bsim" "$(BSIM_DIR)/bsim.vvp"
	printf '%s\n' '#!/bin/sh' 'exec vvp "$$(dirname "$$0")/bsim.vvp" "$$@"' > "$(BSIM_DIR)/bsim"
	chmod +x "$(BSIM_DIR)/bsim"
runsim: sim-runner
endif

# Baseline scan state and PLL reset conversion use these compiler primitives.
# blueYosys copies its common runtime RTL; add the two missing files for Yosys.
.PHONY: runtime-rtl
runtime-rtl: verilog
	test -f "$(BSC_RUNTIME_DIR)/RegFile.v"
	test -f "$(BSC_RUNTIME_DIR)/ResetInverter.v"
	cp "$(BSC_RUNTIME_DIR)/RegFile.v" "$(BSC_RUNTIME_DIR)/ResetInverter.v" "$(BUILD_DIR)/"
netlist: runtime-rtl
