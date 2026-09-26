ifndef ROOTDIR
$(error ROOTDIR must be set before including build.mk)
endif

PROJECT_DIR ?= $(CURDIR)
PROJECT_NAME ?= $(notdir $(PROJECT_DIR))
BOARD ?= ulx3s-85f

ifeq ($(BOARD),ulx3s)
$(error BOARD=ulx3s is ambiguous; use BOARD=ulx3s-85f)
endif

BOARD_REGISTRY := $(ROOTDIR)/boards/profiles.mk
ifeq ($(wildcard $(BOARD_REGISTRY)),)
$(error Missing board profile registry: $(BOARD_REGISTRY))
endif
include $(BOARD_REGISTRY)

BOARD_PROFILE_VAR := BOARD_PROFILE_$(BOARD)
BOARD_PROFILE_PATH := $($(BOARD_PROFILE_VAR))
ifeq ($(strip $(BOARD_PROFILE_PATH)),)
$(error Unknown BOARD '$(BOARD)'; register a concrete profile in boards/profiles.mk)
endif

BOARD_FILE := $(ROOTDIR)/boards/$(BOARD_PROFILE_PATH)/board.mk
ifeq ($(wildcard $(BOARD_FILE)),)
$(error BOARD=$(BOARD) maps to missing profile file 'boards/$(BOARD_PROFILE_PATH)/board.mk')
endif
include $(BOARD_FILE)

BUILD_DIR ?= $(PROJECT_DIR)/build
BSIM_DIR ?= $(PROJECT_DIR)/bsim
HOST_DIR ?= $(PROJECT_DIR)/cpp
TOP_SOURCE ?= $(BOARD_TOP_SOURCE)
TOP_MODULE ?= $(BOARD_TOP_MODULE)
BSIM_TOP_SOURCE ?= $(BOARD_BSIM_TOP_SOURCE)
BSIM_TOP_MODULE ?= $(BOARD_BSIM_TOP_MODULE)
NEEDS_INOUT_FIX ?= 1
POST_RUN ?= :
EXTRA_BSV_PATHS ?=

BSC ?= bsc
SIM_BACKEND ?= bluesim
YOSYS ?= yosys
PYTHON ?= python3
PROGRAMMER ?= $(BOARD_PROGRAMMER)
PROGRAMMER_FLAGS ?= $(BOARD_PROGRAMMER_FLAGS)

empty :=
space := $(empty) $(empty)
BSV_DIRS := $(COMMON_BSV_DIRS) $(FPGA_BSV_DIRS) $(BOARD_BSV_DIRS) $(EXTRA_BSV_PATHS)
BSV_PATH := $(subst $(space),:,$(strip $(BSV_DIRS)))
RTL_DIRS := $(COMMON_RTL_DIRS) $(FPGA_RTL_DIRS) $(BOARD_RTL_DIRS)

BSCFLAGS_COMMON ?= -show-schedule -show-range-conflict -aggressive-conditions
BSCFLAGS_SYNTH := \
	-bdir $(BUILD_DIR) \
	-vdir $(BUILD_DIR) \
	-simdir $(BUILD_DIR) \
	-info-dir $(BUILD_DIR) \
	-fdir $(BUILD_DIR)
BSCFLAGS_BSIM := \
	-bdir $(BSIM_DIR) \
	-vdir $(BSIM_DIR) \
	-simdir $(BSIM_DIR) \
	-info-dir $(BSIM_DIR) \
	-fdir $(BSIM_DIR) \
	-D BSIM \
	-l pthread

BSIM_CPPFILES ?= $(wildcard $(PROJECT_DIR)/cpp/*.cpp) $(wildcard $(ROOTDIR)/lib/cpp/*.cpp)
BSIM_CXXFLAGS ?= -Xc++ -I$(ROOTDIR)/lib/cpp
INOUT_FIXER := $(ROOTDIR)/scripts/fix_generated_inout.py
REPORT_GENERATOR := $(ROOTDIR)/scripts/generate_build_report.py
GENERATED_TOP := $(BUILD_DIR)/$(TOP_MODULE).v
BUILD_CONSTRAINTS := $(BUILD_DIR)/$(notdir $(BOARD_CONSTRAINTS))
JSON_NETLIST := $(BUILD_DIR)/$(TOP_MODULE).json
TEXTCFG := $(BUILD_DIR)/$(TOP_MODULE).config
BITSTREAM := $(BUILD_DIR)/$(TOP_MODULE).bit
YOSYS_REPORT_TEXT := $(BUILD_DIR)/$(TOP_MODULE).yosys.rpt
YOSYS_REPORT_JSON := $(BUILD_DIR)/$(TOP_MODULE).yosys.json
PNR_REPORT_JSON := $(BUILD_DIR)/$(TOP_MODULE).nextpnr.json
PNR_LOG := $(BUILD_DIR)/$(TOP_MODULE).nextpnr.log
UTILIZATION_REPORT := $(BUILD_DIR)/$(TOP_MODULE).utilization.rpt

.PHONY: all help print-config check-board check-bsc check-yosys check-pnr \
	check-pack check-programmer host hostsoft prepare verilog netlist pnr \
	bitstream synth bsim runsim program clean

all: synth host

help:
	@printf '%s\n' \
		"Targets: verilog netlist pnr bitstream synth host bsim runsim program clean print-config" \
		"Toolchain: bsc -> yosys -> nextpnr -> packer" \
		"Reports: $(YOSYS_REPORT_TEXT), $(PNR_REPORT_JSON), $(UTILIZATION_REPORT)" \
		"Variables: BOARD=ulx3s-85f"

print-config:
	@printf 'PROJECT=%s\nBOARD=%s\nBOARD_STATUS=%s\nTOP=%s:%s\nBSV_PATH=%s\nSYNTH=%s\nPNR=%s\nPACK=%s\nBITSTREAM=%s\nUTILIZATION_REPORT=%s\n' \
		'$(PROJECT_NAME)' '$(BOARD)' '$(BOARD_STATUS)' '$(TOP_SOURCE)' '$(TOP_MODULE)' '$(BSV_PATH)' \
		'$(YOSYS):$(BOARD_YOSYS_SYNTH)' '$(BOARD_PNR_TOOL)' '$(BOARD_PACK_TOOL)' '$(BITSTREAM)' '$(UTILIZATION_REPORT)'

check-board:
	@if [ "$(BOARD_READY)" != "1" ]; then \
		echo "BOARD=$(BOARD) is not build-ready: $(BOARD_STATUS)" >&2; \
		exit 2; \
	fi

check-bsc: check-board
	@tool='$(firstword $(BSC))'; command -v "$$tool" >/dev/null || { \
		echo "$$tool not found; install Bluespec Compiler or set BSC=/path/to/bsc" >&2; \
		exit 127; \
	}

check-yosys: check-board
	@tool='$(firstword $(YOSYS))'; command -v "$$tool" >/dev/null || { \
		echo "$$tool not found; install Yosys or set YOSYS=/path/to/yosys" >&2; \
		exit 127; \
	}

check-pnr: check-board
	@tool='$(firstword $(BOARD_PNR_TOOL))'; command -v "$$tool" >/dev/null || { \
		echo "$$tool not found; install the $(BOARD_FAMILY) nextpnr backend or override BOARD_PNR_TOOL" >&2; \
		exit 127; \
	}

check-pack: check-board
	@tool='$(firstword $(BOARD_PACK_TOOL))'; command -v "$$tool" >/dev/null || { \
		echo "$$tool not found; install the $(BOARD_FAMILY) bitstream packer or override BOARD_PACK_TOOL" >&2; \
		exit 127; \
	}

check-programmer: check-board
	@tool='$(firstword $(PROGRAMMER))'; command -v "$$tool" >/dev/null || { \
		echo "$$tool not found; install a programmer or set PROGRAMMER and PROGRAMMER_FLAGS" >&2; \
		exit 127; \
	}

host: hostsoft

hostsoft:
	@if [ -f "$(HOST_DIR)/Makefile" ]; then \
		$(MAKE) -C "$(HOST_DIR)"; \
	else \
		echo "No host Makefile for $(PROJECT_NAME); skipping host build."; \
	fi

prepare: check-bsc
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)

verilog: prepare
	$(BSC) $(BSCFLAGS_COMMON) $(BSCFLAGS_SYNTH) -remove-dollar \
		-p +:$(BSV_PATH) -verilog -u -g $(TOP_MODULE) $(TOP_SOURCE)
	cp $(BOARD_CONSTRAINTS) $(BUILD_DIR)/
	@for directory in $(RTL_DIRS); do \
		find "$$directory" -maxdepth 1 -type f -name '*.v' -exec cp {} "$(BUILD_DIR)/" \;; \
	done
	@if [ "$(NEEDS_INOUT_FIX)" = "1" ]; then \
		$(PYTHON) "$(INOUT_FIXER)" "$(GENERATED_TOP)"; \
	fi

netlist: verilog check-yosys
	cd $(BUILD_DIR) && $(YOSYS) \
		-p "$(strip $(BOARD_YOSYS_SYNTH) -top $(TOP_MODULE) $(BOARD_YOSYS_FLAGS) -json $(notdir $(JSON_NETLIST))); tee -q -o $(notdir $(YOSYS_REPORT_TEXT)) stat -top $(TOP_MODULE); tee -q -o $(notdir $(YOSYS_REPORT_JSON)) stat -json -top $(TOP_MODULE)" \
		*.v

pnr: netlist check-pnr
	@status=0; \
	$(BOARD_PNR_TOOL) \
		--json $(JSON_NETLIST) \
		--textcfg $(TEXTCFG) \
		--lpf $(BUILD_CONSTRAINTS) \
		--report $(PNR_REPORT_JSON) \
		--log $(PNR_LOG) \
		$(BOARD_PNR_FLAGS) || status=$$?; \
	report_status=0; \
	$(PYTHON) "$(REPORT_GENERATOR)" \
		--project "$(PROJECT_NAME)" \
		--board "$(BOARD)" \
		--top "$(TOP_MODULE)" \
		--yosys-json "$(YOSYS_REPORT_JSON)" \
		--nextpnr-json "$(PNR_REPORT_JSON)" \
		--nextpnr-log "$(PNR_LOG)" \
		--output "$(UTILIZATION_REPORT)" || report_status=$$?; \
	if [ -f "$(UTILIZATION_REPORT)" ]; then \
		printf 'Utilization report: %s\n' "$(UTILIZATION_REPORT)"; \
	fi; \
	if [ $$status -ne 0 ]; then exit $$status; fi; \
	exit $$report_status

bitstream: pnr check-pack
	$(BOARD_PACK_TOOL) $(BOARD_PACK_FLAGS) $(TEXTCFG) $(BITSTREAM)

synth: bitstream
	@printf 'Bitstream: %s\nYosys report: %s\nnextpnr report: %s\nUtilization report: %s\n' \
		'$(BITSTREAM)' '$(YOSYS_REPORT_TEXT)' '$(PNR_REPORT_JSON)' '$(UTILIZATION_REPORT)'

ifeq ($(SIM_BACKEND),bluesim)
bsim: check-bsc
	rm -rf $(BSIM_DIR)
	mkdir -p $(BSIM_DIR)
	$(BSC) $(BSCFLAGS_COMMON) $(BSCFLAGS_BSIM) $(DEBUGFLAGS) \
		-p +:$(BSV_PATH) -sim -u -g $(BSIM_TOP_MODULE) $(BSIM_TOP_SOURCE)
	$(BSC) $(BSCFLAGS_COMMON) $(BSCFLAGS_BSIM) $(DEBUGFLAGS) $(BSIM_CXXFLAGS) \
		-sim -e $(BSIM_TOP_MODULE) -o $(BSIM_DIR)/bsim \
		$(BSIM_DIR)/*.ba $(BSIM_CPPFILES)

else ifeq ($(SIM_BACKEND),iverilog)
bsim: check-bsc
	@for tool in iverilog vvp; do command -v "$$tool" >/dev/null || { echo "$$tool not found; install Icarus Verilog" >&2; exit 127; }; done
	rm -rf $(BSIM_DIR)
	mkdir -p $(BSIM_DIR)
	$(BSC) $(BSCFLAGS_COMMON) $(DEBUGFLAGS) -D BSIM \
		-bdir $(BSIM_DIR) -vdir $(BSIM_DIR) -info-dir $(BSIM_DIR) \
		-p +:$(BSV_PATH) -verilog -u -g $(BSIM_TOP_MODULE) $(BSIM_TOP_SOURCE)
	$(BSC) -verilog -e $(BSIM_TOP_MODULE) -vsim iverilog \
		-p +:$(BSV_PATH) -bdir $(BSIM_DIR) -vdir $(BSIM_DIR) -o $(BSIM_DIR)/bsim
else
$(error Unsupported SIM_BACKEND=$(SIM_BACKEND); use bluesim or iverilog)
endif

runsim: bsim
	cd $(PROJECT_DIR) && $(BSIM_DIR)/bsim 2> output.log | tee system.log
	cd $(PROJECT_DIR) && $(POST_RUN)

program: bitstream check-programmer
	$(PROGRAMMER) $(PROGRAMMER_FLAGS) $(BITSTREAM)

clean:
	rm -rf $(BUILD_DIR) $(BSIM_DIR) $(PROJECT_DIR)/cpp/obj
	rm -f $(PROJECT_DIR)/output.log $(PROJECT_DIR)/system.log