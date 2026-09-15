# 7. פשרות בין performance,‏ area,‏ frequency ו-power

[חזרה לאינדקס הדוח](README.md)

## 7.1 מה המשמעות של PPA כאן

Hardware architecture אינה נבחנת לפי performance בלבד:

- **Performance** כולל latency, ‏throughput, ‏stalls ו-speedup מקצה לקצה של
  ה-software.
- **Area** כולל state מאוחסן, לוגיקת lookup/comparison, לוגיקת priority/mux,
  ‏routing, משאבי clock/reset ו-wrapper חיצוני ל-bus/DMA.
- **Power** כולל static/leakage ו-dynamic power הנובעים מ-clocks, ‏logic,
  ‏signals, ‏memories ו-I/O.

היעדים האלה מתנגשים זה בזה. hardware מקבילי יותר יכול להפחית cycles אך צורך
יותר area ו-switched capacitance. יותר pipeline stages יכולים להעלות את
ה-frequency הניתן להשגה, אך להגדיל latency וב-decoder הזה, שתלוי ב-feedback,
גם את ה-initiation interval. ‏clock נמוך יותר מפחית dynamic power רגעי אך
מאריך את הזמן הפעיל.

## 7.2 נקודת התכנון הנוכחית

ה-design החינוכי שנבחר הוא:

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

הסיבות לבחירת נקודה זו:

- היא ממפה באופן ברור וישיר ל-table matcher הפשוט של החבר;
- כל טבלאות bzip2 נמצאות ב-hardware, ולכן המעבר בכל 50 symbols הוא מיידי;
- היא מדגימה בבירור spatial comparison, ‏datapath/control, ‏streaming
  ו-backpressure;
- הרבה יותר קל להסביר אותה מאשר canonical decoder שעבר optimization רב; וכן
- חוסר היעילות שלה מאפשר דיון PPA משמעותי וכן.

היא אינה מוצגת כפתרון production בעל area מינימלי או energy מינימלית.

## 7.3 מודל area

### נוסחת האחסון הכללית

נגדיר:

```text
T = number of tables
E = entries per table
K = lookup/code width [bits]
S = decoded symbol width [bits]
L = stored length-field width [bits]
```

גודל entry ישיר מסוג pattern/mask הוא:

```text
B_entry [bits] = K_pattern + K_mask + S_symbol + L_length + 1_valid
               = 2K + S + L + 1
```

אחסון ה-CAM הוא:

```text
B_CAM [bits] = T * E * (2K + S + L + 1)
```

עבור `T=6`, ‏`E=147`, ‏`K=16`, ‏`S=9`, ‏`L=5`:

```text
B_entry = 2*16 + 9 + 5 + 1 = 47 bits
B_CAM   = 6*147*47 = 41,454 bits
```

ה-state הגולמי הנוסף הוא בקירוב:

```text
selector RAM                 = 2,966*3 = 8,898 bits
six matcher result registers = 6*(1+1+9+5) = 96 bits
reservoir state              = 32+6+3+1+1 = 43 bits
top job/control/counters      approximately 291 bits

B_state,total approximately = 50,782 bits
                              = 6,347.75 byte-equivalents
                              approximately 6.20 KiB bit-packed
```

מספר זה הוא inventory שקוף של state ב-RTL, ולא תוצאת area מ-synthesis.

### מערך ה-comparison

מספר ההזדמנויות הפיזיות ל-masked equality הוא:

```text
N_comparators = T*E = 6*147 = 882

N_bit_compare_lanes = T*E*K
                    = 6*147*16
                    = 14,112 bit lanes
```

רק bank אחד פעיל מבחינת operands בכל lookup, אך כל השישה תופסים area.

הלולאות shortest-first ב-source בודקות עד:

```text
N_priority_predicates,bank = K_lengths * E_entries
                           = 16*147
                           = 2,352

N_priority_predicates,total = 6*2,352 = 14,112
```

ייתכן ש-synthesis יבצע factoring או יסיר תנאים בלתי אפשריים, אך ה-source
המקונן יכול להתמפות לרשת priority/multiplexer עמוקה ורחבה. כנראה שזהו סיכון
PPA גדול יותר מכפי שסך ה-bits המאוחסנים מרמז.

### השלכות המיפוי ל-FPGA

כל entry חייב להיות גלוי במקביל לצורך השוואת CAM. ‏block RAM רגיל בעל port
יחיד או שני ports אינו יכול לחשוף 147 records בבת אחת, ולכן pattern/mask
ו-metadata עשויים להתמפות במידה רבה ל-flip-flops, ‏LUTRAM ולוגיקת LUT. מערך
ה-selector קטן מספיק ל-distributed RAM, אך ה-asynchronous read הנוכחי שלו
עשוי גם להשפיע על ה-inference. ‏selector prefetch סינכרוני יתמפה בצורה טבעית
יותר ל-memory primitive.

יש לדווח area בפועל לפי משאבי ה-device לאחר synthesis ו-placement:

```text
LUTs, flip-flops, distributed RAM, block RAM, DSPs, clock buffers,
and percentage of chosen device
```

לעומת זאת, flow ל-ASIC ידווח cell area, ‏gate equivalents, ‏memory-macro area
ו-routed die/core utilization.

## 7.4 מודל performance

### Throughput

```text
throughput [symbols/s] = f_clk [cycles/s] / II [cycles/symbol]
```

עבור `II=2` הנוכחי ויעד של 200 MHz:

```text
throughput = 200 MHz / 2 = 100 Msymbol/s
```

### Latency של job

```text
C_core = C_fill + N*II + C_bubbles
T_core = C_core / f_achieved
```

עם worst-case fill של `3`, ‏`N=148,271`, ללא bubbles וביעד 200 MHz:

```text
C_core = 3 + 148,271*2 = 296,545 cycles
T_core = 296,545/200,000,000 = 1.482725 ms
```

Latency של symbol יחיד ו-throughput של stream שלם הם שני גדלים שונים. ה-matcher
מכניס תוצאה ל-register לאחר ה-combinational search, אך ה-complete top אינו
יכול להתחיל lookup תלוי חדש עד שה-length הנוכחי מבצע commit.

### Integration

הזמן מקצה לקצה הוא בקירוב:

```text
T_job = T_setup + T_configuration
      + max(T_core, T_source_DMA, T_destination_DMA)
      + T_completion
```

כאשר ההעברות חופפות. אם ה-platform מבצע אותן בסדרה, מחליפים את `max` בסכום
המתאים. זו הסיבה שאסור להציג תוצאת core של 1.483 ms כזמן של כל ה-Python
benchmark.

## 7.5 כיצד timing מחושב בפועל

### ל-RTL עדיין אין delay פיזי

אופרטורים ב-SystemVerilog מגדירים התנהגות Boolean/אריתמטית. ה-delay הפיזי שלהם
מופיע רק לאחר שכלי ממפה אותם ל-device שנבחר ומבצע routing. ‏`timescale 1ns/1ps`
שולט ביחידות ה-delay ב-simulation; הוא אינו קובע את ה-hardware frequency.

ה-XDC constraint:

```tcl
create_clock -name core_clk -period 5.000 [get_ports {clk}]
```

מבקש מהכלים לנסות להגיע ל-200 MHz.

### משוואת setup

עבור path אחד מ-launch-register ל-capture-register:

```text
T_cq,max + T_comb,max + T_route,max + T_setup + T_uncertainty <= T_period
```

Static timing analysis מדווח:

```text
setup slack = required arrival time - actual arrival time
```

- ‏worst negative slack ‏(`WNS < 0`) פירושו שלפחות path אחד נכשל;
- ‏total negative slack ‏(`TNS < 0`) מסכם את ה-slack של כל ה-endpoints שנכשלו;
  וכן
- ‏`WNS >= 0` ו-`TNS=0` הם תנאים הכרחיים לעמידה ב-setup timing עבור אותו
  constraint/corner.

אם ריצה עם 5.0 ns מדווחת `WNS=-1.4 ns` והקשר הפשוט בין required ל-arrival
נשאר ללא שינוי:

```text
critical required duration approximately = 5.0 - (-1.4) = 6.4 ns
Fmax approximately = 1/6.4 ns = 156.25 MHz
```

חישוב ההופכי הזה הוא הערכה. כדי לקבוע Fmax יש להקשיח/להרפות את ה-constraints
ולהריץ implementation מחדש, משום ש-placement וה-optimization של הכלי עשויים
להשתנות בהתאם ליעד.

### משוואת hold

תנאי hold מפושט הוא:

```text
T_cq,min + T_comb,min + T_route,min >= T_hold + T_skew
```

ניתוח hold משתמש ב-minimum-delay corner. האטת ה-clock אינה מתקנת ישירות data
path מהיר מדי עבור אותו edge.

### בדיקות נוספות

דוח timing אמין בודק גם:

- clock uncertainty ו-jitter;
- constraints של input/output delay בגבול ה-core/platform;
- ‏recovery/removal של asynchronous reset deassertion;
- ‏clock-domain crossings אם שעוני DMA/control שונים;
- ‏unconstrained paths ו-endpoints; וכן
- בדיקות minimum pulse-width/device.

אי אפשר להכריז על path גבול ה-selector כ-multicycle path של 50 cycles רק משום
שהוא מתרחש אחת ל-50 symbols: ה-table החדש שנבחר דרוש ל-lookup הבא. ‏timing
exception תחייב schedule מוכח של prefetch, ולא רק activation frequency נמוך.

## 7.6 Critical paths סבירים והפתרונות להם

| Path מועמד | מדוע הוא מסוכן | פתרון ראשון | מחיר הפשרה |
|---|---|---|---|
| Reservoir/active-table register -> bank decode -> 147 masked comparisons -> nested 16x147 priority -> result register | השוואה רחבה מאוד ולוגיקת mux/priority שעלולה להיות עמוקה | Balanced tournament/reduction tree ששומר על ה-priority | RTL/routing מובנים יותר; ניתן לשמור על אותו II נומינלי |
| Matcher result -> count subtract -> 32-bit variable shift -> count-dependent byte append/OR -> reservoir register | ‏Barrel shifts ובחירה בו-זמנית של consume/refill | לפצל/לארגן מחדש את append path, לבצע precompute לבחירות shift או להוסיף pipeline | ה-pipeline עלול להגדיל feedback II |
| Selector index -> increment -> async selector read -> range check -> active-table register | ‏Memory/mux יחד עם compare ב-boundary cycle יחיד | לבצע prefetch ל-selector הבא או להוסיף synchronous RAM stage | מעט state/control נוספים |
| Config code/length -> variable alignment shifts -> table state | ‏Variable shifts בזמן write | לבצע pre-alignment ב-loader/software או להכניס register ל-config path | שינוי programming format או תוספת config latency בלבד |

הוספת `active_table_q` כ-register כבר הוציאה את selector memory מכל lookup רגיל.
הדבר משפר timing בעלות state זניחה וללא steady-state bubble נוסף.

## 7.7 פשרת pipelining הייחודית ל-design הזה

ב-feed-forward pipeline עם inputs בלתי תלויים, הוספת stage עשויה להגדיל latency
בלי להפחית throughput. ההנחה הזו אינה בהכרח נכונה כאן:

```text
current match length -> reservoir consume -> next lookup window
```

אם register מוכנס בין raw matches לבין priority resolution בלי להוסיף
speculation/bypass:

```text
II_current = 2 cycles/symbol
II_pipelined approximately = 3 cycles/symbol
```

ב-200 MHz:

```text
T_II2 = (3 + 148,271*2)/200 MHz = 1.482725 ms
T_II3 = (3 + 148,271*3)/200 MHz = 2.224080 ms
```

ה-pipeline עדיין כדאי אם הוא מעלה את ה-frequency במידה מספקת. נקודת ה-break-even
בין שני ה-designs היא:

```text
N*II_old / f_old approximately = N*II_new / f_new

f_new/f_old approximately = II_new/II_old = 3/2 = 1.5
```

לכן שינוי II מ-2 ל-3 דורש עלייה של כ-50% ב-clock frequency רק כדי לשחזר את
אותו throughput ב-stream ארוך. משום כך, רשת priority מאוזנת ב-stage יחיד היא
תיקון ה-timing הראשון המועדף.

## 7.8 מודל power ו-energy

אפשר להפריד את ה-power הכולל של ה-device כך:

```text
P_total = P_static + P_clock + P_logic + P_signal
        + P_memory + P_IO + P_DMA
```

קירוב מסדר ראשון ל-dynamic power של logic/signals הוא:

```text
P_dynamic approximately = sum(alpha * C_eff * V^2 * f)
```

השפעות ה-design הנוכחי:

- שישה banks מגדילים את `C_eff` בשל יותר logic ו-routing;
- רק bank אחד מקבל lookup data/valid משתנים, ולכן `alpha` קטן יותר בחמשת
  ה-banks האחרים;
- זהו operand isolation, **לא clock gating**;
- ה-bank result registers ורשתות ה-clock עדיין מבצעים toggle/צורכים clock power;
- מערכי ה-selector וה-table תורמים leakage/static power גם כאשר אינם פעילים;
- ‏DMA I/O רחב/תכוף עשוי לצרוך power של platform בכמות דומה או גדולה מזו של
  ה-core הקטן; וכן
- זמן ביצוע קצר יותר יכול להפחית leakage energy גם אם ה-dynamic power הרגעי
  גבוה יותר.

Energy:

```text
E_job = integral(P(t) dt) approximately P_average*T_job
```

דוגמה המחשתית בלבד:

```text
if P_average = 0.40 W and T_job = 1.482725 ms,
E_job = 0.40*0.001482725 = 0.00059309 J = 0.593 mJ
```

לא נבחרו target part, ‏voltage, ‏placed route או activity trace, ולכן עדיין
אין לפרויקט ערך absolute צפוי של Watt שאפשר להגן עליו. יש לדווח `0.40 W` רק
כהנחת דוגמה, ולעולם לא כ-device power שנמדד או הוערך.

## 7.9 השוואת architectures

| Architecture | Cycles/symbol | Area של comparator/storage | התנהגות בהחלפת table | סיכון timing | נטיית dynamic power | התאמה |
|---|---:|---|---|---|---|---|
| שישה banks מקביליים של direct CAM (נוכחי) | 2 ב-complete top | הגבוה ביותר | החלפה מיידית דרך register | Flat priority מסוכן | Capacitance הגבוה ביותר; operand isolation עוזר ל-activity | הבהירות/שלמות הטובה ביותר להדגמה |
| שישה CAM banks עם balanced reduction | אפשרי 2 | State דומה; logic מאורגן מחדש | מיידית | Logic depth טוב יותר | Glitch power דומה או מעט נמוך יותר | refinement מומלץ ל-timing |
| Direct CAM bank יחיד שנטען מחדש | 2 לאחר טעינה, בתוספת reloads | בערך 1/6 ממערך ה-compare/storage | Reload בעת שינוי קבוצה או cache של tables במקום אחר | עומס CAM mux נמוך יותר | Core power נמוך יותר, activity גבוהה ב-transfer/control | לא מתאים כאשר selector משתנה בכל 50 symbols |
| Multi-cycle sequential RAM search | רבים | Logic מינימלי; מתאים ל-BRAM | קל | Frequency קל | Power רגעי נמוך, זמן פעיל ארוך יותר | מאבד את תועלת ההאצה |
| Canonical range decoder | ייתכן 1–2 | נמוך בהרבה מ-882 השוואות CAM | אחסון ranges קומפקטיים עבור tables | בדרך כלל טוב יותר | בדרך כלל נמוך יותר | בחירת production חזקה; שונה מה-design הפשוט |
| Full bzip2 accelerator | יכול להסיר הרבה יותר software | System/state גדולים בהרבה | פנימית | סיכון verification גדול בהרבה | גדול יותר | מחוץ ל-scope של ה-component שנבחר |

## 7.10 כוונוני design ממוקדים

### מספר ה-banks הפיזיים

שינוי מספר הטבלאות `T` משנה באופן לינארי את אחסון ה-CAM ואת מספר ההשוואות:

```text
B_CAM proportional to T
N_comparators proportional to T
```

הפחתה משישה ל-bank אחד חוסכת בערך 5/6 ממערך ה-CAM, אך אז מעברי selector
דורשים table reload או architecture נפרדת של table-memory/cache. כאשר מתרחש
שינוי בכל 50 symbols, ‏reload latency חוזר יכול לשלוט בזמן.

### Key width

הגדלת `KEY_WIDTH` מ-16 ל-20 תגדיל את אחסון ה-pattern+mask ב:

```text
Delta B_CAM = 6*147*2*(20-16)
            = 7,056 bits
```

היא גם מרחיבה בארבעה bits את כל 882 ההשוואות ומגדילה את מחלקות אורכי ה-priority
מ-16 ל-20. ‏16 bits מוצדקים רק משום שאפיון ה-workload מוכיח שהם מספיקים;
accelerator כללי ל-bzip2 זקוק ל-20.

### Reservoir width

Reservoir ברוחב 32 bit מספק מקום ל-window של 16 bit ול-byte refill. ‏buffer
קטן יותר של 24 bit חוסך שמונה data bits ומעט מרוחב ה-shifter, אך מפחית את
מרווח התזמון. ‏buffer רחב יותר של 64 bit יכול להתיישר באופן טבעי ל-DMA data
רחב יותר, אך יוצר variable shifter גדול יותר ואולי power גבוה יותר. בדרך כלל
נקי יותר להציב reservoir צר נפרד מאחורי FIFO של bytes/words.

### Stream width

Input של 8 bit ל-core הוא פשוט וכבר זקוק בממוצע רק לכ-45.57 MB/s עבור upper
bound של כל הקובץ לאורך interval ה-core האנליטי. הרחבת ה-core ל-32/64/128 bits
לא תשפר את מגבלת ההתאמה II=2, אך תגדיל את לוגיקת ה-append. חלוקה שבה DMA רחב
מזין byte FIFO היא integration טובה יותר.

ה-output תובעני יותר: ב-100 Msymbol/s עם slots של 16 bit ב-memory, הוא יכול
להתקרב ל-200 MB/s. ‏FIFO ו-wide writes ארוזים מונעים מתנודות בתגובת ה-memory
לעצור את ה-core.

### Counters ולוגיקת error

ה-cycle counter ברוחב 64 bit ושלושת ה-counters ברוחב 32 bit צורכים state מתון
ו-adder activity. הסרתם חוסכת מעט ביחס ללוגיקת ה-CAM ומקשה לאמת טענות
performance/debug. זו פשרת חינוך ו-observability חיובית.

### Configuration caching

שמירת תמונת table/selector בגודל 6,494 בתים ב-cache חוסכת load/setup energy
ו-latency חוזרים עבור jobs זהים, אך דורשת configuration identity/version וכללי
stale-state זהירים. ה-baseline הפשוט והבטוח כותב מחדש את כל 6x147 ה-entries
(אורכים אפסיים מבטלים codes שאינם קיימים) ואת ה-selector prefix שבשימוש.

## 7.11 סדר ה-optimization עבור timing/area/power

אם עבודת ה-implementation תימשך, יש להשתמש בראיות מהדוחות במקום לבצע
optimization באופן עיוור:

1. לבצע synthesis ו-place ל-design הנוכחי ללא שינוי עבור device מוגדר עם
   constraint של 5.000 ns.
2. לוודא שלכל ה-paths יש constraints ולבדוק WNS/TNS ואת ה-critical path האמיתי
   של ה-top.
3. אם ה-timing בגבול ה-selector נכשל, לבצע prefetch ל-selector הבא.
4. אם ה-priority timing נכשל, להחליף את הבחירה המקוננת ב-balanced reduction
   שנבדק לשקילות, תוך שמירה על ה-interface החיצוני.
5. להריץ מחדש functional simulation ולהשוות התנהגות cycles/MD5.
6. להריץ מחדש place-and-route; לתעד LUT/FF/RAM ואת ה-timing שהושג.
7. ליצור VCD/SAIF מתנועת benchmark מייצגת ולהריץ power analysis.
8. רק אם המימוש המאוזן עדיין נכשל, לבחון pipeline stage ולכלול את ה-II החדש
   שלו במודל ה-performance.
9. אם area/power עדיין מוגזמים, להשוות את canonical-range architecture
   באמצעות אותם vectors ואותו גבול מדידה.

## 7.12 הנתונים הנדרשים לטבלת PPA אמיתית

לאחר שייבחרו target וכלים, יש להחליף את ה-placeholders האנליטיים ב:

| פריט | הראיה הנדרשת |
|---|---|
| Target | ‏FPGA part/speed grade מדויק או ASIC library/corner |
| Constraint | ‏Clock period, ‏uncertainty, ‏I/O delays ו-CDC/reset exceptions |
| Timing | ‏Post-route WNS/TNS, ‏frequency שנבדק והושג, נקודות start/end ומספר logic levels של ה-critical path |
| Area | ‏LUT, ‏FF, ‏LUTRAM, ‏BRAM, ‏DSP, ‏routing/utilization; או cell area/gate equivalents |
| Power | פירוט static ו-dynamic, ‏voltage, ‏temperature, מקור activity ו-toggle coverage |
| Performance | ‏Cycles, ‏stalls, ‏symbols, ‏bits, ‏host wall time וזמן DMA שנמדדו |
| Energy | ‏average watts שנמדד/הוערך כפול זמן job שנמדד |
| Correctness | מספר test vectors, ‏assertions, ‏final bytes/MD5 וכיסוי מקרי error |

## 7.13 מסקנת הפשרות

לפרויקט זה, CAM בעל שישה banks וברוחב 16 bit הוא בחירה שאפשר להצדיק, משום
שהמטרה היא להדגים קונספט מלא של hardware/software acceleration ולא לספק את
ה-bzip2 decoder הקטן ביותר ל-production. הוא מציע מיפוי ישיר וברור, החלפות
selector מיידיות, counters שימושיים ו-core speedup אנליטי חזק.

המחיר הוא area גבוה עקב replication של comparison/priority ו-timing לא ודאי
ב-200 MHz. לכן הדוח צריך להציג נכון את 200 MHz ואת 0.40 W:

- **200 MHz הוא יעד constraint שממתין ל-post-route timing**, וכן
- **0.40 W היא הנחה לצורך דוגמת חישוב energy, עד לבחירת device בשם ולהרצת
  power analysis המבוססת על activity**.

אם מבצעים רק refinement אחד לפני synthesis, יש לארגן את בחירת ה-shortest-match
כ-balanced reduction. שינוי זה מטפל ב-critical path הסביר ביותר בלי להגדיל
אוטומטית את ה-initiation interval של ה-feedback.
