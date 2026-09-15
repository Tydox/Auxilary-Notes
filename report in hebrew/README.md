# דוח ה־Pyflate Huffman accelerator

דוח זה מתאר את ה־Huffman accelerator הייעודי ל־benchmark, בעל מפתח של 16 bit
ושישה tables, שה־top-level module שלו הוא `huffman_find_simple_top`. הדוח מחולק
לשבעת הפרקים שהתבקשו, כדי שיהיה אפשר לעבור על החומר או להסיר אותו פרק אחר פרק.

**מדיניות terminology:** ההסברים תורגמו לעברית, אך terminology מקצועי מקובל
נשאר באנגלית—למשל `cache`, `register`, `pipeline`, `interface`, `ready/valid`,
`MMIO`, `DMA`, `driver`, `RTL` ו־`SystemVerilog`. גם identifiers, signal names,
קוד, נוסחאות, מספרים ונתיבי קבצים נשמרו כפי שהם במקור.

## פרקי הדוח

1. [תיאור ה־hardware](01_hardware_description.md)
2. [Inputs, outputs, רוחבי נתונים, memory, frequency ו־power](02_inputs_outputs.md)
3. [ארכיטקטורת ה־hardware ואופן הפעולה](03_hardware_architecture.md)
4. [interface בין hardware ל־software](04_hardware_software_interface.md)
5. [הצדקת ההאצה והערכת performance](05_acceleration_justification.md)
6. [חלופות ל־block diagram](06_block_diagrams.md)
7. [פשרות בין performance, area, frequency ו־power](07_performance_area_power_tradeoffs.md)

## המימוש הקובע והיקף הפרויקט

היררכיית ה־RTL הפעילה והקובעת היא:

```text
huffman_find_simple_top
|-- huffman_bit_reservoir
`-- huffman_find_six_table
    `-- 6 x hardware_dictionary_accelerator
```

קובצי ה־RTL הקובעים של המימוש הפעיל הם:

- [`huffman_find_simple_top.sv`](../rtl/huffman_find_simple_top.sv): ה־top המלא
  והבלתי תלוי ב־bus של ה־accelerator, כולל job control, counters וטיפול בשגיאות.
- [`huffman_bit_reservoir.sv`](../rtl/huffman_bit_reservoir.sv): המרה מ־byte ל־bit
  וצריכה באורך משתנה.
- [`huffman_find_six_table.sv`](../rtl/huffman_find_six_table.sv): שישה Huffman-table
  banks פיזיים וניתוב של ה־bank הנבחר.
- [`huffman_find_simple.sv`](../rtl/huffman_find_simple.sv): matcher אחד בעל 147
  entries, הממומש כ־content-addressed logic.
- [`huffman_find_simple_top.xdc`](../constraints/huffman_find_simple_top.xdc):
  clock target אנליטי של 200 MHz.

`huffman_find_accel.sv`, `huffman_find_pkg.sv`, `HUFFMAN_FIND_ACCELERATOR.md`
ו־`sw/huffman_find_uapi.h` שייכים להצעה קודמת ועצמאית של canonical-range design
בעל 20 bit. הקובץ `pyflate_accel_uapi.h` מתאר decompressor מלא. אף אחד משני
ה־interfaces האלה אינו ה־ABI של מימוש ה־CAM הפעיל בעל 16 bit. שניהם נשמרו רק כחלופות
לצורך השוואה.

## סיווג הראיות

המספרים בדוח מסומנים במפורש כדי ש־targets לא יוצגו בטעות כמדידות:

| סיווג | משמעות |
|---|---|
| **Measured software** | התקבל מקובץ `timing.json`, מ־folded stack או מ־`perf_stat.txt` שנשמרו בפרויקט. |
| **Workload observation** | נספר מתוך input ה־benchmark הקבוע או מתוך ה־reference model. |
| **RTL fact** | נובע ישירות מן ה־parameters, ה־ports או ה־state שב־RTL הפעיל. |
| **Analytical estimate** | חושב ממודל ארכיטקטורה מפורש ומהנחות שצוינו. |
| **Target** | דרישה שנמסרת לכלי המימוש; טרם הוכח שהמערכת עומדת בה. |
| **Illustrative example** | מדגים נוסחה באמצעות ערכים משוערים; אינו תחזית. |

## מה ממומש ומה אינו ממומש

ממומש ב־SystemVerilog:

- שישה Huffman match banks ניתנים לתכנות, עם 147 entries ומפתח 16 bit בכל bank;
- בחירת ההתאמה בעלת הקוד הקצר ביותר תחילה;
- streaming reservoir מסוג MSB-first ברוחב 32 bit;
- בחירת table מחדש בכל 50 symbols שהתקבלו;
- טיפול ב־registered ready/valid result וב־backpressure;
- זיהוי EOB, בדיקת capacity, terminal errors ו־performance counters;
- בדיקות bounds בעת programming ו־active selector הנשמר ב־register; וכן
- source של unit testbench ושל top-level testbench שהם self-checking.

הדברים הבאים מוגדרים בדוח, אך תלויי platform בכוונה ולכן אינם ממומשים:

- AXI4-Lite או MMIO slave אחר;
- מנועי DMA מסוג memory-to-stream ו־stream-to-memory;
- חיבור ל־interrupt controller;
- Linux kernel driver ו־Python C extension; וכן
- תוצאות synthesis, place-and-route, timing, area ו־power שתלויות ב־device.

מטרת הקורס היא להדגים hardware/software co-design עקבי, ולא לטעון שהמערכת
מוכנה ל־tapeout. ה־RTL מפורט מספיק כדי להציג את החלטות ה־datapath, ה־control,
ה־protocol, השגיאות וה־timing. פרק האינטגרציה מגדיר את ה־platform wrapper החסר
ברמה שמאפשרת לממש אותו בעתיד.

## עדכוני RTL הקשורים ל־timing שנעשו יחד עם הדוח

- `active_table_q` רושם כעת את selector 0 בתחילת job, ואת ה־selector הבא רק
  בגבול של 50 symbols שבו ה־output אכן התקבל. כך selector memory יוצא מה־CAM
  critical path הרגיל, ללא שינוי של initiation interval בן שני clock cycles.
- constraint מסוג `create_clock` עם period של 5.000 ns מתעד כעת את ה־target של
  200 MHz, תוך אזהרה מפורשת ש־constraint אינו הוכחה לעמידה ב־timing.
- ההערות עבור active-low reset דורשות כעת deassertion מסונכרן, כדי למנוע בעיות
  recovery/removal.
- ה־banks שאינם פעילים מתוארים במדויק כ־operand-isolated ולא כ־clock-gated
  פיזית, והטווחים של unpacked table arrays נכתבו במפורש לשיפור הקריאות.

ה־critical paths הסבירים שנותרו הם רשת ההשוואה וה־priority המקוננת, מסלול
ה־consume/refill המשתנה של ה־reservoir, וקריאת ה־selector שמופעלת רק בגבול קבוצה.

מצב האימות נכון ל־2026-09-14: בוצע workload characterization וכל ששת מבחני
ה־Python reference עברו. לא היה זמין HDL compiler/simulator או כלי physical
implementation, ולכן RTL compilation, simulation, synthesis, timing closure,
area ו־power עדיין לא אומתו.

## מסקנה מרכזית

התכנון מחליף כמות משמעותית של comparison logic משוכפל במיפוי פשוט וישיר של
`HuffmanTable.find_next_symbol`. ללא stalls ב־stream, ל־top המלא עם feedback יש
initiation interval של שני clocks לכל symbol. תחת clock **target** של 200 MHz
ועבור ה־workload שנצפה, הכולל 148,271 symbols, זמן ה־core האנליטי הוא בקירוב
1.483 ms. בהתאם לשאלה אם משייכים ל־accelerator רק את ה־self time של פונקציית
Python, או את ה־subtree השימושי שלה הכולל גם את ה־reservoir, תחזיות Amdahl נותנות
speedup כולל של כ־1.135x עד 1.626x לפני integration overhead ממשי. אלו תחזיות
ולא תוצאות שנמדדו ב־hardware.
