# 2. Inputs, outputs, wires, memory, frequency ו-power

[חזרה לאינדקס הדוח](README.md)

## 2.1 מוסכמות Interface

פרק זה מתאר את ה-ports של ה-top-level module הפעיל
`huffman_find_simple_top`, עם ה-default parameters של ה-benchmark:

```systemverilog
NUM_TABLES    = 6
NUM_ENTRIES   = 147
KEY_WIDTH     = 16
SYMBOL_WIDTH  = 9
MAX_SELECTORS = 2966
```

כל ה-functional transfers הם synchronous ל-rising edge של `clk`.
`rst_n` עובר assertion באופן asynchronous לערך נמוך; על המערכת המקיפה לסנכרן
את ה-deassertion שלו ל-`clk`. ב-accelerator core קיים clock domain יחיד.

Streaming interfaces משתמשים ב-ready/valid:

```text
transfer occurs on a rising edge iff valid = 1 AND ready = 1
```

ה-producer חייב להחזיק את `valid` ואת כל ה-payload signals המשויכים אליו יציבים
עד שה-transfer מתרחש. ה-receiver יכול להפעיל backpressure באמצעות הורדת `ready`.

## 2.2 רוחבים נגזרים

עבור שדה unsigned שמייצג ערכים מ-`0` עד `N-1`, הרוחב המזערי הוא:

```text
W [bits] = ceil(log2(N))
```

כאשר מיישמים זאת על תכנון ה-default:

```text
table ID width       = ceil(log2(6))    = 3 bits
table address width  = ceil(log2(147))  = 8 bits
selector address     = ceil(log2(2966)) = 12 bits
selector count width = ceil(log2(2967)) = 12 bits
reservoir count      = ceil(log2(32+1)) = 6 bits
```

שדות ה-address יכולים לקודד ערכים לא חוקיים. לדוגמה, שמונה address bits
מייצגים 0–255, אף שרק 0–146 חוקיים. לכן נדרשות ב-RTL בדיקות bounds מפורשות.

`SYMBOL_WIDTH=9` מייצג 0–511. ה-benchmark משתמש לכל היותר ב-147 alphabet
indices, ולכן מבחינה מתמטית שמונה bits היו מספיקים; התכנון הפעיל שומר על תשעה
bits כ-interface margin וכדי להתאים לייצוג הקיים בפרויקט. ערכים מעל טווח
ה-alphabet/EOB שהוגדר אינם symbols שימושיים עבור ה-benchmark.

## 2.3 טבלת ה-ports המלאה של ה-top level

### Clock ו-reset

| Signal | כיוון | רוחב | משמעות | דרישת Timing |
|---|---:|---:|---|---|
| `clk` | in | 1 | Core clock | יעד של 200 MHz, עם period של 5.000 ns |
| `rst_n` | in | 1 | Active-low reset | יכול לעבור assertion באופן asynchronous; חייב לעבור deassertion באופן synchronous ל-`clk` |

### Configuration ports

ה-Configuration מתקבל רק כאשר ה-core במצב idle ו-`cfg_ready=1`.

| Signal | כיוון | רוחב | ערך חוקי | משמעות |
|---|---:|---:|---|---|
| `cfg_ready` | out | 1 | 0/1 | גבוה כאשר ניתן לקבל writes ל-dictionary/selector |
| `dict_wr_en` | in | 1 | Pulse/high במשך transfer edge אחד | מתכנת או מבטל table entry אחד |
| `dict_wr_table` | in | 3 | 0–5 | ה-table bank שאליו כותבים |
| `dict_wr_addr` | in | 8 | 0–146 | כתובת ה-entry בתוך ה-bank |
| `dict_wr_code` | in | 16 | Code מיושר לימין | Canonical Huffman code; ה-Hardware מיישר אותו לצד ה-MSB |
| `dict_wr_symbol` | in | 9 | בדרך כלל 0–146 | Decoded symbol שמוחזר כאשר יש match |
| `dict_wr_len` | in | 5 | 0–16 | אורך ה-code; אפס מבטל את ה-slot בכתובת זו |
| `selector_wr_en` | in | 1 | Pulse/high במשך transfer edge אחד | כותב selector entry אחד |
| `selector_wr_addr` | in | 12 | 0–2965, contiguous frontier | ה-selector index |
| `selector_wr_table` | in | 3 | 0–5 | ה-table שנבחר עבור קבוצת 50 ה-symbols המתאימה |

ל-programming ports הפשוטים אין צמד `valid/ready` נפרד. במקום זאת, ה-contract
שלהם הוא:

```text
configuration_write = cfg_ready AND write_enable
```

MMIO/config-loader wrapper חייב ליצור write pulse יציב אחד ב-rising edge אחד,
ואסור לו להפעיל write יחד עם `start`. Writes לא חוקיים מגדירים pending
configuration error וגורמים לדחיית ה-start הבא.

יש לכתוב selector entries בסדר עולה ורציף כאשר מרחיבים את ה-loaded region.
מותר לכתוב מחדש entry מוקדם יותר. לשימוש בטוח מחדש ב-table, ה-Software צריך
לתכנת את כל 147 ה-addresses בכל bank, ולכתוב `dict_wr_len=0` עבור symbols שאינם
קיימים, כדי ש-entries ישנים המסומנים valid לא ישרדו מ-job קודם.

### Job-control inputs

| Signal | כיוון | רוחב | ערך חוקי | משמעות |
|---|---:|---:|---|---|
| `start` | in | 1 | Pulse אחד במצב idle | לוכד את שדות ה-job ומתחיל payload אחד |
| `start_bit` | in | 3 | 0–7 | מספר ה-leading bits שמושלכים מה-source byte הראשון |
| `selector_count` | in | 12 | 1–2966 | מספר ה-table selectors התקפים |
| `eob_symbol` | in | 9 | 0–146; ה-benchmark משתמש ב-`symbols_in_use-1` | ה-symbol שמסיים את ה-Huffman block |
| `symbol_capacity` | in | 32 | לפחות 1 | המספר המרבי של outputs שיתקבלו, כולל EOB |

שדות אלה חייבים להישאר יציבים במהלך ה-`start` edge. ה-top לוכד אותם, ולכן הם
יכולים להשתנות לאחר מכן בלי להשפיע על ה-job הפעיל.

### Compressed-byte input stream

| Signal | כיוון | רוחב | משמעות |
|---|---:|---:|---|
| `byte_valid` | in | 1 | ה-producer מציג byte |
| `byte_ready` | out | 1 | ל-reservoir יש מקום לקבל אותו |
| `byte_data` | in | 8 | ה-byte הדחוס; bit 7 מעובד ראשון |
| `byte_last` | in | 1 | ה-byte שהתקבל הוא ה-byte האחרון הזמין ל-job |

Byte עובר כאשר:

```text
byte_fire = byte_valid AND byte_ready
```

`byte_last` הוא חלק מה-byte payload ויש לו משמעות רק בזמן transfer. ה-source
יכול להיות ארוך יותר מ-Huffman payload המדויק, משום ש-EOB ו-`bits_consumed`
מגדירים את ה-consumption הלוגי. אף על פי כן, עליו להיות buffer ממופה ומוגבל,
וה-byte הממופה האחרון חייב להגיע עם `byte_last=1`.

### Decoded-symbol output stream

| Signal | כיוון | רוחב | משמעות |
|---|---:|---:|---|
| `symbol_valid` | out | 1 | קיימת תוצאה יציבה |
| `symbol_ready` | in | 1 | ה-consumer יכול לקבל את התוצאה |
| `symbol` | out | 9 | ה-Huffman alphabet index שפוענח |
| `code_length` | out | 5 | מספר ה-bits הדחוסים האמיתיים שבהם השתמשה תוצאה זו, 1–16 |
| `table_id` | out | 3 | ה-table bank שיצר את התוצאה, 0–5 |
| `symbol_eob` | out | 1 | התוצאה התקפה הנוכחית שווה ל-EOB symbol שהוגדר |

Symbol עובר כאשר:

```text
symbol_fire = symbol_valid AND symbol_ready
```

ה-output payload המורכב נשאר יציב כל עוד `symbol_valid=1` ו-`symbol_ready=0`:
ה-matcher result register מחזיק symbol/length, ה-`active_table_q` של ה-top מחזיק
את `table_id`, ו-`symbol_eob` נגזר combinational מאותם registers יציבים. EOB
נכלל בתור output symbol וגם ב-`symbols_produced`.

במימוש DMA, רק את ה-`symbol` ברוחב תשעה bits צריך לכתוב ל-memory.
`code_length` ו-`table_id` יכולים להישאר debug/trace signals, משום שה-counter
המצטבר `bits_consumed` מספק את ה-bit advance הנראה ל-Software.

### Status ו-counters

| Signal | כיוון | רוחב | משמעות |
|---|---:|---:|---|
| `busy` | out | 1 | Job אחד פעיל |
| `done` | out | 1 | Terminal pulse באורך cycle אחד לאחר הצלחה או שגיאה |
| `error` | out | 1 | ה-job הסתיים בכישלון; נשאר זמין עד ה-start/reset הבא |
| `error_code` | out | 8 | סיבת הכישלון המקודדת |
| `bits_consumed` | out | 32 | סכום אורכי ה-code שהתקבלו לאחר `start_bit` |
| `symbols_produced` | out | 32 | מספר ה-output symbols שהתקבלו, כולל EOB |
| `cycle_count` | out | 64 | מספר ה-core clocks שבהם המודול היה busy |
| `input_stall_cycles` | out | 32 | Cycles שבהם ניתן היה לקבל byte אך אף byte לא היה valid |
| `output_stall_cycles` | out | 32 | Cycles שבהם symbol היה valid אך לא ready |

מכיוון ש-`done` הוא pulse, MMIO adapter חיצוני חייב ללכוד אותו לתוך sticky
status bit, ולנקות bit זה בעקבות acknowledgement מה-Software או ב-start הבא.

## 2.4 Wires פנימיים חשובים

ה-interconnect signals הבאים מסבירים כיצד ה-modules מתחברים. הם אינם pins
חיצוניים של ה-core.

| Signal | רוחב | Source -> destination | מטרה |
|---|---:|---|---|
| `active_table_q` | 3 | top register -> six-table wrapper | בחירת bank רשומה עבור timing רגיל של lookup |
| `selector_current_valid` | 1 | top combinational check | מוכיח שה-selector index/count/table חוקיים |
| `reservoir_peek_bits` | 16 | reservoir -> matcher | חלון ה-bits הבא, מיושר לצד ה-MSB |
| `reservoir_peek_valid` | 1 | reservoir -> top | חלון מלא, או חלון סופי חלקי וחוקי, חשוף |
| `reservoir_valid_bits` | 6 | reservoir -> top | מספר ה-bits האמיתיים; דוחה match שמשתמש ב-zero padding |
| `reservoir_last_seen` | 1 | reservoir -> top | ה-input byte האחרון התקבל |
| `matcher_lookup_valid` | 1 | top -> selected matcher | מבקש match רק כאשר אין תוצאה קודמת שממתינה |
| `matcher_lookup_ready` | 1 | matcher -> top | ה-selected output register יכול לקבל request |
| `matcher_result_valid` | 1 | matcher -> top | קיימת תוצאת match/no-match רשומה |
| `matcher_result_ready` | 1 | top -> matcher | מסיר תוצאה שהתקבלה או מנקז terminal bad result |
| `matcher_found` | 1 | matcher -> top | לפחות table entry אחד יצר match |
| `matcher_symbol` | 9 | matcher -> top | ה-decoded symbol שנבחר |
| `matcher_len` | 5 | matcher -> top/reservoir | אורך ה-code שנבחר וכמות ה-consume הבאה |
| `reservoir_consume_valid` | 1 | output handshake -> reservoir | מבקש להסיר `matcher_len` bits |
| `reservoir_consume_ready` | 1 | reservoir -> top | מאשר שה-length אינו אפס ואינו גדול ממספר ה-bits האמיתיים |
| `output_fire` | 1 | top handshake result | Event אטומי שמקדם bits, symbol count, group count, ואולי selector |
| `dict_cfg_error` | 1 | six-table wrapper -> top | לוכד בקשת dictionary programming לא חוקית |

כלל ה-correctness הקריטי הוא שכל שינויי מצב ה-decode קשורים ל-`output_fire`,
ולא רק ל-`symbol_valid`. לכן output שנמצא ב-stall אינו יכול לקדם את ה-reservoir
או את ה-table selector.

## 2.5 גודל Storage ו-memory

### מצב ה-CAM tables

כל direct-match entry מאחסן:

```text
B_entry = B_pattern + B_mask + B_symbol + B_length + B_valid
        = 16 bits + 16 bits + 9 bits + 5 bits + 1 bit
        = 47 bits/entry
```

עבור שישה tables עם 147 entries בכל אחד:

```text
N_CAM_entries = 6 tables * 147 entries/table = 882 entries

B_CAM = 882 entries * 47 bits/entry
      = 41,454 bits
      = 5,181.75 byte-equivalents
      = 5.060 KiB when perfectly bit-packed
```

שבר ה-byte מקובל בחישוב מספר bits; מיפוי FPGA פיזי משתמש ב-LUTs,
flip-flops, distributed RAM או memory primitives שלמים, ולכן יצרוך granularity
גדולה יותר מאשר byte array ארוז באופן מושלם.

לכל bank:

```text
B_bank = 147 * 47 = 6,909 bits
```

### Selector storage

```text
B_selectors = 2,966 entries * 3 bits/entry
            = 8,898 bits
            = 1,112.25 byte-equivalents
```

### מצב Datapath/control מפורש

ה-registered state הנוסף והחשוב ביותר הוא בקירוב:

| State | Bits |
|---|---:|
| נתוני Reservoir, count, offset ו-first/last flags | `32+6+3+1+1 = 43` |
| שישה matcher result buffers | `6*(valid+found+symbol+len) = 6*(1+1+9+5) = 96` |
| שדות selector/job/control שנלכדו | approximately 88 |
| Status ו-counters גלויים | approximately 203 |
| **Subtotal מעבר ל-CAM/selectors** | **approximately 430** |

לכן inventory תחתון ברמת bits הוא:

```text
B_state,lower = 41,454 + 8,898 + 430
              = 50,782 bits
              = 6,347.75 byte-equivalents
              approximately 6.20 KiB bit-packed
```

זה **אינו** FPGA area report. החישוב אינו כולל clock trees, reset routing,
decode/mux logic, לוגיקת compare ו-priority, carry structures,
placement fragmentation או MMIO/DMA wrapper כלשהו. 882 ההשוואות המקביליות
בעלות mask עשויות להיות משמעותיות יותר עבור LUT area ממספר ה-bits המאוחסנים
הגולמי.

### גודלי External buffers עבור ה-workload שנמדד

ה-observations הקבועים של ה-workload שבהם השתמש הפרויקט הם:

```text
compressed source           = 67,562 bytes
decoded Huffman symbols N   = 148,271 symbols including EOB
selectors                   = 2,966 entries
```

עם ה-packed ABI המוצע:

```text
table image = 6 * 147 * 4 bytes = 3,528 bytes
selector image = 2,966 * 1 byte = 2,966 bytes
configuration image total = 6,494 bytes

destination = 148,271 symbols * 2 bytes/symbol
            = 296,542 bytes
```

ה-source, ה-configuration image וה-destination הם buffers ב-system memory,
ולא storage בתוך ה-core RTL הנוכחי.

## 2.6 יעד Clock וחישוב Timing

### המרה בין Frequency ל-period

Clock frequency ו-period הם הופכיים:

```text
T_clk [s/cycle] = 1 / f_clk [cycles/s]
```

ביעד `f_clk = 200 MHz = 200,000,000 cycles/s`:

```text
T_clk = 1 / 200,000,000 s
      = 5.000e-9 s
      = 5.000 ns/cycle
```

הפרויקט בוחר 200 MHz בתור יעד FPGA/SoC חינוכי מתון: עם `II=2` הנוכחי הוא
מספק תקרה עגולה של 100 Msymbol/s, ובכל זאת מחייב דיון אמיתי במסלול ה-priority
הרחב. היעד אינו נגזר מ-device שנבחר. ה-XDC שסופק מבקש מ-FPGA implementation
tool לנתח דרישה זו:

```tcl
create_clock -name core_clk -period 5.000 [get_ports {clk}]
```

השורה אינה גורמת בפני עצמה ל-circuit לפעול ב-200 MHz.

### Setup timing

עבור כל register-to-register path, דרישת setup מפושטת היא:

```text
T_cq,max + T_logic,max + T_route,max + T_setup + T_uncertainty <= T_clk
```

באופן שקול:

```text
T_arrival  = T_cq,max + T_logic,max + T_route,max
T_required = T_clk - T_setup - T_uncertainty
setup_slack = T_required - T_arrival
```

Slack חיובי עומד ביעד. Slack שלילי פירושו שה-path איטי מדי.

דוגמה להמחשה בלבד:

```text
post-route critical path, including required margins = 6.4 ns
target period                                      = 5.0 ns
setup slack = 5.0 ns - 6.4 ns = -1.4 ns            (fails)

Fmax approximately = 1 / 6.4 ns
                   = 156.25 MHz
```

ב-156.25 MHz, אין לדווח על התכנון כמימוש 200 MHz; יש להנמיך את יעד ה-clock
או לשנות את ה-critical path.

### Hold timing

הפיכת path למהיר יותר אינה מבטיחה באופן אוטומטי hold timing תקין. תנאי
minimum-delay מפושט הוא:

```text
T_cq,min + T_logic,min + T_route,min >= T_hold + T_skew
```

Implementation tools מתקנים בדרך כלל hold violations באמצעות הוספת route/data
delay; שינוי ה-clock period אינו פותר אותם ישירות.

### Critical paths צפויים

סיכוני ה-timing הסבירים, שאותם יש לאשר באמצעות post-route report, הם:

1. מצב table/result מאוחסן -> השוואות mask/equality ברוחב 16-bit -> בחירת
   shortest-first בין 147 entries -> matcher result register;
2. variable left shift ברוחב 32-bit יחד עם בחירת bit-count/refill ->
   reservoir registers; וכן
3. רק בגבול של כל 50 symbols, הגדלת selector index -> קריאת selector-memory
   -> בדיקת טווח -> active table רשום.

רישום `active_table_q` כבר הסיר את ה-selector memory ממסלול ה-CAM הרגיל עבור
כל symbol. אם מסלול הגבול עדיין איטי, ניתן להוסיף next selector שנעשה לו
prefetch או synchronous selector RAM stage. אם מסלול ה-CAM/priority איטי,
balanced priority tree, CAM מחולק או canonical-range decoder עדיפים על קבלה
עיוורת של slack שלילי.

## 2.7 יחידות Throughput ו-latency

ל-top המלא יש initiation interval ללא stalls:

```text
II = 2 cycles/symbol
```

לכן:

```text
symbol throughput [symbols/s] = f_clk [cycles/s] / II [cycles/symbol]
```

ב-200 MHz:

```text
throughput = 200,000,000 / 2
           = 100,000,000 symbols/s
           = 100 Msymbol/s
```

זוהי מגבלת ה-lookup/consume הפנימית. ה-byte source יכול לספק:

```text
input bandwidth = 1 byte/cycle * 200,000,000 cycles/s
                = 200 MB/s
                = 1.6 Gbit/s
```

ה-output פולט לכל היותר symbol אחד בכל שני cycles. אם הוא נארז בשני bytes:

```text
output bandwidth = 100,000,000 symbols/s * 2 bytes/symbol
                 = 200 MB/s
```

DMA engine אמיתי חייב לתמוך בשני הכיוונים בו-זמנית, או שיוסיף stalls אשר
מגדילים את זמן ה-job.

## 2.8 צריכת Power: מה ניתן ומה לא ניתן לחשב כעת

### ההבחנה הנדרשת

ה-RTL אינו קובע ערך watts מהימן. Dynamic power ו-static power תלויים בטכנולוגיית
FPGA/ASIC שנבחרה, ב-voltage, במיפוי המימוש, ב-routing capacitance, ב-clock
network, ב-temperature וב-switching activity אמיתי. לכן המפרט הטכני הנכון
כרגע הוא:

```text
expected core power draw = TBD after synthesis, placement/routing,
                           and activity-based power analysis
```

הדוח משתמש ב-`0.40 W` רק בתור **דוגמת תכנון**, ולא כערך שנמדד או נחזה. ערך
מספרי "צפוי" ללא target device יוצר דיוק מדומה.

### רכיבי Dynamic ו-static

מודל CMOS מקובל מסדר ראשון הוא:

```text
P_total [W] = P_static [W] + P_dynamic [W]

P_dynamic [W] approximately = sum_j(alpha_j * C_j [F] * V_j^2 [V^2]
                                      * f_j [1/s])
```

כאשר:

- `alpha_j` היא transition activity ממוצעת של node/group `j` בכל cycle;
- `C_j` הוא ה-effective switched capacitance שלו;
- `V_j` הוא ה-supply voltage שלו; וכן
- `f_j` הוא ה-switching/clock frequency שלו.

בדיקת dimensions:

```text
F * V^2 * 1/s = (C/V) * V^2 / s = C*V/s = J/s = W
```

עבור FPGA, ה-vendor power tool מקבל effective capacitance מה-placed netlist
ומה-routing. קובץ VCD או SAIF מ-test מייצג מספק activity. ה-flow המומלץ:

```text
choose device and voltage
-> synthesize
-> place and route at 5 ns constraint
-> simulate benchmark vectors
-> export VCD/SAIF activity
-> run vendor power analysis
-> report static, clocks, logic, signals, memories, I/O, and total watts
```

### Energy לכל job

Energy משלב power וזמן פעילות:

```text
E_job [J/job] = P_average [W] * T_job [s/job]
```

דוגמה להמחשה בלבד, תוך שימוש ב-`P_average=0.40 W` שהונח וב-no-stall target-time
האנליטי `T_job=1.482725 ms`:

```text
E_job = 0.40 J/s * 0.001482725 s/job
      = 0.00059309 J/job
      = 0.593 mJ/job
```

Sensitivity, עדיין להמחשה בלבד:

| Average core power שהונח | Energy ב-1.482725 ms |
|---:|---:|
| 0.20 W | 0.297 mJ |
| 0.40 W | 0.593 mJ |
| 0.80 W | 1.186 mJ |

ערכים אלה מלמדים את החישוב ותוחמים דיון תכנוני; אף אחד מהם אינו power result
לאחר implementation.

### השפעת Frequency על energy

אם ה-voltage וכמות העבודה קבועים ומתעלמים מ-leakage, dynamic power גדל בקירוב
באופן לינארי עם frequency, בעוד זמן ה-job קטן ביחס הפוך:

```text
P_dynamic proportional to f
T_job proportional to 1/f
E_dynamic = P_dynamic * T_job approximately constant
```

בפועל ה-energy אינו קבוע לחלוטין, משום ש-leakage פועל במשך זמן קצר יותר
ב-frequency גבוה, פעילות ה-clock/routing משתנה, ייתכן שיהיה צורך להעלות voltage,
ו-overhead של memory/DMA לא בהכרח משתנה באותו יחס. לכן יש למדוד energy מתוך
workload ממומש, ולא להסיק אותו מ-frequency בלבד.
