# Pyflate v2: simplified Huffman accelerator comparison

This directory is an independent copy of the current pyflate hardware project.
The v1 design remains unchanged in `hardware/pyflate`.

The active requirements, design decisions, implementation order, equations,
and completion checklist are maintained in `SIMPLIFIED_HUFFMAN_PLAN.md`.
The completed hardware/software explanation is in
`SIMPLIFIED_HUFFMAN_DESIGN.md`.
The beginner-oriented, lesson-by-lesson explanation is in
`HUFFMAN_ACCELERATOR_TUTORIAL.md`.
The new seven-chapter submission report starts at [`report/README.md`](report/README.md).
The parallel Hebrew translation starts at
[`report in hebrew/README.md`](report%20in%20hebrew/README.md).

## Simplified source location

The friend's one-table SystemVerilog source was placed in and developed at:

```text
hardware/pyflate_v2/rtl/huffman_find_simple.sv
```

The active complete hierarchy is `huffman_find_simple_top` -> reservoir plus
six-table wrapper -> six copies of the friend's matcher. The detailed
`huffman_find_accel.sv` remains uninstantiated as a comparison baseline.

If the code is Python, C, Verilog (`.v`), or a testbench rather than
SystemVerilog, keep its original extension and place it under:

```text
hardware/pyflate_v2/friend_code/
```

Tell Codex the resulting path, or paste the code directly in the conversation.

## Comparison baseline

| Item | Path |
|---|---|
| **Comparison-only** detailed 20-bit RTL | `rtl/huffman_find_accel.sv` |
| Friend's simplified RTL | `rtl/huffman_find_simple.sv` |
| Active simplified design/checklist | `SIMPLIFIED_HUFFMAN_PLAN.md` |
| Completed simplified design report | `SIMPLIFIED_HUFFMAN_DESIGN.md` |
| Seven requested report chapters | `report/README.md` |
| Hebrew translation of the seven chapters | `report in hebrew/README.md` |
| Interactive learning tutorial | `HUFFMAN_ACCELERATOR_TUTORIAL.md` |
| **Comparison-only** 20-bit design specification | `HUFFMAN_FIND_ACCELERATOR.md` |
| **Comparison-only** 20-bit MMIO/error constants | `rtl/huffman_find_pkg.sv` |
| **Comparison-only** 20-bit Linux userspace ABI | `sw/huffman_find_uapi.h` |
| 200 MHz target clock constraint | `constraints/huffman_find_simple_top.xdc` |
| Executable reference model | `tools/huffman_reference.py` |
| Reference tests | `tests/test_huffman_reference.py` |
| Simplified matcher RTL testbench | `tests/tb_huffman_find_simple.sv` |
| Streaming top-level RTL testbench | `tests/tb_huffman_find_simple_top.sv` |

## What will be checked

The simplified version does not need all of the production integration logic if
the course expects only a demonstrable hardware kernel. It should, however,
define enough behavior to answer these questions unambiguously:

1. Does it decode the same MSB-first canonical Huffman symbols as
   `HuffmanTable.find_next_symbol(..., False)`?
2. How are tables loaded, including code, length, and decoded symbol widths?
3. How are compressed bits supplied and consumed across byte boundaries?
4. Does it use `valid/ready`, `start/done`, or another precisely defined
   protocol?
5. What happens when no code matches, input ends, or output stalls?
6. Does it switch bzip2 tables from the selector list every 50 symbols, or is
   that explicitly left to a wrapper/software?
7. What clock frequency and initiation interval does it target?
8. Is every construct synthesizable, with no `real`, delays, or unbounded
   loops in the design?
9. Is there a self-checking testbench or a way to compare it with the reference
   model?
10. Which driver, MMIO, or DMA features are actually required by the course,
    and which can be described as future system integration?

The implemented simplification retains a bus-independent ready/valid core and
places AXI4-Lite, DMA, Linux-driver, and Python-extension integration in the
design report rather than implementing platform-specific infrastructure.
