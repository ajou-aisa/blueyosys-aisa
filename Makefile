PROJECTS := basic matmul nn_fc nn_fc_quantized nn_fc_zfpe rms_norm
PROJECT ?= basic
BOARD ?= ulx3s-85f

.PHONY: help verilog netlist pnr bitstream synth host \
	bsim runsim program clean clean-all

help:
	@printf '%s\n' \
		"blueYosys build dispatcher" \
		"  make synth PROJECT=basic BOARD=ulx3s-85f" \
		"  make verilog PROJECT=basic BOARD=ulx3s-85f" \
		"  make bsim PROJECT=basic BOARD=ulx3s-85f" \
		"  make host PROJECT=basic" \
		"Reports are written under projects/<project>/build/."

verilog netlist pnr bitstream synth host bsim runsim program clean:
	@test -d "projects/$(PROJECT)" || { \
		echo "Unknown PROJECT=$(PROJECT)." >&2; \
		exit 2; \
	}
	+$(MAKE) -C "projects/$(PROJECT)" BOARD="$(BOARD)" $@

clean-all:
	@for project in $(PROJECTS); do \
		$(MAKE) -C "projects/$$project" clean; \
	done
