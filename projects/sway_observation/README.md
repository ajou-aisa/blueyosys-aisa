# MARS baseline for blueYosys

Self-contained MARS inference project with the current frozen INT8 PTQ checkpoint. Copy this directory to `blueyosys/projects/sway_observation`, or use the project already included there.

The baseline has 11 dedicated four-lane affine engines, separate normalization/convolution/scan engines, whole-frame registers, and explicit FIFO token handoff. Both Mamba blocks have their own delta projection. The BSV uses numbered stage rules, explicit counters/control registers, and FIFO input/output methods.

Inputs are 320 signed INT8 values in HWC order; each result is 57 signed INT8 coordinates in X19/Y19/Z19 order. Input and output scales are in `model/export/quantization.json`. The UART protocol sends one complete frame, then reads its 57-byte reply. The configured core clock is 100 MHz and UART is 115200 baud.

## Run in blueYosys

Install BSC/Bluesim; generated-Verilog simulation also requires Icarus Verilog. From the blueYosys repository root:

```sh
make runsim PROJECT=sway_observation BOARD=ulx3s-85f
make runsim PROJECT=sway_observation BOARD=ulx3s-85f SIM_BACKEND=iverilog
make verilog PROJECT=sway_observation BOARD=ulx3s-85f
make netlist PROJECT=sway_observation BOARD=ulx3s-85f
make pnr PROJECT=sway_observation BOARD=ulx3s-85f
```

The full FPGA flow uses `make synth PROJECT=sway_observation BOARD=ulx3s-85f` with Yosys, nextpnr-ecp5 and ecppack installed. A 100 MHz configuration alone does not establish timing closure or a physical-board result.

From the Sway repository, the same project runs with:

```sh
make -C hw runsim ROOTDIR=/absolute/path/to/blueyosys
```

## Files and validation

- `HwMain.bsv`, `Top.bsv`: UART adapter, clock crossing, and PLL reset conversion.
- `bsv/`: dedicated-engine baseline compute modules and clock wrapper.
- `model/`: frozen PTQ checkpoint, INT8 export, and provenance.
- `generated/`: combinational parameter tables and fixed golden fixtures.
- `sim/TbSway.bsv`: 14-frame regression checking all 798 outputs, input bubbles, output stalls, repeated-frame state reset, and trailing output.
- `reference/`: standalone integer reference, coefficient/fixture generator, and simulation checker.
- `results/`: validation records for this baseline and checkpoint.

The integer reference measures **8.3579082742 cm** RMSE on 7,984 MARS test frames. The paired PTQ software value is **8.3563735004 cm**. The difference comes from exact rational integer range normalization; weights, scales and fitted PWL functions are frozen. See [reference report](generated/reference_report.json) and [software contract verification](generated/software_contract_verification.json).

Simulation and netlist checks passed with BSC 2025.07, Icarus 12.0, and Yosys 0.33: Bluesim and generated Verilog agree on all 798 outputs and event cycles; the restored core has the same 115-rule compiler schedule as the first baseline. Project-top Verilog generation and ECP5 netlist synthesis pass, with zero Yosys check problems. See [validation](results/validation.json).

The physical build fails during placement on ULX3S-85F: nextpnr requires **145,239 / 83,640 TRELLIS_COMB sites (173.65%)**. The actual core clock receives the 100 MHz constraint, but routing is never reached, so no routed Fmax or slack is available. See the [physical result](results/physical/result.json) and [nextpnr log](results/physical/nextpnr.log). Physical-board operation has not been tested.

Normal hardware builds use the checked-in tables and fixtures and need neither dataset downloads nor PyTorch. To regenerate coefficients and fixtures from the included model, install NumPy/PyTorch and run `python3 reference/generate.py` in this directory. Add `--data /path/to/mars` to recompute the full held-out integer-reference metric. The generator performs no training or calibration.
