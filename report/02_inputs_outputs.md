# 2. Inputs, outputs, wires, memory, frequency, and power

[Back to report index](README.md)

## 2.1 Interface conventions

This chapter describes the ports of the active top-level module
`huffman_find_simple_top` with its default benchmark parameters:

```systemverilog
NUM_TABLES    = 6
NUM_ENTRIES   = 147
KEY_WIDTH     = 16
SYMBOL_WIDTH  = 9
MAX_SELECTORS = 2966
```

All functional transfers are synchronous to the rising edge of `clk`.
`rst_n` asserts asynchronously low; the surrounding system must synchronize its
deassertion to `clk`. There is one clock domain in the accelerator core.

Streaming interfaces use ready/valid:

```text
transfer occurs on a rising edge iff valid = 1 AND ready = 1
```

The producer must hold `valid` and all associated payload signals stable until
the transfer occurs. The receiver may apply backpressure by lowering `ready`.

## 2.2 Derived widths

For an unsigned field representing values `0` through `N-1`, the minimum width
is:

```text
W [bits] = ceil(log2(N))
```

Applying this to the default design:

```text
table ID width       = ceil(log2(6))    = 3 bits
table address width  = ceil(log2(147))  = 8 bits
selector address     = ceil(log2(2966)) = 12 bits
selector count width = ceil(log2(2967)) = 12 bits
reservoir count      = ceil(log2(32+1)) = 6 bits
```

The address fields can encode illegal values. For example, eight address bits
represent 0–255 although only 0–146 are legal. That is why explicit bounds
checks are required in the RTL.

`SYMBOL_WIDTH=9` represents 0–511. The benchmark uses at most 147 alphabet
indices, so eight bits would mathematically suffice; nine bits are retained by
the active design as interface margin and to match the existing project
representation. Values above the configured alphabet/EOB range are not useful
benchmark symbols.

## 2.3 Complete top-level port table

### Clock and reset

| Signal | Dir. | Width | Meaning | Timing requirement |
|---|---:|---:|---|---|
| `clk` | in | 1 | Core clock | Target 200 MHz, 5.000 ns period |
| `rst_n` | in | 1 | Active-low reset | May assert asynchronously; must deassert synchronously to `clk` |

### Configuration ports

Configuration is accepted only while the core is idle and `cfg_ready=1`.

| Signal | Dir. | Width | Legal value | Meaning |
|---|---:|---:|---|---|
| `cfg_ready` | out | 1 | 0/1 | High when dictionary/selector writes may be accepted |
| `dict_wr_en` | in | 1 | Pulse/high for one transfer edge | Programs or invalidates one table entry |
| `dict_wr_table` | in | 3 | 0–5 | Destination table bank |
| `dict_wr_addr` | in | 8 | 0–146 | Entry address within the bank |
| `dict_wr_code` | in | 16 | Right-aligned code | Canonical Huffman code; hardware aligns it to the MSB side |
| `dict_wr_symbol` | in | 9 | Normally 0–146 | Decoded symbol returned on a match |
| `dict_wr_len` | in | 5 | 0–16 | Code length; zero invalidates the addressed slot |
| `selector_wr_en` | in | 1 | Pulse/high for one transfer edge | Writes one selector entry |
| `selector_wr_addr` | in | 12 | 0–2965, contiguous frontier | Selector index |
| `selector_wr_table` | in | 3 | 0–5 | Table selected for the corresponding 50-symbol group |

The simplified programming ports have no individual `valid/ready` pair. Their
contract is instead:

```text
configuration_write = cfg_ready AND write_enable
```

An MMIO/config-loader wrapper must issue one stable write pulse on one rising
edge and must not assert a write together with `start`. Illegal writes set a
pending configuration error and cause the next start to be rejected.

Selector entries must be written in ascending contiguous order when extending
the loaded region. Rewriting an earlier entry is permitted. For safe table
reuse, software should program all 147 addresses in each bank, writing
`dict_wr_len=0` for absent symbols so stale valid entries cannot survive from a
previous job.

### Job-control inputs

| Signal | Dir. | Width | Legal value | Meaning |
|---|---:|---:|---|---|
| `start` | in | 1 | One pulse while idle | Latches job fields and starts one payload |
| `start_bit` | in | 3 | 0–7 | Number of leading bits discarded from the first source byte |
| `selector_count` | in | 12 | 1–2966 | Number of valid table selectors |
| `eob_symbol` | in | 9 | 0–146; benchmark uses `symbols_in_use-1` | Symbol that terminates the Huffman block |
| `symbol_capacity` | in | 32 | At least 1 | Maximum number of accepted outputs, including EOB |

These fields must remain stable during the `start` edge. The top captures them,
so they may change afterward without affecting the active job.

### Compressed-byte input stream

| Signal | Dir. | Width | Meaning |
|---|---:|---:|---|
| `byte_valid` | in | 1 | Producer is presenting a byte |
| `byte_ready` | out | 1 | Reservoir has room to accept it |
| `byte_data` | in | 8 | Compressed byte; bit 7 is processed first |
| `byte_last` | in | 1 | This accepted byte is the final byte available to the job |

A byte transfers when:

```text
byte_fire = byte_valid AND byte_ready
```

`byte_last` is part of the byte payload and is meaningful only on a transfer.
The source may be longer than the exact Huffman payload because EOB and
`bits_consumed` define logical consumption. It must nevertheless be a bounded,
mapped buffer, and the final mapped byte must carry `byte_last=1`.

### Decoded-symbol output stream

| Signal | Dir. | Width | Meaning |
|---|---:|---:|---|
| `symbol_valid` | out | 1 | A stable result is available |
| `symbol_ready` | in | 1 | Consumer can accept the result |
| `symbol` | out | 9 | Decoded Huffman alphabet index |
| `code_length` | out | 5 | Number of real compressed bits used by this result, 1–16 |
| `table_id` | out | 3 | Table bank that produced the result, 0–5 |
| `symbol_eob` | out | 1 | Current valid result equals the configured EOB symbol |

A symbol transfers when:

```text
symbol_fire = symbol_valid AND symbol_ready
```

The output register holds `symbol`, `code_length`, `table_id`, and EOB meaning
stable while `symbol_valid=1` and `symbol_ready=0`. EOB is included as an output
symbol and in `symbols_produced`.

For a DMA implementation only the nine-bit `symbol` must be written to memory.
`code_length` and `table_id` may remain debug/trace signals because the aggregate
`bits_consumed` counter supplies the software-visible bit advance.

### Status and counters

| Signal | Dir. | Width | Meaning |
|---|---:|---:|---|
| `busy` | out | 1 | One job is active |
| `done` | out | 1 | One-cycle terminal pulse after success or error |
| `error` | out | 1 | Terminal job failed; remains available until next start/reset |
| `error_code` | out | 8 | Encoded failure reason |
| `bits_consumed` | out | 32 | Sum of accepted code lengths after `start_bit` |
| `symbols_produced` | out | 32 | Accepted output symbols, including EOB |
| `cycle_count` | out | 64 | Core clocks spent busy |
| `input_stall_cycles` | out | 32 | Cycles when a byte could be accepted but none was valid |
| `output_stall_cycles` | out | 32 | Cycles when a symbol was valid but not ready |

Because `done` is a pulse, an external MMIO adapter must capture it into a sticky
status bit and clear that bit on software acknowledgement or next start.

## 2.4 Important internal wires

The following interconnect signals explain how the modules compose. They are not
external pins of the core.

| Signal | Width | Source -> destination | Purpose |
|---|---:|---|---|
| `active_table_q` | 3 | top register -> six-table wrapper | Registered bank choice for normal lookup timing |
| `selector_current_valid` | 1 | top combinational check | Proves selector index/count/table are legal |
| `reservoir_peek_bits` | 16 | reservoir -> matcher | MSB-aligned next-bit window |
| `reservoir_peek_valid` | 1 | reservoir -> top | Full window, or legal final partial window, is exposed |
| `reservoir_valid_bits` | 6 | reservoir -> top | Number of real bits; rejects a match using zero padding |
| `reservoir_last_seen` | 1 | reservoir -> top | Final input byte has been accepted |
| `matcher_lookup_valid` | 1 | top -> selected matcher | Requests a match only when no previous result is pending |
| `matcher_lookup_ready` | 1 | matcher -> top | Selected output register can accept a request |
| `matcher_result_valid` | 1 | matcher -> top | Registered match/no-match result exists |
| `matcher_result_ready` | 1 | top -> matcher | Removes an accepted result or drains a terminal bad result |
| `matcher_found` | 1 | matcher -> top | At least one table entry matched |
| `matcher_symbol` | 9 | matcher -> top | Chosen decoded symbol |
| `matcher_len` | 5 | matcher -> top/reservoir | Chosen code length and subsequent consume amount |
| `reservoir_consume_valid` | 1 | output handshake -> reservoir | Requests removal of `matcher_len` bits |
| `reservoir_consume_ready` | 1 | reservoir -> top | Confirms length is nonzero and no greater than real bit count |
| `output_fire` | 1 | top handshake result | Atomic event that advances bits, symbol count, group count, and possibly selector |
| `dict_cfg_error` | 1 | six-table wrapper -> top | Captures an illegal dictionary programming request |

The critical correctness rule is that all decode state changes are tied to
`output_fire`, not merely to `symbol_valid`. Therefore a stalled output cannot
advance the reservoir or the table selector.

## 2.5 Storage and memory size

### CAM table state

Each direct-match entry stores:

```text
B_entry = B_pattern + B_mask + B_symbol + B_length + B_valid
        = 16 bits + 16 bits + 9 bits + 5 bits + 1 bit
        = 47 bits/entry
```

For six tables with 147 entries each:

```text
N_CAM_entries = 6 tables * 147 entries/table = 882 entries

B_CAM = 882 entries * 47 bits/entry
      = 41,454 bits
      = 5,181.75 byte-equivalents
      = 5.060 KiB when perfectly bit-packed
```

The fractional byte is acceptable as a bit-count calculation; a physical FPGA
mapping uses LUTs, flip-flops, distributed RAM, or whole memory primitives and
will consume more granularity than a perfectly packed byte array.

Per bank:

```text
B_bank = 147 * 47 = 6,909 bits
```

### Selector storage

```text
B_selectors = 2,966 entries * 3 bits/entry
            = 8,898 bits
            = 1,112.25 byte-equivalents
```

### Explicit datapath/control state

The most important additional registered state is approximately:

| State | Bits |
|---|---:|
| Reservoir data, count, offset, first/last flags | `32+6+3+1+1 = 43` |
| Six matcher result buffers | `6*(valid+found+symbol+len) = 6*(1+1+9+5) = 96` |
| Latched selector/job/control fields | approximately 88 |
| Status and visible counters | approximately 203 |
| **Subtotal beyond CAM/selectors** | **approximately 430** |

Thus a bit-level lower-bound inventory is:

```text
B_state,lower = 41,454 + 8,898 + 430
              = 50,782 bits
              = 6,347.75 byte-equivalents
              approximately 6.20 KiB bit-packed
```

This is **not** an FPGA area report. It excludes clock trees, reset routing,
decode/mux logic, compare and priority logic, carry structures, placement
fragmentation, and any MMIO/DMA wrapper. The 882 parallel masked comparisons are
likely more important to LUT area than the raw stored-bit count.

### External buffer sizes for the measured workload

The fixed workload observations used in the project are:

```text
compressed source           = 67,562 bytes
decoded Huffman symbols N   = 148,271 symbols including EOB
selectors                   = 2,966 entries
```

With the proposed packed ABI:

```text
table image = 6 * 147 * 4 bytes = 3,528 bytes
selector image = 2,966 * 1 byte = 2,966 bytes
configuration image total = 6,494 bytes

destination = 148,271 symbols * 2 bytes/symbol
            = 296,542 bytes
```

Source, configuration image, and destination are system-memory buffers, not
storage inside the current core RTL.

## 2.6 Clock target and timing calculation

### Frequency-period conversion

Clock frequency and period are reciprocals:

```text
T_clk [s/cycle] = 1 / f_clk [cycles/s]
```

At the target `f_clk = 200 MHz = 200,000,000 cycles/s`:

```text
T_clk = 1 / 200,000,000 s
      = 5.000e-9 s
      = 5.000 ns/cycle
```

The supplied XDC asks an FPGA implementation tool to analyze this requirement:

```tcl
create_clock -name core_clk -period 5.000 [get_ports {clk}]
```

It does not make the circuit operate at 200 MHz by itself.

### Setup timing

For every register-to-register path, a simplified setup requirement is:

```text
T_cq,max + T_logic,max + T_route,max + T_setup + T_uncertainty <= T_clk
```

Equivalently:

```text
T_arrival  = T_cq,max + T_logic,max + T_route,max
T_required = T_clk - T_setup - T_uncertainty
setup_slack = T_required - T_arrival
```

Positive slack meets the target. Negative slack means that path is too slow.

Illustrative example only:

```text
post-route critical path, including required margins = 6.4 ns
target period                                      = 5.0 ns
setup slack = 5.0 ns - 6.4 ns = -1.4 ns            (fails)

Fmax approximately = 1 / 6.4 ns
                   = 156.25 MHz
```

At 156.25 MHz, the design should not be reported as a 200 MHz implementation;
either the clock target must be lowered or the critical path must be changed.

### Hold timing

Making a path faster does not automatically guarantee correct hold timing. A
simplified minimum-delay condition is:

```text
T_cq,min + T_logic,min + T_route,min >= T_hold + T_skew
```

Implementation tools normally repair hold violations by adding route/data
delay; changing the clock period does not directly solve them.

### Expected critical paths

The likely timing risks, to be confirmed by a post-route report, are:

1. stored table/result state -> 16-bit mask/equality comparisons -> 147-entry
   shortest-first priority selection -> matcher result register;
2. 32-bit variable left shift plus bit-count/refill selection -> reservoir
   registers; and
3. on each 50-symbol boundary only, selector index increment -> selector-memory
   read -> range test -> registered active table.

Registering `active_table_q` has already removed selector memory from the normal
per-symbol CAM path. If the boundary path is still slow, a prefetched next
selector or synchronous selector RAM stage can be added. If the CAM/priority
path is slow, a balanced priority tree, partitioned CAM, or canonical-range
decoder is preferable to blindly accepting negative slack.

## 2.7 Throughput and latency units

The complete top has no-stall initiation interval:

```text
II = 2 cycles/symbol
```

Therefore:

```text
symbol throughput [symbols/s] = f_clk [cycles/s] / II [cycles/symbol]
```

At 200 MHz:

```text
throughput = 200,000,000 / 2
           = 100,000,000 symbols/s
           = 100 Msymbol/s
```

This is the internal lookup/consume limit. The byte source can supply:

```text
input bandwidth = 1 byte/cycle * 200,000,000 cycles/s
                = 200 MB/s
                = 1.6 Gbit/s
```

The output emits at most one symbol every two cycles. If packed into two bytes:

```text
output bandwidth = 100,000,000 symbols/s * 2 bytes/symbol
                 = 200 MB/s
```

A real DMA engine must sustain both directions concurrently or add stalls that
increase job time.

## 2.8 Power draw: what can and cannot be calculated now

### Required distinction

The RTL does not determine a trustworthy watt value. Dynamic and static power
depend on the selected FPGA/ASIC technology, voltage, implementation mapping,
routing capacitance, clock network, temperature, and real switching activity.
Therefore the technically correct current specification is:

```text
expected core power draw = TBD after synthesis, placement/routing,
                           and activity-based power analysis
```

The report uses `0.40 W` only as a **planning example**, not as a measured or
predicted value. A numerical “expected” value without a target device would give
false precision.

### Dynamic and static components

A common first-order CMOS model is:

```text
P_total [W] = P_static [W] + P_dynamic [W]

P_dynamic [W] approximately = sum_j(alpha_j * C_j [F] * V_j^2 [V^2]
                                      * f_j [1/s])
```

where:

- `alpha_j` is the average transition activity of node/group `j` per cycle;
- `C_j` is its effective switched capacitance;
- `V_j` is its supply voltage; and
- `f_j` is its switching/clock frequency.

Dimensional check:

```text
F * V^2 * 1/s = (C/V) * V^2 / s = C*V/s = J/s = W
```

For an FPGA, the vendor power tool obtains effective capacitance from the placed
netlist and routing. A VCD or SAIF trace from a representative test provides
activity. Recommended flow:

```text
choose device and voltage
-> synthesize
-> place and route at 5 ns constraint
-> simulate benchmark vectors
-> export VCD/SAIF activity
-> run vendor power analysis
-> report static, clocks, logic, signals, memories, I/O, and total watts
```

### Energy per job

Energy combines power and active time:

```text
E_job [J/job] = P_average [W] * T_job [s/job]
```

Illustrative example only, using assumed `P_average=0.40 W` and the analytical
no-stall target-time `T_job=1.482725 ms`:

```text
E_job = 0.40 J/s * 0.001482725 s/job
      = 0.00059309 J/job
      = 0.593 mJ/job
```

Sensitivity, still illustrative:

| Assumed average core power | Energy at 1.482725 ms |
|---:|---:|
| 0.20 W | 0.297 mJ |
| 0.40 W | 0.593 mJ |
| 0.80 W | 1.186 mJ |

These values teach the calculation and bound a planning discussion; none is a
post-implementation power result.

### Energy effect of frequency

If voltage and work are fixed and leakage is ignored, dynamic power grows
approximately linearly with frequency while job time falls inversely:

```text
P_dynamic proportional to f
T_job proportional to 1/f
E_dynamic = P_dynamic * T_job approximately constant
```

Real energy is not perfectly constant because leakage acts for less time at
higher frequency, clock/routing activity differs, voltage may need to rise, and
memory/DMA overhead may not scale. That is why energy must be measured from an
implemented workload rather than inferred from frequency alone.
