# **שכבת דרייבר וממשק התוכנה: הדרייבר מספק שכבת הפשטה (Abstraction).**
הכיוון הכללי נכון, אבל הטקסט מייחס ל-RTL הקיים יכולות שאינן נמצאות ב-`huffman_find_simple.sv`, כגון MMIO, ‏DMA, ‏`start`, ‏`done`, ‏interrupt ו-bit reservoir. בנוסף, יש כמה אי-דיוקים לגבי מבנה ה-table וקצב העבודה.

## נוסח מתוקן

**שכבת Driver וממשק Software**

ה-Driver מספק שכבת Abstraction בין תוכנת `pyflate` לבין ה-system wrapper של המאיץ. חשוב להדגיש כי `huffman_find_simple.sv` הוא bus-independent core ואינו כולל בעצמו MMIO, ‏DMA, ‏interrupt controller או registers מסוג `start` ו-`done`. רכיבים אלה נדרשים ב-wrapper חיצוני.

ממשק Software אפשרי יכלול את הפונקציות הבאות:

### `huffman_accel_init`

```
int huffman_accel_init(huffman_accel_t *dev);
```

הפונקציה נקראת בעת אתחול ה-Driver או לפני השימוש הראשון במאיץ. היא מאתרת את התקן ה-Hardware, ממפה את אזור ה-MMIO ל-virtual address space של ה-Driver, מגדירה את ערוצי ה-DMA ורושמת interrupt handler אם המערכת משתמשת ב-interrupts.

לאחר האתחול, ה-Driver יכול להפעיל `SOFT_RESET` באמצעות control register ב-MMIO. ה-`SOFT_RESET` צריך להפוך בתוך ה-wrapper ל-clear סינכרוני עבור ה-table state, ה-status registers וה-FIFOs.

ה-`rst_n` של ה-core הוא Hardware reset נפרד. לא מומלץ לחבר ביט Software ישירות ל-`rst_n`, משום ששחרור `rst_n` חייב להיות מסונכרן ל-`clk`.

### `huffman_load_tables`

```
int huffman_load_tables(
    huffman_accel_t *dev,
    const huffman_code_t *tables,
    size_t table_count,
    size_t entries_per_table,
    const uint8_t *selectors,
    size_t selector_count);
```

הפונקציה נקראת לפני פענוח block שמשתמש בקבוצת Huffman tables חדשה. עבור workload זה נטענים עד שישה tables, כאשר בכל table קיימים עד `147` entries פעילים.

כל entry שמועבר ל-Hardware מכיל:

```
table_id
entry_address
code
symbol
code_length
```

ה-Software אינו צריך להעביר `pattern`, ‏`mask` או `valid_mem` ישירות. ה-core מקבל `dict_wr_code` מיושר לימין ומייצר בעצמו את `pattern` ואת `mask`:

```
pattern = code << (KEY_WIDTH - code_length)
mask    = all_ones << (KEY_WIDTH - code_length)
```

כתיבת `code_length=0` מבטלת entry באמצעות ניקוי ה-`valid` הפנימי.

ה-wrapper מתרגם כתיבת MMIO ל-signals הבאים:

```
dict_wr_en
dict_wr_addr
dict_wr_code
dict_wr_symbol
dict_wr_len
```

כאשר קיימים שישה banks, ה-wrapper מוסיף גם `table_id` ובוחר לאיזה matcher לנתב את הכתיבה. יש לטעון גם את רשימת ה-selectors, משום שב-bzip2 ה-table הפעיל עשוי להשתנות בכל קבוצה של 50 symbols.

### `huffman_decode_block_async`

```
huffman_job_t *huffman_decode_block_async(
    huffman_accel_t *dev,
    const void *src,
    size_t src_size,
    void *dst_tokens,
    size_t dst_capacity,
    unsigned int start_bit,
    unsigned int eob_symbol);
```

הפונקציה מפעילה job אחד עבור Huffman payload של block. ה-Driver ממפה את buffers באמצעות ה-DMA API של מערכת ההפעלה ומטפל ב-cache coherence לפי דרישות הפלטפורמה. במערכת coherent ייתכן שלא נדרש flush ידני; במערכת non-coherent ה-Driver מבצע את פעולות ה-sync הנדרשות.

לאחר מכן ה-Driver כותב ל-MMIO את:

```
source address
source size
destination address
destination capacity
start_bit
selector_count
EOB symbol
START
```

RX DMA קורא compressed bytes מה-DRAM ומכניס אותם ל-RX FIFO. ה-bit reservoir אוסף את ה-bytes ומציג ל-CAM core חלון `lookup_bits[15:0]`.

כאשר נמצאת התאמה, ה-core מחזיר:

```
match_found
match_symbol
match_len
```

לאחר שהתוצאה מתקבלת באמצעות `result_valid && result_ready`, ה-bit reservoir מתקדם ב-`match_len` bits ומייצר את החלון הבא. ה-token נכתב ל-TX FIFO, וממנו TX DMA כותב אותו ל-destination buffer ב-DRAM.

ב-wrapper הפשוט קיימת תלות בין `match_len` לבין יצירת החלון הבא, ולכן מתקבל בקירוב `II=2 cycles/symbol`, ולא בהכרח symbol חדש בכל clock.

הפלט הוא stream של Huffman tokens ולא בהכרח הקובץ המפוענח הסופי. ה-Software ממשיך לבצע את שלבי `RUNA/RUNB`, ‏`move-to-front`, ‏`inverse BWT` ו-run-length decoding.

בסיום EOB או במקרה של error, ה-wrapper שומר `DONE` ו-`STATUS` ב-sticky registers ויכול להפעיל interrupt. מאחר שהפונקציה היא asynchronous, היא חוזרת לפני סיום החישוב. ה-Software יכול להמתין באמצעות API נוסף:

```
int huffman_wait(
    huffman_job_t *job,
    huffman_status_t *status);
```

## מדוע הנוסח המקורי לא היה מדויק

1. **מיפוי הכתובת תואר בצורה לא מדויקת.**  
    ה-Driver אינו הופך את כתובת המאיץ ל-RAM רגיל. הוא ממפה MMIO registers ל-virtual address space באמצעות מנגנון של מערכת ההפעלה.
    
2. **`rst_n` אינו Software reset register.**  
    חיבור ישיר של ביט MMIO ל-`rst_n` עלול ליצור שחרור reset שאינו מסונכרן. עדיף לממש `SOFT_RESET` סינכרוני ונפרד.
    
3. **ה-RTL הנוכחי אינו כולל MMIO, ‏DMA או interrupt.**  
    אלה רכיבים מוצעים של system wrapper ולא חלק מ-`huffman_find_simple.sv`.
    
4. **מספר ה-entries אינו 288.**  
    ברירת המחדל של ה-core הנוכחי היא `NUM_ENTRIES=147`, בהתאם ל-workload שנמדד.
    
5. **ה-Software אינו מעביר `pattern`, ‏`mask` ו-`valid_mem`.**  
    הוא מעביר `dict_wr_code`, ‏`dict_wr_symbol` ו-`dict_wr_len`. ה-core מייצר את `pattern` וה-`mask` ומנהל את `valid_mem` פנימית.
    
6. **יש יותר מ-Huffman table אחד.**  
    ב-bzip2 יכולים להיות עד שישה tables, וה-selector מחליף ביניהם בכל קבוצה של 50 symbols. לכן טעינת table יחיד אינה מתארת את ה-integration המלא.
    
7. **המאיץ אינו מפענח את כל הקובץ.**  
    הוא מאיץ את Huffman symbol lookup. שלבי bzip2 המאוחרים נשארים ב-Software.
    
8. **DMA אינו מספק ישירות חלון חדש בכל clock.**  
    DMA מספק bytes ל-FIFO. ה-bit reservoir הוא זה שיוצר את חלון ה-16 bits ומתקדם לפי `match_len`.
    
9. **לא מובטח symbol אחד בכל clock.**  
    ה-CAM core יכול לקבל lookup בכל cycle בתנאים המתאימים, אבל wrapper עם feedback מהתוצאה ל-reservoir עובד בתכנון הפשוט ב-`II=2`.
    
10. **`done` לא צריך להיות pulse שניתן לפספס.**  
    ב-MMIO wrapper עדיף לשמור `DONE` כ-sticky status או interrupt pending עד שה-Driver מבצע acknowledge.
    
11. **קיים typo של `DNA`.**  
    המונח הנכון הוא `DMA`.
    
12. **`size` יחיד אינו מספיק.**  
    צריך להבחין לפחות בין `src_size` לבין `dst_capacity`, וכן להעביר `start_bit`, ‏EOB ונתוני selectors.

# **ביצועים\שטח\הספק**

הכיוון הכללי נכון, אבל יש לתקן את מספר ה-entries, את תיאור ה-critical path, את השימוש ב-`LPM`, ואת הטענות המספריות לגבי speedup ו-power.

## נוסח מתוקן

**Performance, Area and Power Trade-offs**

הארכיטקטורה שנבחרה משתמשת ב-CAM-style parallel comparison כדי להחליף את החיפוש הסדרתי של `find_next_symbol`. היא משפרת את throughput של פעולת ה-lookup, אך יוצרת trade-offs בין `Fmax`, ‏latency, ‏area ו-power.

### 1. Performance מול תדר עבודה

המסלול ה-combinational המרכזי בתוך `hardware_dictionary_accelerator` הוא:

```
lookup_bits
    -> 147 masked comparisons
    -> raw_matches
    -> priority-selection logic
    -> candidate_symbol and candidate_len
    -> result register
```

ה-clock period המינימלי צריך לקיים:

```
T_clk,min >= T_cq + T_CAM + T_priority + T_mux
             + T_route + T_setup + T_uncertainty

Fmax <= 1 / T_clk,min
```

התוצאה נשמרת ב-register, ולכן לולאת ה-feedback של ה-system wrapper אינה מסלול combinational יחיד. היא תלות בין cycles:

```
Result register
    -> match_len
    -> Bit Reservoir shift
    -> next lookup_bits
    -> CAM lookup
    -> Result register
```

ה-core עצמו יכול לקבל lookup חדש בכל cycle כאשר `lookup_ready=1` וה-consumer מקבל את התוצאות. עם זאת, ב-wrapper הפשוט החלון הבא תלוי ב-`match_len` של התוצאה הקודמת. לכן מתקבל:

```
II = 2 cycles/symbol
```

עבור target של `200 MHz`:

```
Throughput = f_clk / II
           = 200 MHz / 2
           = 100 Msymbol/s
```

הוספת pipeline register בתוך ה-CAM או ה-priority logic עשויה להעלות את `Fmax`, אך גם להגדיל את latency. בזרם Huffman יחיד, שבו ה-lookup הבא תלוי באורך ה-code הקודם, pipeline נוסף עלול להגדיל גם את `II`.

כדי שה-pipeline ישפר throughput כאשר `II` משתנה מ-2 ל-3, נדרש:

```
Throughput_new >= Throughput_old

f_new / 3 >= f_old / 2

f_new / f_old >= 3 / 2

f_new >= 1.5 * f_old
```

לכן, אם התכנון הנוכחי עובד ב-`200 MHz` עם `II=2`, pipeline שמעלה את `II` ל-3 צריך להגיע לפחות ל-`300 MHz` כדי לשמור על אותו throughput:

```
200 MHz / 2 = 100 Msymbol/s
300 MHz / 3 = 100 Msymbol/s
```

אין הצדקה להוסיף pipeline לפני ש-synthesis ו-Static Timing Analysis מראים שהמסלול הנוכחי אינו עומד ב-clock constraint.

### 2. Area מול Performance

ה-core הנוכחי מכיל `147` entries ולא `288`. כל entry שומר:

```
pattern = 16 bits
mask    = 16 bits
symbol  = 9 bits
length  = 5 bits
valid   = 1 bit
```

לכן:

```
B_entry = 16 + 16 + 9 + 5 + 1
        = 47 bits

B_one_bank = 147 * 47
           = 6,909 bits
           = 863.625 bytes
           = 0.843 KiB
```

בנוסף ל-storage, קיימים `147` masked comparators ו-priority-selection network.

אם ה-system wrapper כולל שישה banks כדי לתמוך במעבר מיידי בין Huffman tables של bzip2:

```
Number of comparators = 6 * 147
                      = 882 comparators

B_six_banks = 6 * 6,909
            = 41,454 bits
            = 5.06 KiB
```

אלה storage bits בלבד. הם אינם כוללים את עלות ה-comparators, ‏priority logic, ‏routing, ‏registers, ‏selectors, ‏FIFO או DMA.

ה-RTL אינו מבצע `Longest Prefix Match`. ה-priority logic בוחר תחילה את ה-code הקצר ביותר, ובשוויון את ה-entry בעל ה-address הנמוך ביותר. ב-Huffman table חוקי ה-codes הם prefix-free ולכן בדרך כלל קיימת התאמה יחידה. מטרת ה-priority rule היא להגדיר התנהגות deterministic גם במקרה של table לא חוקי.

חלופה אפשרית היא two-level lookup table:

```
First-level table:
    Use the first 8 bits as a direct index.

Short code:
    Return the symbol immediately.

Long code:
    Use a secondary table for the remaining bits.
```

גישה זו יכולה להפחית את מספר ה-comparators ואת routing congestion, ואף להשתמש ב-BRAM או SRAM. המחיר הוא שקודים ארוכים דורשים access נוסף, ולכן latency ו-`II` עשויים להיות תלויים באורך ה-code.

### 3. Dynamic Power, Static Power ו-Energy

אין עדיין synthesis או power analysis, ולכן לא ניתן לטעון שה-power גבוה או נמוך בערך מוחלט.

ה-dynamic power תלוי בקירוב ב:

```
P_dynamic ~= alpha * C_switched * V^2 * f_clk
```

כאשר:

```
alpha       = switching activity
C_switched  = effective switched capacitance
V           = supply voltage
f_clk       = clock frequency
```

השוואת `147` entries במקביל מגדילה את `C_switched`. לכן CAM שטוח צפוי לצרוך יותר dynamic power בכל lookup בהשוואה ל-tree walker סדרתי קטן. עם זאת, הוא עשוי לסיים את העבודה במספר קטן יותר של cycles.

ה-energy הכולל לכל job הוא:

```
E_job = P_average * T_job
```

לכן dynamic power גבוה יותר אינו אומר בהכרח energy גבוה יותר; יש למדוד גם את זמן הביצוע. ללא power report ו-switching activity לא ניתן לטעון שהיעילות האנרגטית טובה יותר מה-CPU.

ה-RTL הקיים כבר מפחית switching לוגי באמצעות:

```
raw_matches[i] =
    lookup_valid
    && valid_mem[i]
    && comparison_result
```

כאשר `lookup_valid=0`, ‏`raw_matches` אינם מופעלים. ב-wrapper עם שישה banks ניתן גם להעביר `lookup_valid` ו-`lookup_bits` רק ל-bank הפעיל.

פעולה זו היא operand isolation ולא Clock Gating פיזי. Clock Gating אינו ממומש ב-core הנוכחי.

ב-ASIC ניתן להוסיף integrated clock-gating cell עבור registers שאינם פעילים. ב-FPGA עדיף להשתמש ב-clock-enable resources של ה-device ולא ליצור clock gated באמצעות logic רגיל, משום שהדבר עלול לגרום ל-clock skew ולבעיות timing.

### סיכום ה-trade-offs

|החלטה|יתרון|מחיר|
|---|---|---|
|`147` parallel comparators|חיפוש מקבילי ומהיר|area, routing ו-dynamic power גבוהים יותר.|
|Flat priority network|מימוש ישיר וברור|עלול להיות ה-critical path.|
|Registered output|תמיכה בטוחה ב-backpressure|מוסיף cycle של latency.|
|Feedback ל-bit reservoir|צריכת מספר bits משתנה באופן מדויק|מגביל את ה-wrapper הפשוט ל-`II=2`.|
|שישה CAM banks|החלפת table מיידית|`882` comparators ו-area גדול פי שישה.|
|Two-level lookup חלופי|פחות comparators ואפשרות לשימוש ב-BRAM|access נוסף עבור codes ארוכים.|
|Pipeline נוסף|עשוי להעלות את `Fmax`|עלול להגדיל latency ו-`II`.|
|Operand isolation|מפחית switching בכניסות לא פעילות|אינו חוסך area ואינו Clock Gating.|

## מדוע הנוסח המקורי לא היה מדויק

1. **מספר ה-entries אינו 288.**  
    ברירת המחדל של ה-core הנוכחי היא `NUM_ENTRIES=147`. שישה banks מכילים יחד `882` entries פיזיים.
    
2. **לא מובטח symbol אחד בכל clock.**  
    ה-core מסוגל לקבל lookup בכל cycle בתנאים המתאימים, אבל ה-wrapper עם bit-feedback עובד בתכנון הפשוט ב-`II=2`.
    
3. **לולאת ה-feedback אינה כולה critical combinational path.**  
    ה-result register מפריד בין ה-CAM lookup לבין עדכון ה-bit reservoir. לכן מדובר בתלות בין cycles ולא בלולאה combinational מלאה.
    
4. **Pipeline לא בהכרח מוריד throughput.**  
    הוא מגדיל latency, אך יכול לשמור על `II=1` כאשר קיימים inputs בלתי תלויים. בזרם Huffman יחיד התלות ב-`match_len` עלולה להגדיל את `II`, ולכן יש לבדוק את היחס בין העלייה בתדר לבין העלייה ב-`II`.
    
5. **ה-RTL אינו מבצע `Longest Prefix Match`.**  
    הוא סורק lengths מ-1 עד 16 ולכן מממש shortest-length priority. בטבלת Huffman חוקית קיימת התאמה יחידה, כך שה-priority בדרך כלל אינו משפיע על התוצאה.
    
6. **ה-storage אינו כל עלות ה-area.**  
    חישוב הביטים אינו כולל comparators, ‏priority logic, ‏muxing, ‏routing ו-control. לכן אי אפשר להסיק ממנו לבדו את שטח הסיליקון.
    
7. **אין הוכחה שה-static power נמוך.**  
    Static power תלוי ב-target technology, בגודל המימוש ובמאפייני ה-device. ללא synthesis ו-power analysis אי אפשר לכמת אותו.
    
8. **הטענה על שיפור של פי 2–4 אינה נתמכת.**  
    ההערכה הנוכחית לכל ה-benchmark היא בערך `1.135x–1.626x`, לפני integration overhead. אין עדיין Hardware measurement.
    
9. **אין הוכחה ל-energy efficiency טובה יותר מה-CPU.**  
    צריך למדוד או להעריך את `P_average` ואת `T_job` בשתי המערכות.
    
10. **Clock Gating אינו ממומש בקוד.**  
    הקוד משתמש ב-`lookup_valid` וב-`valid_mem` לצורך operand gating. ב-FPGA יש להשתמש ב-clock enable ייעודי ולא בשער לוגי רגיל על קו ה-clock.
    
11. **היו שגיאות ניסוח.**  
    הביטוי “קבץ העיבוד” צריך להיות “קצב העיבוד”, “דורך שטח” צריך להיות “דורש שטח”, ו-“הפחתה” נכתבה בטעות כ-“הפחה”.