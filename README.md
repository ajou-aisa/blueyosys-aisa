# blueYosys

A Bluespec SystemVerilog development environment for Lattice ECP5 FPGA kernels. It provides a shared flow from simulation to bitstream generation, with reusable libraries and board integration.

**Current target:** ULX3S-85F (`BOARD=ulx3s-85f`). The ICE40 backend is reserved for future support.

## Requirements

Use Linux with GNU Make, GCC/G++, Python 3, and pthread support. Install Bluespec Compiler (`bsc`) and Bluesim separately. [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) supplies Yosys, `nextpnr-ecp5`, `ecppack`, and `openFPGALoader`; select the archive for your host architecture and enable its `environment` script.

Project-specific dependencies are listed in each project's README. Sway uses the checked-in model tables for normal builds; regenerating its reference data requires NumPy and PyTorch.

## How to build

Run commands from the repository root. Replace `basic` with the desired project name.

| Task | Command |
| --- | --- |
| Generate Verilog | `make verilog PROJECT=basic BOARD=ulx3s-85f` |
| Synthesize the netlist | `make netlist PROJECT=basic BOARD=ulx3s-85f` |
| Place and route | `make pnr PROJECT=basic BOARD=ulx3s-85f` |
| Generate the bitstream | `make bitstream PROJECT=basic BOARD=ulx3s-85f` |
| Complete hardware build | `make synth PROJECT=basic BOARD=ulx3s-85f` |
| Build the host application | `make host PROJECT=basic` |
| Compile Bluesim | `make bsim PROJECT=basic BOARD=ulx3s-85f` |
| Compile and run Bluesim | `make runsim PROJECT=basic BOARD=ulx3s-85f` |
| Program the FPGA | `make program PROJECT=basic BOARD=ulx3s-85f` |

Each command builds its prerequisites. `synth` runs the hardware flow through bitstream generation; it does not program the board.

```text
BSV -> Verilog -> Yosys netlist -> nextpnr placement/routing -> Bitstream
```

To build directly from a project, use `make -C projects/basic synth BOARD=ulx3s-85f`.

Programming defaults to `ujprog`. To use openFPGALoader:

```sh
make program PROJECT=basic BOARD=ulx3s-85f \
  PROGRAMMER=openFPGALoader PROGRAMMER_FLAGS="-b ulx3s"
```

## Project layout

```text
projects/   Kernels and optional host applications
lib/        Shared BSV, BSC runtime RTL, and C++/BDPI libraries
fpga/       FPGA-family arithmetic backends
boards/     Board profiles, interfaces, clocks, and constraints
scripts/    Verilog post-processing and build reports
build.mk    Shared build rules
Makefile    Project dispatcher
```

| Project | Purpose |
| --- | --- |
| `basic` | UART, SDRAM, and floating-point MAC example |
| `matmul` | 4x4 floating-point matrix multiplication |
| `nn_fc` | Fully connected neural-network computation |
| `nn_fc_quantized` | INT4/INT8/INT16 fully connected computation |
| `nn_fc_zfpe` | Fully connected computation with ZFP-style compression |
| [sway_observation](projects/sway_observation/README.md) | MARS INT8 PTQ model and dedicated-engine baseline |

To add a project, copy the closest example into `projects/`, set `ROOTDIR` and `PROJECT_NAME` in its Makefile, include `$(ROOTDIR)/build.mk`, and register the project in the root Makefile.

## Build results

Hardware outputs are written to `projects/<project>/build/`:

```text
mkTop.yosys.rpt        Synthesis statistics
mkTop.yosys.json       Machine-readable synthesis statistics
mkTop.nextpnr.log      Placement, routing, and timing log
mkTop.nextpnr.json     Machine-readable utilization and timing
mkTop.utilization.rpt  Combined resource and timing summary
```

Timing failure returns an error even when a summary report is generated. A saved report alone does not mean the build passed.

Clean one project with `make clean PROJECT=<name>`, or all included projects with `make clean-all`.

## Notes

Maintained by Se-Min Lim. Keep project logic separate from shared libraries and board-specific code.

Keep READMEs concise, focused on essential information, and easy for readers to follow. Do not create new `.md` files without the user's explicit permission. Do not create `.gitignore` files.
