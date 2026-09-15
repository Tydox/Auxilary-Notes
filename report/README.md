# Pyflate Huffman accelerator report

This report describes the benchmark-specific, 16-bit, six-table Huffman
accelerator whose top-level module is `huffman_find_simple_top`. It is split into
the seven requested chapters so that material can be reviewed or removed one
section at a time.

## Report chapters

1. [Hardware description](01_hardware_description.md)
2. [Inputs, outputs, widths, memory, frequency, and power](02_inputs_outputs.md)
3. [Hardware architecture and operation](03_hardware_architecture.md)
4. [Hardware/software interface](04_hardware_software_interface.md)
5. [Acceleration justification and performance estimate](05_acceleration_justification.md)
6. [Block-diagram alternatives](06_block_diagrams.md)
7. [Performance, area, frequency, and power tradeoffs](07_performance_area_power_tradeoffs.md)

## Design authority and scope

The active implementation hierarchy is:

```text
huffman_find_simple_top
|-- huffman_bit_reservoir
`-- huffman_find_six_table
    `-- 6 x hardware_dictionary_accelerator
```

The authoritative active RTL files are:

- [`huffman_find_simple_top.sv`](../rtl/huffman_find_simple_top.sv): complete
  bus-independent accelerator top, job control, counters, and error handling.
- [`huffman_bit_reservoir.sv`](../rtl/huffman_bit_reservoir.sv): byte-to-bit
  conversion and variable-length consumption.
- [`huffman_find_six_table.sv`](../rtl/huffman_find_six_table.sv): six physical
  Huffman-table banks and selected-bank routing.
- [`huffman_find_simple.sv`](../rtl/huffman_find_simple.sv): one 147-entry
  content-addressed matcher.
- [`huffman_find_simple_top.xdc`](../constraints/huffman_find_simple_top.xdc):
  200 MHz analytical clock target.

`huffman_find_accel.sv`, `huffman_find_pkg.sv`, `HUFFMAN_FIND_ACCELERATOR.md`,
and `sw/huffman_find_uapi.h` belong to an older, independent 20-bit
canonical-range proposal. `pyflate_accel_uapi.h` describes a full decompressor.
Neither interface is the ABI of the active 16-bit CAM design. They are retained
only as alternatives for comparison.

## Evidence labels

Numbers in this report are deliberately labeled so that targets are not
mistaken for measurements:

| Label | Meaning |
|---|---|
| **Measured software** | Obtained from a checked-in `timing.json`, folded stack, or `perf_stat.txt` file. |
| **Workload observation** | Counted from the fixed benchmark input or the reference model. |
| **RTL fact** | Follows directly from parameters, ports, or state in the active RTL. |
| **Analytical estimate** | Computed from an explicit architecture model and stated assumptions. |
| **Target** | A requirement supplied to implementation tools; not yet demonstrated. |
| **Illustrative example** | Demonstrates a formula with assumed values; not a prediction. |

## What is and is not implemented

Implemented in SystemVerilog:

- six programmable 147-entry, 16-bit Huffman match banks;
- shortest-code-first match selection;
- a 32-bit MSB-first streaming reservoir;
- table selection every 50 accepted symbols;
- registered ready/valid result handling and backpressure;
- EOB detection, capacity checking, terminal errors, and performance counters;
- programming bounds checks and a registered active selector; and
- self-checking unit and top-level testbench source.

Specified, but intentionally platform-dependent and therefore not implemented:

- an AXI4-Lite or other MMIO slave;
- memory-to-stream and stream-to-memory DMA engines;
- an interrupt controller connection;
- a Linux kernel driver and Python C extension; and
- device-specific synthesis, place-and-route, timing, area, and power results.

The course objective is to demonstrate a coherent hardware/software
co-design—not to claim tapeout readiness. The RTL is detailed enough to expose
the datapath, control, protocol, error, and timing decisions. The integration
chapter defines the missing platform wrapper clearly enough to implement later.

## Timing-related RTL updates made with this report

- `active_table_q` now registers selector 0 at start and the next selector only
  on an accepted 50-symbol boundary. This removes selector memory from the
  normal CAM critical path without changing the existing two-cycle initiation
  interval.
- A 5.000 ns `create_clock` constraint now records the 200 MHz target while
  explicitly warning that a constraint is not achieved timing evidence.
- Active-low reset comments now require synchronized deassertion to avoid
  recovery/removal problems.
- Inactive banks are described accurately as operand-isolated, not physically
  clock-gated, and unpacked table-array ranges are explicit for readability.

The remaining likely critical paths are the nested comparison/priority network,
the variable reservoir consume/refill path, and the boundary-only selector read.

Verification status on 2026-09-14: workload characterization completed and all
six Python reference tests passed. No HDL compiler/simulator or physical
implementation tool was available, so RTL compilation, simulation, synthesis,
timing closure, area, and power remain unverified.

## Executive conclusion

The design trades substantial replicated comparison logic for a simple and
direct mapping of `HuffmanTable.find_next_symbol`. With no stream stalls, the
complete feedback top has an initiation interval of two clocks per symbol. At
the **target** 200 MHz clock and for the observed 148,271-symbol workload, the
analytical core time is approximately 1.483 ms. Depending on whether only the
Python function's self time or its useful reservoir-inclusive subtree is
credited to the accelerator, Amdahl projections give about 1.135x to 1.626x
whole-benchmark speedup before real integration overhead. These are projections,
not measured hardware results.
