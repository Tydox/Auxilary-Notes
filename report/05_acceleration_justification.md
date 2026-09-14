# 5. Acceleration justification and performance estimate

[Back to report index](README.md)

## 5.1 Why `HuffmanTable.find_next_symbol` is a good candidate

The function is attractive for hardware acceleration for five independent
reasons.

### It is hot and repeated

The measured block performs 148,271 Huffman lookups, including EOB. Sampling of
the full original run attributes approximately:

- **12.11% / 80.21 ms** to the Python function's own work; and
- **38.71% / 256.34 ms** to the function plus its nested bit-reader work.

The self value maps most directly to a table-match engine. The inclusive value
maps to the actual proposed boundary—matcher plus hardware bit reservoir.

### Its state and bounds are small and predictable

The target workload needs six tables, 147 entries/table, code lengths no greater
than 16, and one selector every 50 raw symbols. Fixed bounds are well suited to
static hardware arrays, fixed-width arithmetic, and deterministic control.

### It contains fine-grained parallel work

Python checks candidate lengths/entries sequentially and performs object,
function-call, masking, and loop control work. A CAM-style circuit compares 147
entries in a selected bank at the same time, then reduces match results.

### It streams cleanly

Compressed bytes enter in order; decoded symbols leave in order. Apart from the
matched-length feedback, no global random memory access is required. A
ready/valid reservoir allows DMA and lookup to overlap.

### It can be batched

One job covers a whole Huffman block rather than one symbol. This amortizes
Python/C, driver, MMIO, interrupt, and DMA setup overhead across 148,271 results.

## 5.2 Why the software optimization is useful but not hardware

The optimized Python implementation prebuilds dictionaries indexed by
`(length, code)` and scans only the unique code lengths. That is a good
algorithmic improvement and an excellent golden/reference implementation. It
reduced the latest comparable mean from 662.237 ms to 430.018 ms, or 1.540x.

It is nevertheless still software because it:

- executes Python bytecode and object/dictionary operations;
- processes one symbol after another on the CPU;
- uses CPU registers/caches rather than dedicated comparator fabric;
- has no fixed streaming protocol, reservoir hardware, DMA, MMIO, or driver;
- cannot compare many table entries spatially on one clock edge; and
- continues to pay one Python lookup call for each of 148,271 symbols.

The optimized code gives two useful hardware ideas: precompute a representation
before the hot loop, and reduce unnecessary candidate lengths. It does not
replace the need to design the datapath, state, handshakes, bit ownership, table
switching, and integration boundary.

## 5.3 Measurement sources and method

### Baseline wall time

The primary baseline is the 60-value regular original run:

- [`results/pyflate/original/original results full run/timing.json`](../../../results/pyflate/original/original%20results%20full%20run/timing.json)
- [`run_metadata.txt`](../../../results/pyflate/original/original%20results%20full%20run/run_metadata.txt)

For measured values `t_k` in seconds:

```text
mean [s] = (1/n) * sum(k=1..n, t_k)
mean [ms] = 1000 ms/s * mean [s]
```

The 60 measured values give:

| Statistic | Original full run |
|---|---:|
| Count | 60 values |
| Arithmetic mean | 662.236860 ms |
| Median | 659.091945 ms |
| Minimum | 652.654428 ms |
| Maximum | 736.232706 ms |
| Sample standard deviation | 11.667433 ms |

Warmups are not included in these 60 reported values.

The exact workload counters were obtained by
[`tools/characterize_workload.py`](../tools/characterize_workload.py) and are
asserted by [`tests/test_huffman_reference.py`](../tests/test_huffman_reference.py):
148,271 lookup calls including EOB and 399,360 final decompressed bytes. Since
EOB terminates rather than advancing to another group, the selector requirement
is consistent with:

```text
N_non_EOB = 148,271 - 1 = 148,270 symbols
N_selectors = floor(N_non_EOB / 50 symbols/selector) + 1 EOB group
            = floor(148,270 / 50) + 1
            = 2,966 selectors

equivalently for this stream:
N_selectors = ceil(148,271 total symbols / 50) = 2,966
```

### Profile shares

The function shares come from the adjacent folded-stack profile:

- [`speedscope.folded`](../../../results/pyflate/original/original%20results%20full%20run/speedscope.folded)
- [`perf_report.txt`](../../../results/pyflate/original/original%20results%20full%20run/perf_report.txt)

Stacks were filtered to samples containing the benchmark frame, producing a
denominator of 38,010 weighted samples. The metadata records a 199 Hz
`cpu-clock` profile with frame-pointer call graphs; the report records about 41K
samples and zero lost samples for the broader recording.

For a function with self-sample count `s_i`:

```text
p_i [%] = 100 * s_i / 38,010

estimated self time_i [ms]
    = baseline mean [ms] * s_i / 38,010
```

This converts a sample fraction into an estimated share of the separately
measured mean. It is not a direct per-function stopwatch.

## 5.4 Original-code bottleneck table

The table below is a **self-time partition**: each filtered sample is assigned
to the deepest Python frame, so rows may be summed and total 100%. “Other”
collects the remaining small frames.

| Function/deepest Python frame | Self samples | Share of total | Estimated time |
|---|---:|---:|---:|
| `decode_huffman_block` | 10,064 | 26.477% | 175.34 ms |
| `move_to_front` | 5,824 | 15.322% | 101.47 ms |
| `HuffmanTable.find_next_symbol` | 4,604 | 12.113% | 80.21 ms |
| `bwt_transform` | 3,765 | 9.905% | 65.60 ms |
| `RBitfield.readbits` | 3,001 | 7.895% | 52.29 ms |
| `RBitfield.snoopbits` | 2,874 | 7.561% | 50.07 ms |
| `bwt_reverse` | 2,759 | 7.259% | 48.07 ms |
| `_mask` | 2,179 | 5.733% | 37.96 ms |
| `_read` | 970 | 2.552% | 16.90 ms |
| `_more` | 845 | 2.223% | 14.72 ms |
| `needbits` | 471 | 1.239% | 8.21 ms |
| `bzip2_main` | 438 | 1.152% | 7.63 ms |
| Other | 216 | 0.568% | 3.76 ms |
| **Total** | **38,010** | **100.000%** | **662.24 ms** |

Example calculation for `find_next_symbol`:

```text
p_self = 100 * 4,604 samples / 38,010 samples
       = 12.1126%

T_self = 662.236860 ms * 4,604 / 38,010
       = 80.2141 ms
```

The largest self frame is the surrounding decode logic, but accelerating all of
it would require a much broader bzip2 engine. `find_next_symbol` offers a strong
combination of material time, 148,271 repetitions, bounded state, and a clean
stream interface.

## 5.5 `find_next_symbol` subtree breakdown

Inclusive profiling counts a parent whenever it appears anywhere in the stack.
Inclusive rows overlap and must **not** be added to an all-function table.
Within the `find_next_symbol` subtree, however, the exclusive components below
partition its 14,713 samples:

| Work within lookup subtree | Samples | Estimated time |
|---|---:|---:|
| `find_next_symbol` own matcher/loop work | 4,604 | 80.21 ms |
| `snoopbits` | 2,874 | 50.07 ms |
| `readbits` | 2,860 | 49.83 ms |
| `_mask` | 2,127 | 37.06 ms |
| `_read` | 956 | 16.66 ms |
| `_more` | 830 | 14.46 ms |
| `needbits` | 462 | 8.05 ms |
| **Inclusive lookup subtree** | **14,713** | **256.34 ms** |

Inclusive fraction:

```text
p_inclusive = 14,713 / 38,010
            = 0.38708235
            = 38.708235%

T_inclusive = 662.236860 ms * 14,713 / 38,010
            = 256.3402 ms

T_children = T_inclusive - T_self
           = 256.3402 - 80.2141
           = 176.1261 ms
```

This breakdown justifies the bit-reservoir wrapper: a bare comparator replaces
mainly 80.21 ms of own work, whereas a batched reservoir-plus-matcher can replace
much of the 256.34 ms subtree.

## 5.6 Analysis of every checked-in timing/profile set

The following table summarizes all original/optimized timing result directories.
Single-value runs are useful smoke tests but too noisy for a primary mean.

| Implementation/result set | Measured values | Mean | Filtered profile samples | `find_next_symbol` self | Inclusive subtree | Use in report |
|---|---:|---:|---:|---:|---:|---|
| [Original root/debug](../../../results/pyflate/original/timing.json) | 1 | 695.254 ms | 452 | 14.381% | 38.053% | Diagnostic only |
| [Original full regular](../../../results/pyflate/original/original%20results%20full%20run/timing.json) | 60 | 662.237 ms | 38,010 | 12.113% | 38.708% | Primary original baseline |
| [Optimized 13-09](../../../results/pyflate/optimized/2026-09-12-13-09/timing.json) | 20 | 436.035 ms | 9,664 | 15.004% | 40.284% | Earlier optimized run |
| [Optimized 14-09](../../../results/pyflate/optimized/2026-09-12-14-09/timing.json) | 60 | 431.718 ms | 24,650 | 15.290% | 40.775% | Regular confirmation |
| [Optimized 15-04](../../../results/pyflate/optimized/2026-09-12-15-04/timing.json) | 1 | 430.226 ms | 289 | 14.533% | 41.176% | Diagnostic only |
| [Optimized 15-16](../../../results/pyflate/optimized/2026-09-12-15-16/timing.json) | 60 | 430.018 ms | 24,788 | 15.261% | 41.137% | Latest optimized baseline |

The checked-in `optimized/latest` points to `2026-09-12-15-16`. The older
`2026-09-12-13-09/comparison.txt` uses rounded/stale values and is not the source
of the calculations here.

The optimized lookup consumes a larger percentage after other code becomes
faster, but its absolute estimated times fall to approximately:

```text
optimized self time      = 65.627 ms
optimized inclusive time = 176.896 ms
```

That is consistent with an effective software optimization, not evidence that
the remaining lookup ceased to be important.

### Role of the other result files

Each result directory contains several views of the same run. They should not be
treated as independent timing experiments:

| Artifact | What it contributes | How it is used here |
|---|---|---|
| `timing.json` | pyperformance measured values and environment metadata | Primary wall-time statistics |
| `speedscope.folded` | Weighted sampled call stacks | Recomputed self/inclusive Python shares |
| `flamegraph.svg` | Visual rendering of the folded samples | Human inspection; not separately summed |
| `perf_report.txt` | Call graph, event/sample totals, lost-sample status | Confirms profile collection and zero lost samples |
| `perf_stat.txt` | CPU counters over the full pyperformance invocation | Supporting original/optimized work trends only |
| `run_metadata.txt` | interpreter, event, frequency, platform, and command provenance | Documents 199 Hz sampling and debug-vs-regular interpreter distinction |
| `perf_events.txt` | available/requested event information | Explains which counters were collectable |
| `perf_probe.log` and `perf_record.log` | collection diagnostics | Checked for warnings; kernel relocation/BPF warnings limit kernel attribution |
| `comparison.txt` | convenience output in one early optimized directory | Not used because its rounded baseline is stale relative to the checked-in JSON |
| `latest` | pointer to the latest optimized directory | Resolves to `2026-09-12-15-16` |

The `perf_record` warnings do not invalidate the filtered Python stack count,
but they are another reason not to make claims about kernel-level hotspots from
these files.

## 5.7 Optimized software improvement

Using the two comparable 60-value runs:

```text
S_software = T_original / T_optimized
           = 662.236860 ms / 430.018329 ms
           = 1.54002x

time reduction [%]
    = (1 - T_optimized/T_original) * 100
    = (1 - 430.018329/662.236860) * 100
    = 35.066%
```

The latest optimized distribution is:

| Statistic | Optimized 15-16 |
|---|---:|
| Count | 60 values |
| Arithmetic mean | 430.018329 ms |
| Median | 428.316756 ms |
| Minimum | 425.535526 ms |
| Maximum | 518.911097 ms |
| Sample standard deviation | 11.809953 ms |

## 5.8 Supporting hardware-counter trends

The regular full invocations' `perf_stat.txt` files show that optimized Python
does substantially less CPU work:

- [original perf stat](../../../results/pyflate/original/original%20results%20full%20run/perf_stat.txt)
- [optimized perf stat](../../../results/pyflate/optimized/2026-09-12-15-16/perf_stat.txt)

| Counter over whole pyperformance invocation | Original | Optimized | Change |
|---|---:|---:|---:|
| Cycles | 143.192 billion | 96.466 billion | -32.63% |
| Instructions | 382.299 billion | 248.717 billion | -34.94% |
| Branch instructions | 63.898 billion | 36.850 billion | -42.33% |
| Branch misses | 331.517 million | 189.527 million | -42.83% |
| Cache references | 451.591 million | 315.042 million | -30.24% |
| Cache misses | 38.158 million | 10.704 million | -71.95% |
| L1 data loads | 83.038 billion | 54.141 billion | -34.80% |
| L1 data load misses | 1.754 billion | 0.568 billion | -67.59% |
| IPC | 2.67 | 2.58 | slightly lower |
| Branch-miss rate | 0.52% | 0.51% | nearly unchanged |

The improvement comes mainly from executing fewer instructions/branches and
memory operations, not from a higher IPC. The low branch-miss and L1-miss rates
do not justify calling the original workload “DRAM bound.” The hardware case is
instead justified by removing repeated Python/object/control work and performing
bounded comparisons spatially.

These totals include process startup, warmups, and many benchmark values; they
are not counters for one 662 ms job. Many hardware counters were multiplexed
with approximately 20–31% event coverage, so they support trends rather than an
exact per-iteration microarchitectural model.

## 5.9 Analytical accelerator time

### Core cycles

For a 16-bit reservoir window and an initial offset of 0–7:

```text
C_fill = ceil((16 + start_bit) / 8) = 2 or 3 cycles
```

Using worst-case fill, `N=148,271`, and complete-top `II=2`:

```text
C_core = C_fill + N*II
       = 3 + 148,271*2
       = 296,545 cycles
```

At the unverified 200 MHz target:

```text
T_core = C_core / f_clk
       = 296,545 cycles / 200,000,000 cycles/s
       = 0.001482725 s
       = 1.482725 ms
```

This corresponds to nearly 100 million symbols/s in the long-run steady state.

### Source/configuration transfer checks

The complete compressed file is 67,562 bytes. That is an upper bound on the
accelerator source region because software consumes headers before the hardware
start position.

At one eight-bit input transfer per 200 MHz cycle:

```text
T_input,upper = 67,562 bytes / 200,000,000 bytes/s
              = 0.00033781 s
              = 337.81 us
```

This can overlap decode and is shorter than 1.483 ms.

The direct configuration stream performs:

```text
C_config = 6*147 table writes + 2,966 selector writes
         = 3,848 cycles

T_config,internal = 3,848 / 200,000,000
                  = 19.24 us
```

This excludes CPU/MMIO/DMA setup. Table/selector images total 6,494 bytes and
can be cached for repeated identical blocks.

## 5.10 Component speedup

### Conservative self-only scope

```text
S_component,self = software self time / hardware core time
                 = 80.2141 ms / 1.482725 ms
                 = 54.10x
```

This deliberately credits the accelerator only with the function's own
sampled work, even though the implemented reservoir also replaces child work.

### Optimistic inclusive scope

```text
S_component,inclusive = software inclusive time / hardware core time
                      = 256.3402 ms / 1.482725 ms
                      = 172.88x
```

This is optimistic because it assumes the batched API removes essentially the
entire sampled lookup/bit-reader subtree and that integration adds no overhead.

## 5.11 Whole-program speedup with Amdahl's law

For accelerated fraction `p` and component speedup `S_c`:

```text
S_total = 1 / ((1-p) + p/S_c)
```

### Conservative result

```text
p_self = 0.121126

S_total,self = 1 / ((1-0.121126) + 0.121126/54.10)
             = 1.13493x

S_max,self = 1 / (1-p_self)
           = 1.13782x
```

### Optimistic reservoir-inclusive result

```text
p_inclusive = 0.387082

S_total,inclusive
    = 1 / ((1-0.387082) + 0.387082/172.88)
    = 1.62560x

S_max,inclusive = 1 / (1-p_inclusive)
                = 1.63154x
```

The small gap between each projected result and its perfect-component bound is
a useful lesson: once a hot section becomes extremely fast, unaccelerated
software dominates.

## 5.12 Equivalent time-accounting formula

A direct formula makes integration overhead visible:

```text
T_new = T_base - T_removed + T_core + H_integration
```

where `H_integration` includes extra packing, driver submission, DMA setup,
cache maintenance, completion, and any returned-buffer overhead not already
present in the baseline.

For `H_integration=0`:

```text
conservative:
T_new = 662.2369 - 80.2141 + 1.4827
      = 583.5055 ms
S     = 662.2369 / 583.5055 = 1.1349x

optimistic inclusive:
T_new = 662.2369 - 256.3402 + 1.4827
      = 407.3794 ms
S     = 662.2369 / 407.3794 = 1.6256x
```

The latest optimized software takes 430.0183 ms. For the original-inclusive
hardware projection to beat it:

```text
H_integration < 430.0183 - 407.3794
              < 22.6389 ms/job
```

The conservative self-only projection cannot beat the current optimized suite,
which reinforces why the reservoir and a single batched job are essential.

As a secondary same-run sensitivity, applying the same 1.482725 ms core model
to the latest optimized profile gives approximately:

| Credited optimized scope | No-overhead projected total | Speedup over 430.018 ms |
|---|---:|---:|
| Self, 65.627 ms | 365.874 ms | 1.175x |
| Inclusive, 176.896 ms | 254.605 ms | 1.689x |

These are still projections and should not be mixed with a future measured
implementation result.

## 5.13 Frequency and initiation-interval sensitivity

For the fixed 296,545-cycle II=2 model:

| Achieved frequency | Period | Core time |
|---:|---:|---:|
| 100 MHz | 10.0 ns | 2.96545 ms |
| 156.25 MHz | 6.4 ns | 1.897888 ms |
| **200 MHz target** | **5.0 ns** | **1.482725 ms** |
| 250 MHz | 4.0 ns | 1.186180 ms |

The 156.25 MHz row corresponds to the illustrative 6.4 ns critical-path
example; it is not an achieved result.

At fixed 200 MHz:

| Architecture | II | Cycle model | Core time |
|---|---:|---:|---:|
| Speculative/bypassed ideal | 1 | `3 + 148271*1 = 148274` | 0.741370 ms |
| **Current complete top** | **2** | **`3 + 148271*2 = 296545`** | **1.482725 ms** |
| Extra non-speculative matcher stage | about 3 | `3 + 148271*3 = 444816` | 2.224080 ms |

This table prevents a common mistake: adding a pipeline register to the matcher
does not necessarily preserve whole-decoder throughput because each next window
depends on the previous returned length.

## 5.14 End-to-end streamed performance equation

For effective memory bandwidth `B_eff`:

```text
T_read  = input bytes / B_eff,read
T_write = output bytes / B_eff,write
```

With independent, overlapped source/output engines:

```text
T_job approximately = T_setup + T_config
                    + max(T_core, T_read, T_write)
                    + T_completion
```

With serialized transfers:

```text
T_job approximately = T_setup + T_config + T_read
                    + T_core + T_write + T_completion
```

Real behavior lies between these models and must be measured. `cycle_count`
gives accelerator-active cycles; host wall time gives the user-visible result.

For the core itself, a more complete cycle model is:

```text
C_observed = C_fill + N*II + C_bubbles
```

`C_bubbles` is the union of lost opportunities from input starvation,
backpressure, and wrapper behavior. The two exposed stall counters may overlap
other work or each other, so they must not automatically be summed to obtain
`C_bubbles`.

## 5.15 Assumptions and limitations of the estimate

The 1.135x–1.626x original-program range assumes:

- the observed input remains within 16-bit codes, six tables, 147 entries, and
  2,966 selectors;
- the workload emits exactly 148,271 raw Huffman symbols including EOB;
- the complete top meets the target 200 MHz after place-and-route;
- there are no byte-source or symbol-sink stalls in the core cycle model;
- the bit reservoir replaces the intended bit-reader operations correctly;
- returned raw symbols can be batch-processed without changing RUNA/RUNB, EOB,
  MTF, BWT, or final RLE semantics;
- table/selector transfer and integration overhead are either excluded or
  accounted separately; and
- software/hardware output matches the 399,360-byte golden result and MD5.

Profiling limitations:

- sampling percentages are estimates, not exact timers;
- the folded profile used a debug Python executable while `timing.json` used the
  regular benchmark interpreter, so multiplying fraction by mean combines
  adjacent but not identical executions;
- inclusive percentages overlap and cannot be summed across parents;
- wrapper/startup samples were filtered by the benchmark frame;
- kernel-symbol relocation warnings affect kernel attribution, not the selected
  Python-frame count; and
- no FPGA execution, synthesis Fmax, or device power measurement exists yet.

Accordingly, expected speedup should be reported as an **analytical projection
with a conservative and optimistic scope**, never as measured acceleration.

## 5.16 Decision

`HuffmanTable.find_next_symbol` plus its bit-reader boundary remains a good
project choice. It demonstrates both sides of hardware acceleration:

- software profiling, batching, representation conversion, absolute bit-state
  ownership, driver/MMIO/DMA decisions, and Amdahl analysis; and
- hardware table storage, parallel match logic, priority resolution, a streaming
  reservoir, ready/valid backpressure, variable-length feedback, control,
  counters, errors, and timing/PPA tradeoffs.

It is narrow enough to implement coherently in SystemVerilog, but rich enough to
show why an accelerator is more than translating one Python function into RTL.
