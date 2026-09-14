# 7. Performance, area, frequency, and power tradeoffs

[Back to report index](README.md)

## 7.1 What PPA means here

Hardware architecture is not judged by performance alone:

- **Performance** includes latency, throughput, stalls, and end-to-end software
  speedup.
- **Area** includes stored state, lookup/comparison logic, priority/mux logic,
  routing, clock/reset resources, and the external bus/DMA wrapper.
- **Power** includes static/leakage and dynamic power from clocks, logic, signals,
  memories, and I/O.

These objectives conflict. More parallel hardware can reduce cycles but consumes
more area and switched capacitance. More pipeline stages can raise achievable
frequency but increase latency and, for this feedback-dependent decoder,
initiation interval. A lower clock reduces instantaneous dynamic power but
extends active time.

## 7.2 Current design point

The selected educational design is:

```text
six physical CAM-style table banks
* 147 entries/table
* 16-bit lookup
* 32-bit byte reservoir
* registered active selector
* registered matcher output
* one outstanding lookup
* II = 2 cycles/symbol
* target = 200 MHz, not yet achieved
```

Why this point was chosen:

- it maps visibly and directly to the friend's simple table matcher;
- all bzip2 tables are resident, so switching every 50 symbols is immediate;
- it clearly demonstrates spatial comparison, datapath/control, streaming, and
  backpressure;
- it is much easier to explain than a highly optimized canonical decoder; and
- its inefficiencies create a meaningful, honest PPA discussion.

It is not presented as the minimum-area or minimum-energy production solution.

## 7.3 Area model

### General storage formula

Let:

```text
T = number of tables
E = entries per table
K = lookup/code width [bits]
S = decoded symbol width [bits]
L = stored length-field width [bits]
```

The direct pattern/mask entry size is:

```text
B_entry [bits] = K_pattern + K_mask + S_symbol + L_length + 1_valid
               = 2K + S + L + 1
```

CAM storage is:

```text
B_CAM [bits] = T * E * (2K + S + L + 1)
```

For `T=6`, `E=147`, `K=16`, `S=9`, `L=5`:

```text
B_entry = 2*16 + 9 + 5 + 1 = 47 bits
B_CAM   = 6*147*47 = 41,454 bits
```

Additional raw state is approximately:

```text
selector RAM                 = 2,966*3 = 8,898 bits
six matcher result registers = 6*(1+1+9+5) = 96 bits
reservoir state              = 32+6+3+1+1 = 43 bits
top job/control/counters      approximately 291 bits

B_state,total approximately = 50,782 bits
                              = 6,347.75 byte-equivalents
                              approximately 6.20 KiB bit-packed
```

This number is a transparent RTL state inventory, not a synthesis area result.

### Comparison fabric

The number of physical masked equality opportunities is:

```text
N_comparators = T*E = 6*147 = 882

N_bit_compare_lanes = T*E*K
                    = 6*147*16
                    = 14,112 bit lanes
```

Only one bank is operand-active per lookup, but all six occupy area.

The source's shortest-first loops test up to:

```text
N_priority_predicates,bank = K_lengths * E_entries
                           = 16*147
                           = 2,352

N_priority_predicates,total = 6*2,352 = 14,112
```

Synthesis may factor or remove impossible conditions, but the nested source can
map to a deep and wide priority/multiplexer network. It is likely a larger PPA
risk than the stored-bit total suggests.

### FPGA mapping consequence

Every entry must be observed in parallel for the CAM compare. Ordinary
single/dual-port block RAM cannot expose 147 records at once, so pattern/mask and
metadata may map largely to flip-flops, LUTRAM, and LUT logic. The selector array
is small enough for distributed RAM, but its current asynchronous read may also
affect inference. A synchronous selector prefetch would map more naturally to a
memory primitive.

Actual area must be reported in device resources after synthesis and placement:

```text
LUTs, flip-flops, distributed RAM, block RAM, DSPs, clock buffers,
and percentage of chosen device
```

An ASIC flow would instead report cell area, gate equivalents, memory-macro area,
and routed die/core utilization.

## 7.4 Performance model

### Throughput

```text
throughput [symbols/s] = f_clk [cycles/s] / II [cycles/symbol]
```

For the current `II=2` and target 200 MHz:

```text
throughput = 200 MHz / 2 = 100 Msymbol/s
```

### Job latency

```text
C_core = C_fill + N*II + C_bubbles
T_core = C_core / f_achieved
```

With worst fill `3`, `N=148,271`, no bubbles, and target 200 MHz:

```text
C_core = 3 + 148,271*2 = 296,545 cycles
T_core = 296,545/200,000,000 = 1.482725 ms
```

One-symbol latency and whole-stream throughput are different quantities. The
matcher registers a result after its combinational search, but the complete top
cannot start a dependent next lookup until the current length commits.

### Integration

End-to-end time is approximately:

```text
T_job = T_setup + T_configuration
      + max(T_core, T_source_DMA, T_destination_DMA)
      + T_completion
```

when transfers overlap. If the platform serializes them, replace `max` with an
appropriate sum. This is why a 1.483 ms core result must not be presented as the
whole Python benchmark time.

## 7.5 How timing is actually calculated

### RTL has no physical delay yet

SystemVerilog operators define Boolean/arithmetic behavior. Their physical
delay appears only after a tool maps them to a chosen device and routes them.
`timescale 1ns/1ps` controls simulation delay units; it does not set hardware
frequency.

The XDC constraint:

```tcl
create_clock -name core_clk -period 5.000 [get_ports {clk}]
```

asks tools to attempt 200 MHz.

### Setup equation

For one launch-register to capture-register path:

```text
T_cq,max + T_comb,max + T_route,max + T_setup + T_uncertainty <= T_period
```

Static timing analysis reports:

```text
setup slack = required arrival time - actual arrival time
```

- worst negative slack (`WNS < 0`) means at least one path fails;
- total negative slack (`TNS < 0`) summarizes all failing endpoint slack; and
- `WNS >= 0` and `TNS=0` are necessary setup-timing conditions for that
  constraint/corner.

If a 5.0 ns run reports `WNS=-1.4 ns` and the simplified required/arrival
relationship is otherwise unchanged:

```text
critical required duration approximately = 5.0 - (-1.4) = 6.4 ns
Fmax approximately = 1/6.4 ns = 156.25 MHz
```

This reciprocal is an estimate. To establish Fmax, tighten/relax constraints and
rerun implementation because placement and tool optimization can change with
the target.

### Hold equation

A simplified hold condition is:

```text
T_cq,min + T_comb,min + T_route,min >= T_hold + T_skew
```

Hold analysis uses a minimum-delay corner. Slowing the clock does not directly
fix a too-fast same-edge data path.

### Other checks

A credible timing report also checks:

- clock uncertainty and jitter;
- input/output delay constraints at the core/platform boundary;
- recovery/removal of asynchronous reset deassertion;
- clock-domain crossings if DMA/control clocks differ;
- unconstrained paths and endpoints; and
- minimum pulse-width/device checks.

The boundary selector path cannot simply be declared a 50-cycle multicycle path:
although it occurs only every 50 symbols, the newly selected table is needed by
the following lookup. A timing exception would require a proven prefetch
schedule, not merely low activation frequency.

## 7.6 Likely critical paths and remedies

| Candidate path | Why risky | First remedy | Tradeoff |
|---|---|---|---|
| Reservoir/active-table register -> bank decode -> 147 masked comparisons -> nested 16x147 priority -> result register | Very wide compare and potentially deep mux/priority logic | Balanced tournament/reduction tree that preserves priority | More structured RTL/routing; same nominal II possible |
| Matcher result -> count subtract -> 32-bit variable shift -> count-dependent byte append/OR -> reservoir register | Barrel shifts and simultaneous consume/refill selection | Split/refactor append path, precompute shift choices, or pipeline | Pipeline may increase feedback II |
| Selector index -> increment -> async selector read -> range check -> active-table register | Memory/mux plus compare in one boundary cycle | Prefetch next selector or synchronous RAM stage | Small extra state/control |
| Config code/length -> variable alignment shifts -> table state | Variable shifts at write time | Pre-align in loader/software or register config path | Changes programming format or adds config latency only |

Registering `active_table_q` already removed selector memory from every normal
lookup. This improves timing with negligible state cost and no extra steady-state
bubble.

## 7.7 Pipelining tradeoff specific to this design

In a feed-forward pipeline with independent inputs, adding a stage may increase
latency without reducing throughput. That assumption does not automatically hold
here:

```text
current match length -> reservoir consume -> next lookup window
```

If a register is inserted between raw matches and priority resolution and no
speculation/bypass is added:

```text
II_current = 2 cycles/symbol
II_pipelined approximately = 3 cycles/symbol
```

At 200 MHz:

```text
T_II2 = (3 + 148,271*2)/200 MHz = 1.482725 ms
T_II3 = (3 + 148,271*3)/200 MHz = 2.224080 ms
```

The pipeline is still worthwhile if it raises frequency enough. Break-even
between the two designs is:

```text
N*II_old / f_old approximately = N*II_new / f_new

f_new/f_old approximately = II_new/II_old = 3/2 = 1.5
```

So changing II from 2 to 3 needs roughly a 50% clock-frequency increase merely
to recover the same long-stream throughput. A balanced single-stage priority
network is therefore the preferred first timing fix.

## 7.8 Power and energy model

Total device power can be separated as:

```text
P_total = P_static + P_clock + P_logic + P_signal
        + P_memory + P_IO + P_DMA
```

First-order dynamic logic/signal power is:

```text
P_dynamic approximately = sum(alpha * C_eff * V^2 * f)
```

Current design effects:

- six banks increase `C_eff` through more logic and routing;
- only one bank receives changing lookup data/valid, reducing `alpha` in five
  banks;
- this is operand isolation, **not clock gating**;
- bank result registers and clock networks still toggle/consume clock power;
- the selector and table arrays contribute leakage/static power even inactive;
- wide/frequent DMA I/O may consume as much or more platform power than the
  small core; and
- shorter execution can reduce leakage energy even if instantaneous dynamic
  power is higher.

Energy:

```text
E_job = integral(P(t) dt) approximately P_average*T_job
```

Illustrative only:

```text
if P_average = 0.40 W and T_job = 1.482725 ms,
E_job = 0.40*0.001482725 = 0.00059309 J = 0.593 mJ
```

No target part, voltage, placed route, or activity trace has been selected, so
the project has no defensible absolute expected watt value yet. Report `0.40 W`
only as an assumed example, never as measured/estimated device power.

## 7.9 Architecture comparison

| Architecture | Cycles/symbol | Comparator/storage area | Table-switch behavior | Timing risk | Dynamic power tendency | Suitability |
|---|---:|---|---|---|---|---|
| Six parallel direct CAM banks (current) | 2 in complete top | Highest | Immediate registered switch | Flat priority is risky | Highest capacitance; operand isolation helps activity | Best clarity/demo completeness |
| Six CAM banks with balanced reduction | 2 possible | Similar state; reorganized logic | Immediate | Better logic depth | Similar or somewhat lower glitch power | Recommended timing refinement |
| One direct CAM bank reloaded | 2 after loaded, plus reloads | About 1/6 compare/storage fabric | Reload at group changes or cache tables elsewhere | Lower CAM mux load | Lower core power, high transfer/control activity | Poor when selector changes every 50 symbols |
| Multi-cycle sequential RAM search | Many | Lowest logic; BRAM-friendly | Easy | Easy frequency | Low instantaneous power, longer active time | Loses acceleration benefit |
| Canonical range decoder | Potentially 1–2 | Much lower than 882 CAM compares | Store compact ranges for tables | Generally better | Generally lower | Strong production choice; different from simple design |
| Full bzip2 accelerator | Could remove much more software | Much larger system/state | Internal | Much greater verification risk | Larger | Outside selected component scope |

## 7.10 Specific design knobs

### Number of physical banks

Scaling table count `T` changes CAM storage and comparisons linearly:

```text
B_CAM proportional to T
N_comparators proportional to T
```

Reducing six to one saves about 5/6 of CAM fabric, but selector transitions then
need table reload or a separate table-memory/cache architecture. With a change
every 50 symbols, repeated reload latency can dominate.

### Key width

Increasing `KEY_WIDTH` from 16 to 20 would increase pattern+mask storage by:

```text
Delta B_CAM = 6*147*2*(20-16)
            = 7,056 bits
```

It also widens all 882 comparisons by four bits and expands priority length
classes from 16 to 20. Sixteen bits is justified only because workload
characterization proves it sufficient; a general bzip2 accelerator needs 20.

### Reservoir width

A 32-bit reservoir provides room for a 16-bit window plus byte refill. A smaller
24-bit buffer saves eight data bits and some shifter width but reduces scheduling
margin. A wider 64-bit buffer can align naturally with wider DMA data but creates
a larger variable shifter and potentially higher power. A separate narrow
reservoir behind a byte/word FIFO is usually cleaner.

### Stream width

The eight-bit core input is simple and already needs only about 45.57 MB/s
average for the full-file upper bound over the analytical core interval. Widening
the core to 32/64/128 bits would not improve the II=2 match limit, but it would
increase append logic. A wide DMA-to-byte FIFO is a better integration split.

The output is more demanding: at 100 Msymbol/s with 16-bit memory slots, it can
approach 200 MB/s. A FIFO and packed wide writes prevent memory response jitter
from stalling the core.

### Counters and error logic

The 64-bit cycle counter and three 32-bit counters consume modest state and
adder activity. Removing them saves little relative to CAM logic and would make
performance/debug claims harder to validate. They are a favorable educational
and observability tradeoff.

### Configuration caching

Caching a 6,494-byte table/selector image avoids repeated load/setup energy and
latency across identical jobs, but requires a configuration identity/version and
careful stale-state rules. The simple safe baseline fully rewrites all 6x147
entries (zero lengths invalidate absent codes) and the used selector prefix.

## 7.11 Timing/area/power optimization order

If implementation work continues, use evidence from reports rather than
optimizing blindly:

1. Synthesize and place the unchanged current design for a named device at the
   5.000 ns constraint.
2. Confirm all paths are constrained and inspect WNS/TNS and the actual top
   critical path.
3. If selector-boundary timing fails, prefetch the next selector.
4. If priority timing fails, replace the nested selection with a balanced,
   equivalence-tested reduction while keeping the external interface.
5. Re-run functional simulation and compare cycle/MD5 behavior.
6. Re-run place-and-route; record LUT/FF/RAM and achieved timing.
7. Generate VCD/SAIF from representative benchmark traffic and run power
   analysis.
8. Only if the balanced implementation still fails, evaluate a pipeline stage
   and include its new II in the performance model.
9. If area/power remains excessive, compare the canonical-range architecture
   using the same vectors and measurement boundary.

## 7.12 Data required for a real PPA table

Once a target and tools are available, replace analytical placeholders with:

| Item | Required evidence |
|---|---|
| Target | Exact FPGA part/speed grade or ASIC library/corner |
| Constraint | Clock period, uncertainty, I/O delays, CDC/reset exceptions |
| Timing | Post-route WNS/TNS, achieved tested frequency, critical path start/end and logic levels |
| Area | LUT, FF, LUTRAM, BRAM, DSP, routing/utilization; or cell area/gate equivalents |
| Power | Static and dynamic breakdown, voltage, temperature, activity source, toggle coverage |
| Performance | Measured cycles, stalls, symbols, bits, host wall time, DMA time |
| Energy | Measured/estimated average watts times measured job time |
| Correctness | Test vector count, assertions, final bytes/MD5, error-case coverage |

## 7.13 Final tradeoff judgment

For this project, the current six-bank 16-bit CAM is defensible because the goal
is to demonstrate a complete hardware/software acceleration concept rather than
deliver the smallest production bzip2 decoder. It offers a clear direct mapping,
immediate selector changes, useful counters, and an analytically strong core
speedup.

The price is high replicated comparison/priority area and uncertain 200 MHz
timing. The report should therefore present 200 MHz and 0.40 W correctly:

- **200 MHz is a constrained target pending post-route timing**, and
- **0.40 W is an illustrative energy-calculation assumption pending a named
  device and activity-based power analysis**.

If only one refinement is made before synthesis, restructure the shortest-match
selection as a balanced reduction. It attacks the most likely critical path
without automatically increasing the feedback initiation interval.
