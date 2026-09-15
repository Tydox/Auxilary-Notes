# 6. Block-diagram alternatives

[Back to report index](README.md)

This chapter intentionally offers several Mermaid versions. A short final report
probably needs only Figure A plus either Figure C or D. The remaining figures
can be retained for teaching or removed to avoid repetition.

## Figure A — compact system integration

Best single executive-level diagram:

```mermaid
flowchart LR
    CPU["Pyflate + driver"] -->|"MMIO job control"| ACC["16-bit six-table<br/>Huffman accelerator"]
    MEM["System memory"] -->|"DMA compressed bytes"| ACC
    ACC -->|"DMA 16-bit symbol slots"| MEM
    ACC -->|"done, error, counters"| CPU
```

It shows the correct communication split without overwhelming the reader: MMIO
for control, DMA for bulk data.

## Figure B — non-compact system/software integration

Best detailed architecture figure for the hardware/software chapter:

```mermaid
flowchart TB
    subgraph SOFTWARE["Software"]
        PY["Python pyflate<br/>parse bzip2 metadata"]
        PACK["C extension/library<br/>validate and pack tables/selectors"]
        DRV["driver or bare-metal HAL<br/>map buffers, submit, wait"]
        POST["RUNA/RUNB + MTF + inverse BWT<br/>final RLE and MD5"]
        PY --> PACK --> DRV
    end

    subgraph CONTROL["Control plane"]
        AXIL["AXI4-Lite MMIO slave<br/>addresses, lengths, START, status"]
        IRQ["sticky done/error + interrupt"]
    end

    subgraph MEMORY["Memory/data plane"]
        RAM["System RAM<br/>source, table image, selectors, destination"]
        RD["read DMA + byte unpack FIFO"]
        CFG["configuration loader"]
        WR["symbol pack FIFO + write DMA"]
    end

    subgraph CORE["huffman_find_simple_top"]
        RES["32-bit MSB-first reservoir"]
        SEL["selector controller"]
        CAM["six x 147-entry match banks"]
        CTL["commit, EOB, errors, counters"]
        RES --> CAM --> CTL
        SEL --> CAM
        CTL -.->|matched length| RES
    end

    DRV --> AXIL
    AXIL --> CTL
    CTL --> IRQ --> DRV
    RAM --> RD -->|"8-bit ready/valid"| RES
    RAM --> CFG
    CFG -->|"table-entry writes"| CAM
    CFG -->|"selector writes"| SEL
    CTL -->|"9-bit ready/valid"| WR --> RAM
    DRV --> RAM
    RAM --> POST
```

The MMIO/DMA blocks are proposed integration logic; the `CORE` subgraph is the
implemented bus-independent RTL.

## Figure C — compact accelerator interior

Best concise hardware-only diagram:

```mermaid
flowchart LR
    IN["bytes"] --> R["reservoir"] --> W["16-bit window"] --> M["selected CAM"] --> Q["result register"] --> OUT["symbols"]
    S["selectors"] --> M
    Q -.->|length on accepted result| R
```

The dashed feedback explains why the complete top has a two-cycle initiation
interval even though the matcher output is registered.

## Figure D — non-compact accelerator interior with signal widths

Best detailed hardware-description figure:

```mermaid
flowchart LR
    subgraph I["Input stream"]
        IV["byte_valid: 1 bit"]
        IR["byte_ready: 1 bit"]
        ID["byte_data: 8 bits<br/>byte_last: 1 bit"]
    end

    subgraph R["Bit reservoir"]
        AL["first-byte align<br/>start_bit: 3 bits"]
        BQ["buffer_q: 32 bits<br/>valid_bits: 6 bits"]
        PK["peek_bits: 16 bits<br/>MSB first"]
        AL --> BQ --> PK
    end

    subgraph S["Selector controller"]
        SM["selector_mem<br/>2966 x 3"]
        GI["group count: 6 bits<br/>selector index: 12 bits"]
        AT["active_table_q: 3 bits"]
        GI --> SM --> AT
    end

    subgraph H["Six table banks"]
        BD["bank decode +<br/>operand isolation"]
        C0["CAM 0 + bank result register<br/>147 x 47-bit entries"]
        C1["CAM 1 + bank result register"]
        CX["CAM 2..4 + result registers"]
        C5["CAM 5 + bank result register"]
        MX["selected-result mux"]
        BD --> C0 --> MX
        BD --> C1 --> MX
        BD --> CX --> MX
        BD --> C5 --> MX
    end

    subgraph O["Commit/output"]
        CK["capacity + real-bit + EOB checks"]
        OS["symbol_valid/ready: 1 bit each<br/>symbol 9, length 5, table 3, EOB 1 bit"]
        CN["bit/symbol/cycle/stall counters"]
        CK --> OS
        CK --> CN
    end

    ID --> AL
    IV --> AL
    AL --> IR
    PK --> BD
    AT --> BD
    MX --> CK
    OS -.->|output_fire| GI
    OS -.->|consume_len 5 bits| BQ
```

## Figure E — datapath versus control-path split

Useful when explaining those terms to a beginner:

```mermaid
flowchart TB
    subgraph DATA["Datapath: values being transformed"]
        D0["compressed byte"] --> D1["32-bit buffered bits"] --> D2["16-bit lookup window"]
        D2 --> D3["masked comparisons"] --> D4["chosen 9-bit symbol + 5-bit length"] --> D5["output symbol"]
    end

    subgraph CTRL["Control path: when and where data moves"]
        C0["ready/valid handshakes"] --> C1["active table selection"] --> C2["commit event"]
        C2 --> C3["EOB/capacity/error decision"]
        C2 --> C4["group and performance counters"]
    end

    C0 -.->|controls| D0
    C1 -.->|selects| D3
    C2 -.->|enables consume| D1
    D4 -.->|status inputs| C3
```

The datapath carries bytes, bits, codes, and symbols. The control path decides
when a value is valid, which bank acts, and whether state may advance.

## Figure F — one CAM entry and parallel reduction

Useful for explaining the central hardware operation:

```mermaid
flowchart LR
    L["lookup_bits[15:0]"] --> AND0["AND mask[0]"] --> EQ0["== pattern[0]"] --> R0["match[0]"]
    L --> AND1["AND mask[1]"] --> EQ1["== pattern[1]"] --> R1["match[1]"]
    L --> ANDN["AND mask[146]"] --> EQN["== pattern[146]"] --> RN["match[146]"]
    V0["valid[0]"] --> R0
    V1["valid[1]"] --> R1
    VN["valid[146]"] --> RN
    R0 --> P["shortest length,<br/>then lowest index"]
    R1 --> P
    RN --> P
    P --> REG["found/symbol/length register"]
```

All entry branches represent parallel hardware. The priority reduction is
combinational and is likely the largest timing risk.

## Figure G — reservoir bit alignment example

Useful for clarifying MSB-first alignment:

```mermaid
flowchart LR
    B0["first byte<br/>10110110"] --> SKIP["start_bit=3<br/>discard 101"] --> KEEP["retain 10110"]
    KEEP --> R0["reservoir MSB side<br/>10110"]
    B1["next byte<br/>01100101"] --> APP["append below<br/>current valid bits"]
    R0 --> APP --> R1["reservoir<br/>10110 01100101 ..."]
    R1 --> PEEK["peek next 16 bits<br/>zero-pad only after byte_last"]
```

## Figure H — selector schedule

Useful for proving the table changes at the right boundary:

```mermaid
flowchart LR
    G0["accepted symbols 1..50<br/>selector[0]"] --> E0["accept symbol 50"]
    E0 --> L1["register selector[1]"] --> G1["accepted symbols 51..100<br/>selector[1]"]
    G1 --> E1["accept symbol 100"] --> L2["register selector[2]"] --> G2["symbols 101..150"]
    G0 -.->|EOB may terminate early| DONE["done"]
    G1 -.->|EOB may terminate early| DONE
    G2 -.->|EOB may terminate early| DONE
```

The transition is driven by accepted outputs, so output backpressure cannot
silently move the selector early.

## Figure I — ready/valid commit behavior

Useful for explaining protocol safety:

```mermaid
sequenceDiagram
    participant M as Matcher register
    participant T as Top control
    participant R as Reservoir
    participant O as Output consumer

    M->>O: valid=1, symbol=S, length=L
    O-->>T: ready=0
    Note over M,R: Hold result, bits, table, and counters
    M->>O: valid=1, same S and L
    O-->>T: ready=1
    Note over M,O: Transfer at rising edge
    T->>R: consume L bits
    T->>T: increment symbol/bits/group counters
```

## Figure J — control-state view

Useful in a hardware-architecture section when a state diagram is expected:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Configure: configuration writes
    Configure --> Configure: more table/selector writes
    Configure --> Fill: valid start
    Idle --> Fill: valid start with retained configuration
    Fill --> Lookup: lookup window valid
    Lookup --> Result: registered match
    Result --> Result: output backpressure
    Result --> Fill: accepted symbol, refill required
    Result --> Lookup: accepted symbol, window remains
    Result --> Success: accepted EOB
    Fill --> Failure: truncated input
    Lookup --> Failure: no match or invalid length
    Result --> Failure: capacity or selector error
    Success --> Idle: done pulse
    Failure --> Idle: done pulse and error status
```

`Configure` is an externally interpreted phase while `busy=0`; the RTL uses
state flags rather than this exact enumerated FSM.

## Figure K — likely timing paths

Useful for the timing/tradeoff chapter:

```mermaid
flowchart TB
    subgraph P1["Normal match path: likely critical"]
        RQ["reservoir and active-table registers"] --> BM["bank decode/mux"] --> CMP["147 masked 16-bit comparisons"] --> PRI["16 x 147 priority predicates"] --> RR["result register"]
    end
    subgraph P2["Reservoir update path"]
        MR["match result register"] --> SUB["length/count subtract"] --> SHIFT["32-bit variable shift"] --> APP["optional count-dependent byte append"] --> BQR["reservoir register"]
    end
    subgraph P3["Boundary-only selector path"]
        SI["selector index register"] --> ADD["increment"] --> MEM["selector memory read"] --> RC["range check"] --> AT["active-table register"]
    end
```

The 5 ns constraint applies to every synchronous path, even if a path is used
only once per 50 symbols.

## Figure L — architecture tradeoff map

Useful as a concluding comparison:

```mermaid
flowchart LR
    SEQ["Sequential RAM search<br/>small area, many cycles"] --> ONE["One parallel CAM<br/>reload/table-switch cost"] --> SIX["Current six CAM banks<br/>fast switch, high area"]
    SIX --> TREE["Six CAMs + balanced reduction<br/>better timing, more design work"]
    TREE --> CAN["Canonical range decoder<br/>lower area/power, different design"]
```

This is a qualitative continuum, not measured placement data.

## Recommended final-report selection

If the report must be compact, retain:

1. **Figure A** for overall hardware/software integration;
2. **Figure D** for the detailed internal block diagram; and
3. **Figure I or K** depending on whether the discussion emphasizes protocol
   correctness or timing closure.

If the audience is new to RTL, also retain Figures E, G, and H because they make
datapath/control, bit alignment, and selector scheduling concrete.
