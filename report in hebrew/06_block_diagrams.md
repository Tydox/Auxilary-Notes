# 6. חלופות ל-Block diagrams

[חזרה לאינדקס הדוח](README.md)

פרק זה מציע במכוון כמה גרסאות Mermaid. דוח סופי קצר יזדקק כנראה רק לתרשים A
ולתוספת של תרשים C או D. ניתן להשאיר את יתר התרשימים לצורכי לימוד, או להסירם
כדי להימנע מחזרה.

## תרשים A — שילוב מערכת קומפקטי

התרשים היחיד הטוב ביותר ברמת executive overview:

```mermaid
flowchart LR
    CPU["Pyflate + driver"] -->|"MMIO job control"| ACC["Huffman accelerator עם שישה tables<br/>וברוחב 16-bit"]
    MEM["System memory"] -->|"DMA של compressed bytes"| ACC
    ACC -->|"DMA של symbol slots ברוחב 16-bit"| MEM
    ACC -->|"done, error, counters"| CPU
```

הוא מציג את חלוקת התקשורת הנכונה בלי להעמיס על הקורא: MMIO עבור control ו-DMA
עבור bulk data.

## תרשים B — שילוב מערכת/Software לא קומפקטי

תרשים ה-architecture המפורט הטוב ביותר עבור פרק ה-Hardware/Software:

```mermaid
flowchart TB
    subgraph SOFTWARE["Software"]
        PY["Python pyflate<br/>ניתוח metadata של bzip2"]
        PACK["C extension/library<br/>אימות ואריזת tables/selectors"]
        DRV["driver או bare-metal HAL<br/>מיפוי buffers, שליחה והמתנה"]
        POST["RUNA/RUNB + MTF + inverse BWT<br/>RLE סופי ו-MD5"]
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
        CAM["שישה match banks עם 147 entries"]
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
    CFG -->|"writes של table entries"| CAM
    CFG -->|"writes של selectors"| SEL
    CTL -->|"9-bit ready/valid"| WR --> RAM
    DRV --> RAM
    RAM --> POST
```

בלוקי ה-MMIO/DMA הם integration logic מוצע; ה-subgraph בשם `CORE` הוא ה-RTL
הבלתי תלוי ב-bus שכבר מומש.

## תרשים C — פנים ה-Accelerator באופן קומפקטי

תרשים Hardware-only התמציתי הטוב ביותר:

```mermaid
flowchart LR
    IN["bytes"] --> R["reservoir"] --> W["חלון 16-bit"] --> M["CAM נבחר"] --> Q["result register"] --> OUT["symbols"]
    S["selectors"] --> M
    Q -.->|length בתוצאה שהתקבלה| R
```

ה-feedback המקווקו מסביר מדוע ל-top המלא יש initiation interval של שני cycles,
אף שה-output של ה-matcher רשום.

## תרשים D — פנים ה-Accelerator באופן לא קומפקטי, כולל רוחבי signals

תרשים ה-Hardware description המפורט הטוב ביותר:

```mermaid
flowchart LR
    subgraph I["Input stream"]
        IV["byte_valid: 1 bit"]
        IR["byte_ready: 1 bit"]
        ID["byte_data: 8 bits<br/>byte_last: 1 bit"]
    end

    subgraph R["Bit reservoir"]
        AL["יישור ה-byte הראשון<br/>start_bit: 3 bits"]
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

    subgraph H["שישה table banks"]
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
        CK["בדיקות capacity + real-bit + EOB"]
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

## תרשים E — הפרדה בין Datapath ל-control path

שימושי כאשר מסבירים מונחים אלה למתחילים:

```mermaid
flowchart TB
    subgraph DATA["Datapath: הערכים שעוברים עיבוד"]
        D0["compressed byte"] --> D1["buffered bits ברוחב 32-bit"] --> D2["חלון lookup ברוחב 16-bit"]
        D2 --> D3["masked comparisons"] --> D4["symbol נבחר ברוחב 9-bit + length ברוחב 5-bit"] --> D5["output symbol"]
    end

    subgraph CTRL["Control path: מתי ולאן המידע נע"]
        C0["ready/valid handshakes"] --> C1["בחירת active table"] --> C2["commit event"]
        C2 --> C3["החלטת EOB/capacity/error"]
        C2 --> C4["group counters ו-performance counters"]
    end

    C0 -.->|שולט ב-| D0
    C1 -.->|בוחר| D3
    C2 -.->|מאפשר consume| D1
    D4 -.->|status inputs| C3
```

ה-datapath נושא bytes, bits, codes ו-symbols. ה-control path מחליט מתי ערך הוא
valid, איזה bank פועל והאם מותר למצב להתקדם.

## תרשים F — CAM entry אחד ו-parallel reduction

שימושי להסברת פעולת ה-Hardware המרכזית:

```mermaid
flowchart LR
    L["lookup_bits[15:0]"] --> AND0["AND mask[0]"] --> EQ0["== pattern[0]"] --> R0["match[0]"]
    L --> AND1["AND mask[1]"] --> EQ1["== pattern[1]"] --> R1["match[1]"]
    L --> ANDN["AND mask[146]"] --> EQN["== pattern[146]"] --> RN["match[146]"]
    V0["valid[0]"] --> R0
    V1["valid[1]"] --> R1
    VN["valid[146]"] --> RN
    R0 --> P["האורך הקצר ביותר,<br/>ואחריו ה-index הנמוך ביותר"]
    R1 --> P
    RN --> P
    P --> REG["found/symbol/length register"]
```

כל ענפי ה-entry מייצגים Hardware מקבילי. ה-priority reduction הוא combinational
וכנראה מהווה את סיכון ה-timing הגדול ביותר.

## תרשים G — דוגמה ל-bit alignment ב-reservoir

שימושי להבהרת יישור MSB-first:

```mermaid
flowchart LR
    B0["ה-byte הראשון<br/>10110110"] --> SKIP["start_bit=3<br/>השלכת 101"] --> KEEP["שמירת 10110"]
    KEEP --> R0["צד ה-MSB של ה-reservoir<br/>10110"]
    B1["ה-byte הבא<br/>01100101"] --> APP["צירוף מתחת ל-bits<br/>התקפים הנוכחיים"]
    R0 --> APP --> R1["reservoir<br/>10110 01100101 ..."]
    R1 --> PEEK["הצגת 16 ה-bits הבאים<br/>zero-padding רק לאחר byte_last"]
```

## תרשים H — תזמון ה-Selector

שימושי להוכחה שה-table משתנה בגבול הנכון:

```mermaid
flowchart LR
    G0["symbols שהתקבלו 1..50<br/>selector[0]"] --> E0["קבלת symbol 50"]
    E0 --> L1["רישום selector[1]"] --> G1["symbols שהתקבלו 51..100<br/>selector[1]"]
    G1 --> E1["קבלת symbol 100"] --> L2["רישום selector[2]"] --> G2["symbols 101..150"]
    G0 -.->|EOB עשוי לסיים מוקדם| DONE["done"]
    G1 -.->|EOB עשוי לסיים מוקדם| DONE
    G2 -.->|EOB עשוי לסיים מוקדם| DONE
```

ה-transition מונע על ידי outputs שהתקבלו, ולכן output backpressure אינו יכול
להקדים בשקט את תנועת ה-selector.

## תרשים I — התנהגות commit ב-ready/valid

שימושי להסברת בטיחות ה-protocol:

```mermaid
sequenceDiagram
    participant M as Matcher register
    participant T as Top control
    participant R as Reservoir
    participant O as Output consumer

    M->>O: valid=1, symbol=S, length=L
    O-->>T: ready=0
    Note over M,R: החזקת התוצאה, ה-bits, ה-table וה-counters
    M->>O: valid=1, same S and L
    O-->>T: ready=1
    Note over M,O: Transfer ב-rising edge
    T->>R: consume של L bits
    T->>T: הגדלת counters של symbol/bits/group
```

## תרשים J — מבט על מצבי ה-Control

שימושי בפרק Hardware architecture כאשר מצופה state diagram:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Configure: configuration writes
    Configure --> Configure: writes נוספים של table/selector
    Configure --> Fill: start תקין
    Idle --> Fill: start תקין עם configuration שנשמר
    Fill --> Lookup: חלון lookup תקף
    Lookup --> Result: match רשום
    Result --> Result: output backpressure
    Result --> Fill: symbol התקבל, נדרש refill
    Result --> Lookup: symbol התקבל, נותר חלון
    Result --> Success: EOB התקבל
    Fill --> Failure: input קטוע
    Lookup --> Failure: אין match או length לא תקין
    Result --> Failure: שגיאת capacity או selector
    Success --> Idle: pulse של done
    Failure --> Idle: pulse של done ו-error status
```

`Configure` הוא שלב שמפורש חיצונית כאשר `busy=0`; ה-RTL משתמש ב-state flags
ולא ב-FSM enumerated מדויק זה.

## תרשים K — מסלולי Timing סבירים

שימושי עבור פרק ה-timing/tradeoff:

```mermaid
flowchart TB
    subgraph P1["מסלול match רגיל: כנראה critical"]
        RQ["registers של reservoir ו-active-table"] --> BM["bank decode/mux"] --> CMP["147 השוואות masked ברוחב 16-bit"] --> PRI["16 x 147 priority predicates"] --> RR["result register"]
    end
    subgraph P2["מסלול עדכון ה-Reservoir"]
        MR["match result register"] --> SUB["חיסור length/count"] --> SHIFT["variable shift ברוחב 32-bit"] --> APP["צירוף byte אופציונלי שתלוי ב-count"] --> BQR["reservoir register"]
    end
    subgraph P3["מסלול Selector רק בגבול"]
        SI["selector index register"] --> ADD["increment"] --> MEM["קריאת selector memory"] --> RC["בדיקת טווח"] --> AT["active-table register"]
    end
```

ה-constraint של 5 ns חל על כל synchronous path, גם אם משתמשים ב-path רק פעם
ב-50 symbols.

## תרשים L — מפת Tradeoffs של ה-Architecture

שימושי כהשוואה מסכמת:

```mermaid
flowchart LR
    SEQ["חיפוש Sequential RAM<br/>area קטן, cycles רבים"] --> ONE["CAM מקבילי יחיד<br/>עלות reload/table-switch"] --> SIX["ששת ה-CAM banks הנוכחיים<br/>מעבר מהיר, area גבוה"]
    SIX --> TREE["שישה CAMs + balanced reduction<br/>timing טוב יותר, יותר עבודת תכנון"]
    TREE --> CAN["Canonical range decoder<br/>area/power נמוכים יותר, תכנון שונה"]
```

זהו רצף qualitative, ולא נתוני placement שנמדדו.

## בחירה מומלצת לדוח הסופי

אם הדוח חייב להיות קומפקטי, כדאי להשאיר:

1. את **תרשים A** עבור שילוב ה-Hardware/Software הכולל;
2. את **תרשים D** עבור ה-block diagram הפנימי המפורט; וכן
3. את **תרשים I או K**, בהתאם לשאלה אם הדיון מדגיש protocol correctness או
   timing closure.

אם הקהל חדש בתחום ה-RTL, כדאי להשאיר גם את תרשימים E, G ו-H, משום שהם הופכים
את ה-datapath/control, את ה-bit alignment ואת תזמון ה-selector למוחשיים.
