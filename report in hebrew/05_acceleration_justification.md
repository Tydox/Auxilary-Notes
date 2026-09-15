# 5. הצדקת ההאצה והערכת ביצועים

[חזרה לאינדקס הדוח](README.md)

## 5.1 מדוע `HuffmanTable.find_next_symbol` הוא מועמד טוב

הפונקציה מתאימה ל-hardware acceleration מחמש סיבות בלתי תלויות.

### היא חמה וחוזרת פעמים רבות

ה-block שנמדד מבצע 148,271 פעולות Huffman lookup, כולל EOB. ה-sampling של
הריצה המקורית המלאה מייחס בקירוב:

- **12.11% / 80.21 ms** לעבודה של פונקציית ה-Python עצמה; וכן
- **38.71% / 256.34 ms** לפונקציה יחד עם עבודת ה-bit-reader המקוננת בתוכה.

ערך ה-self מתאים באופן הישיר ביותר למנוע התאמת טבלה. ערך ה-inclusive מתאים
לגבול המוצע בפועל — matcher יחד עם bit reservoir ב-hardware.

### ה-state והגבולות שלה קטנים וצפויים

ה-workload הנבחר זקוק לשש טבלאות, 147 entries בכל table, אורכי code שאינם
גדולים מ-16, ו-selector אחד לכל 50 symbols גולמיים. גבולות קבועים מתאימים היטב
ל-arrays סטטיים ב-hardware, לאריתמטיקה ברוחב קבוע ול-control דטרמיניסטי.

### היא מכילה עבודה מקבילית ברמת גרעיניות עדינה

Python בודק אורכים/entries מועמדים באופן סדרתי ומבצע עבודת objects,
function calls, masking ו-loop control. מעגל בסגנון CAM משווה בו-זמנית 147
entries ב-bank שנבחר, ולאחר מכן מבצע reduction לתוצאות ההתאמה.

### היא מתאימה באופן טבעי ל-streaming

הבתים הדחוסים נכנסים לפי הסדר; ה-symbols המפוענחים יוצאים לפי הסדר. מלבד
ה-feedback של אורך ההתאמה, אין צורך בגישה גלובלית אקראית ל-memory. reservoir
עם ready/valid מאפשר חפיפה בין DMA לבין lookup.

### אפשר לעבד אותה ב-batch

job יחיד מכסה Huffman block שלם במקום symbol יחיד. כך ה-overhead של Python/C,
driver, MMIO, interrupt והגדרת DMA מתחלק על פני 148,271 תוצאות.

## 5.2 מדוע ה-software optimization שימושי אך אינו hardware

מימוש ה-Python ה-optimized בונה מראש dictionaries שמאונדקסים לפי
`(length, code)` וסורק רק את אורכי ה-code הייחודיים. זהו שיפור אלגוריתמי טוב
ומימוש golden/reference מצוין. הוא הפחית את ה-mean ההשוואתי האחרון מ-662.237
ms ל-430.018 ms, כלומר speedup של 1.540x.

עם זאת, הוא עדיין software משום שהוא:

- מריץ Python bytecode ופעולות object/dictionary;
- מעבד symbol אחר symbol על ה-CPU;
- משתמש ב-registers וב-caches של ה-CPU במקום במערך comparators ייעודי;
- אינו כולל streaming protocol קבוע, reservoir ב-hardware, DMA, MMIO או driver;
- אינו יכול להשוות entries רבים במרחב באותו clock edge; וכן
- ממשיך לשלם על Python lookup call אחד לכל אחד מ-148,271 ה-symbols.

ה-code ה-optimized נותן שני רעיונות שימושיים ל-hardware: לבצע precompute של
representation לפני ה-hot loop, ולהקטין בדיקות מיותרות של אורכי מועמדים. הוא
אינו מחליף את הצורך לתכנן datapath, state, handshakes, בעלות על bits, החלפת
tables ואת גבול ה-integration.

## 5.3 מקורות המדידה והשיטה

### זמן קיר של ה-baseline

ה-baseline העיקרי הוא הריצה המקורית הרגילה הכוללת 60 ערכים:

- [`results/pyflate/original/original results full run/timing.json`](../../../results/pyflate/original/original%20results%20full%20run/timing.json)
- [`run_metadata.txt`](../../../results/pyflate/original/original%20results%20full%20run/run_metadata.txt)

עבור הערכים הנמדדים `t_k` בשניות:

```text
mean [s] = (1/n) * sum(k=1..n, t_k)
mean [ms] = 1000 ms/s * mean [s]
```

60 הערכים הנמדדים נותנים:

| מדד סטטיסטי | הריצה המקורית המלאה |
|---|---:|
| מספר ערכים | 60 values |
| mean אריתמטי | 662.236860 ms |
| median | 659.091945 ms |
| minimum | 652.654428 ms |
| maximum | 736.232706 ms |
| sample standard deviation | 11.667433 ms |

ה-warmups אינם נכללים ב-60 הערכים המדווחים האלה.

מוני ה-workload המדויקים הופקו מחדש באמצעות
[`tools/characterize_workload.py`](../tools/characterize_workload.py): שש טבלאות,
alphabet/table עם לכל היותר 147 entries, אורכי code בטווח 2–15, 2,966
selectors עם ID מרבי 5, 148,271 lookup calls כולל EOB, ‏67,562 בתים במקור
ו-399,360 בתים ב-output הסופי לאחר decompression. הכלי הורחב כדי לדווח את שדות
ה-capacity הנדרשים ל-hardware והורץ בהצלחה ב-2026-09-14. מספרי ה-lookup וה-output
נבדקים גם באמצעות assertions ב-[`tests/test_huffman_reference.py`](../tests/test_huffman_reference.py),
וכל שש הבדיקות שלו עברו תחת ה-Python runtime המצורף. מכיוון ש-EOB מסיים את
התהליך ואינו מתקדם לקבוצה נוספת, דרישת ה-selectors תואמת ל:

```text
N_non_EOB = 148,271 - 1 = 148,270 symbols
N_selectors = floor(N_non_EOB / 50 symbols/selector) + 1 EOB group
            = floor(148,270 / 50) + 1
            = 2,966 selectors

equivalently for this stream:
N_selectors = ceil(148,271 total symbols / 50) = 2,966
```

### יחסי ה-profile

יחסי הפונקציה נלקחו מ-folded-stack profile הסמוך:

- [`speedscope.folded`](../../../results/pyflate/original/original%20results%20full%20run/speedscope.folded)
- [`perf_report.txt`](../../../results/pyflate/original/original%20results%20full%20run/perf_report.txt)

ה-stacks סוננו ל-samples המכילים את frame ה-benchmark, וכך התקבל denominator
של 38,010 weighted samples. ה-metadata מתעד profile מסוג `cpu-clock` ב-frequency של 199
Hz עם call graphs המבוססים על frame pointer; הדוח מתעד בערך 41K samples ואפס
samples שאבדו בהקלטה הרחבה יותר.

עבור פונקציה בעלת מספר self-samples ‏`s_i`:

```text
p_i [%] = 100 * s_i / 38,010

estimated self time_i [ms]
    = baseline mean [ms] * s_i / 38,010
```

החישוב ממיר יחס samples לזמן מוערך מתוך ה-mean שנמדד בנפרד. אין זו מדידת
stopwatch ישירה לכל פונקציה.

## 5.4 טבלת צווארי הבקבוק ב-code המקורי

הטבלה להלן היא חלוקת **self-time**: כל sample מסונן משויך ל-Python frame
העמוק ביותר, ולכן אפשר לסכום את השורות והן מסתכמות ל-100%. השורה "אחר"
מאחדת את יתר ה-frames הקטנים.

| פונקציה/Python frame העמוק ביותר | Self samples | חלק מהסך הכול | זמן מוערך |
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
| אחר | 216 | 0.568% | 3.76 ms |
| **סך הכול** | **38,010** | **100.000%** | **662.24 ms** |

דוגמת חישוב עבור `find_next_symbol`:

```text
p_self = 100 * 4,604 samples / 38,010 samples
       = 12.1126%

T_self = 662.236860 ms * 4,604 / 38,010
       = 80.2141 ms
```

ה-self frame הגדול ביותר הוא לוגיקת ה-decode שמסביב, אך האצה של כולה תחייב
מנוע bzip2 רחב בהרבה. `find_next_symbol` מציע שילוב חזק של זמן משמעותי,
148,271 חזרות, state חסום ו-stream interface נקי.

## 5.5 פירוט ה-subtree של `find_next_symbol`

Inclusive profiling סופר parent בכל פעם שהוא מופיע במקום כלשהו ב-stack.
שורות inclusive חופפות ואסור **לחבר** אותן בטבלת כלל הפונקציות. עם זאת, בתוך
ה-subtree של `find_next_symbol`, הרכיבים ה-exclusive להלן מחלקים את 14,713
ה-samples שלו:

| העבודה בתוך lookup subtree | Samples | זמן מוערך |
|---|---:|---:|
| עבודת matcher/loop של `find_next_symbol` עצמו | 4,604 | 80.21 ms |
| `snoopbits` | 2,874 | 50.07 ms |
| `readbits` | 2,860 | 49.83 ms |
| `_mask` | 2,127 | 37.06 ms |
| `_read` | 956 | 16.66 ms |
| `_more` | 830 | 14.46 ms |
| `needbits` | 462 | 8.05 ms |
| **lookup subtree כולל** | **14,713** | **256.34 ms** |

יחס ה-inclusive:

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

הפירוט מצדיק את wrapper ה-bit-reservoir: comparator לבדו מחליף בעיקר 80.21
ms של עבודה עצמית, בעוד reservoir-plus-matcher עם batched interface יכול להחליף חלק
גדול מה-subtree שאורכו 256.34 ms.

## 5.6 ניתוח כל קבוצות תוצאות ה-timing/profile שב-repository

הטבלה הבאה מסכמת את כל תיקיות תוצאות ה-timing של המימוש המקורי וה-optimized.
ריצות בעלות ערך יחיד מועילות כ-smoke tests, אך רועשות מדי לשמש mean עיקרי.

| מימוש/קבוצת תוצאות | ערכים שנמדדו | Mean | Profile samples מסוננים | self של `find_next_symbol` | Inclusive subtree | שימוש בדוח |
|---|---:|---:|---:|---:|---:|---|
| [Original root/debug](../../../results/pyflate/original/timing.json) | 1 | 695.254 ms | 452 | 14.381% | 38.053% | לצורך diagnostic בלבד |
| [Original full regular](../../../results/pyflate/original/original%20results%20full%20run/timing.json) | 60 | 662.237 ms | 38,010 | 12.113% | 38.708% | ה-baseline המקורי העיקרי |
| [Optimized 13-09](../../../results/pyflate/optimized/2026-09-12-13-09/timing.json) | 20 | 436.035 ms | 9,664 | 15.004% | 40.284% | ריצת optimized מוקדמת יותר |
| [Optimized 14-09](../../../results/pyflate/optimized/2026-09-12-14-09/timing.json) | 60 | 431.718 ms | 24,650 | 15.290% | 40.775% | אישור בריצה רגילה |
| [Optimized 15-04](../../../results/pyflate/optimized/2026-09-12-15-04/timing.json) | 1 | 430.226 ms | 289 | 14.533% | 41.176% | לצורך diagnostic בלבד |
| [Optimized 15-16](../../../results/pyflate/optimized/2026-09-12-15-16/timing.json) | 60 | 430.018 ms | 24,788 | 15.261% | 41.137% | ה-baseline ה-optimized האחרון |

הנתיב `optimized/latest` שב-repository מצביע על `2026-09-12-15-16`. הקובץ
הישן יותר `2026-09-12-13-09/comparison.txt` משתמש בערכים מעוגלים/מיושנים ואינו
המקור לחישובים כאן.

ה-lookup ה-optimized צורך אחוז גדול יותר לאחר שחלקי code אחרים נעשים מהירים
יותר, אך זמניו המוחלטים המוערכים יורדים בקירוב ל:

```text
optimized self time      = 65.627 ms
optimized inclusive time = 176.896 ms
```

הדבר עקבי עם software optimization יעיל, ואינו ראיה לכך שה-lookup שנותר חדל
להיות חשוב.

### תפקידם של קובצי התוצאות האחרים

כל תיקיית תוצאות מכילה כמה מבטים על אותה ריצה. אין להתייחס אליהם כניסויי
timing עצמאיים:

| Artifact | מה הוא מספק | כיצד הוא משמש כאן |
|---|---|---|
| `timing.json` | ערכים שנמדדו באמצעות pyperformance ו-environment metadata | סטטיסטיקת wall-time עיקרית |
| `speedscope.folded` | call stacks שנדגמו עם משקלים | חישוב מחדש של יחסי self/inclusive ב-Python |
| `flamegraph.svg` | הצגה חזותית של ה-folded samples | בדיקה אנושית; אינו נסכם בנפרד |
| `perf_report.txt` | call graph, סך event/sample ומצב samples שאבדו | מאשר את איסוף ה-profile ואפס samples שאבדו |
| `perf_stat.txt` | CPU counters על כל הרצת pyperformance | תומך רק במגמות העבודה original/optimized |
| `run_metadata.txt` | מקור ה-interpreter, event, frequency, platform וה-command | מתעד sampling ב-199 Hz ואת ההבדל בין debug לבין regular interpreter |
| `perf_events.txt` | מידע על events זמינים/מבוקשים | מסביר אילו counters היו ניתנים לאיסוף |
| `perf_probe.log` ו-`perf_record.log` | diagnostics של האיסוף | נבדקו warnings; ‏kernel relocation/BPF warnings מגבילים attribution ל-kernel |
| `comparison.txt` | output נוח בתיקיית optimized מוקדמת אחת | לא בשימוש, כי ה-baseline המעוגל שלו מיושן ביחס ל-JSON שב-repository |
| `latest` | מצביע לתיקיית ה-optimized האחרונה | מתורגם ל-`2026-09-12-15-16` |

ה-warnings של `perf_record` אינם פוסלים את ספירת ה-Python stacks המסוננים, אך
הם סיבה נוספת שלא להסיק מקבצים אלה מסקנות על hotspots ברמת ה-kernel.

## 5.7 שיפור ה-software ה-optimized

בהשוואת שתי הריצות הכוללות 60 ערכים:

```text
S_software = T_original / T_optimized
           = 662.236860 ms / 430.018329 ms
           = 1.54002x

time reduction [%]
    = (1 - T_optimized/T_original) * 100
    = (1 - 430.018329/662.236860) * 100
    = 35.066%
```

התפלגות הריצה ה-optimized האחרונה היא:

| מדד סטטיסטי | Optimized 15-16 |
|---|---:|
| מספר ערכים | 60 values |
| mean אריתמטי | 430.018329 ms |
| median | 428.316756 ms |
| minimum | 425.535526 ms |
| maximum | 518.911097 ms |
| sample standard deviation | 11.809953 ms |

## 5.8 מגמות תומכות של hardware counters

קובצי `perf_stat.txt` מהריצות הרגילות המלאות מראים כי Python ה-optimized מבצע
פחות עבודת CPU באופן משמעותי:

- [original perf stat](../../../results/pyflate/original/original%20results%20full%20run/perf_stat.txt)
- [optimized perf stat](../../../results/pyflate/optimized/2026-09-12-15-16/perf_stat.txt)

| Counter על פני כל הרצת pyperformance | Original | Optimized | שינוי |
|---|---:|---:|---:|
| Cycles | 143.192 billion | 96.466 billion | -32.63% |
| Instructions | 382.299 billion | 248.717 billion | -34.94% |
| Branch instructions | 63.898 billion | 36.850 billion | -42.33% |
| Branch misses | 331.517 million | 189.527 million | -42.83% |
| Cache references | 451.591 million | 315.042 million | -30.24% |
| Cache misses | 38.158 million | 10.704 million | -71.95% |
| L1 data loads | 83.038 billion | 54.141 billion | -34.80% |
| L1 data load misses | 1.754 billion | 0.568 billion | -67.59% |
| IPC | 2.67 | 2.58 | מעט נמוך יותר |
| שיעור Branch miss | 0.52% | 0.51% | כמעט ללא שינוי |

השיפור נובע בעיקר מהרצת פחות instructions/branches ופעולות memory, ולא מ-IPC
גבוה יותר. שיעורי ה-branch-miss וה-L1-miss הנמוכים אינם מצדיקים לתאר את
ה-workload המקורי כ-"DRAM bound". ההצדקה ל-hardware נובעת במקום זאת מהסרת
עבודת Python/object/control חוזרת ומביצוע מקבילי במרחב של השוואות חסומות.

סכומים אלה כוללים startup של ה-process, ‏warmups וערכי benchmark רבים; הם
אינם counters של job יחיד באורך 662 ms. hardware counters רבים עברו
multiplexing עם event coverage של כ-20–31%, ולכן הם תומכים במגמות ולא במודל
microarchitectural מדויק לכל iteration.

## 5.9 זמן accelerator אנליטי

### מספר cycles ב-core

עבור reservoir window ברוחב 16 bit ו-offset התחלתי 0–7:

```text
C_fill = ceil((16 + start_bit) / 8) = 2 or 3 cycles
```

בהנחת ה-fill הגרוע ביותר, `N=148,271` ו-`II=2` ב-complete top:

```text
C_core = C_fill + N*II
       = 3 + 148,271*2
       = 296,545 cycles
```

ב-target frequency של 200 MHz, שטרם אומת:

```text
T_core = C_core / f_clk
       = 296,545 cycles / 200,000,000 cycles/s
       = 0.001482725 s
       = 1.482725 ms
```

ערך זה תואם לכמעט 100 מיליון symbols/s ב-steady state לטווח ארוך.

### בדיקת העברות מקור/configuration

גודל הקובץ הדחוס המלא הוא 67,562 בתים. זהו upper bound לאזור המקור של
ה-accelerator, משום שה-software צורך headers לפני נקודת ההתחלה של ה-hardware.

בהעברה של בית אחד בכל cycle ב-200 MHz:

```text
T_input,upper = 67,562 bytes / 200,000,000 bytes/s
              = 0.00033781 s
              = 337.81 us
```

העברה זו יכולה לחפוף ל-decode והיא קצרה מ-1.483 ms.

עם loader פשוט שמבצע serialization לתכנות ה-dictionary וה-selector, זרם
ה-configuration מבצע:

```text
C_config = 6*147 table writes + 2,966 selector writes
         = 3,848 cycles

T_config,internal = 3,848 / 200,000,000
                  = 19.24 us
```

ערך זה אינו כולל setup של CPU/MMIO/DMA. גודל תמונות ה-table/selector הוא
6,494 בתים וניתן לשמור אותן ב-cache עבור blocks זהים שחוזרים.

ל-core יש בפועל ports עצמאיים ל-dictionary-write ול-selector-write, ולכן
loader בעל dual issue יכול להפעיל אחד מכל סוג באותו clock כאשר ה-core idle:

```text
C_config,dual = max(6*147, 2,966)
              = 2,966 cycles

T_config,dual = 2,966 / 200,000,000
              = 14.83 us
```

לכן 19.24 us היא הנחה שמרנית עבור loader יחיד; 14.83 us היא ה-lower bound
הפנימי עבור dual-port לפני השפעות setup/transfer חיצוניות.

## 5.10 Component speedup

### תחום self-only שמרני

```text
S_component,self = software self time / hardware core time
                 = 80.2141 ms / 1.482725 ms
                 = 54.10x
```

חישוב זה מזכה במכוון את ה-accelerator רק על העבודה שנדגמה בתוך הפונקציה עצמה,
אף שה-reservoir הממומש מחליף גם עבודת child functions.

### תחום inclusive אופטימי

```text
S_component,inclusive = software inclusive time / hardware core time
                      = 256.3402 ms / 1.482725 ms
                      = 172.88x
```

זהו חישוב אופטימי משום שהוא מניח שה-API ה-batched מסיר כמעט את כל lookup/bit-reader
subtree שנדגם ושאין overhead נוסף ל-integration.

## 5.11 Speedup של התוכנית כולה באמצעות חוק Amdahl

עבור החלק המואץ `p` ו-component speedup ‏`S_c`:

```text
S_total = 1 / ((1-p) + p/S_c)
```

### תוצאה שמרנית

```text
p_self = 0.121126

S_total,self = 1 / ((1-0.121126) + 0.121126/54.10)
             = 1.13493x

S_max,self = 1 / (1-p_self)
           = 1.13782x
```

### תוצאה אופטימית הכוללת את ה-reservoir

```text
p_inclusive = 0.387082

S_total,inclusive
    = 1 / ((1-0.387082) + 0.387082/172.88)
    = 1.62560x

S_max,inclusive = 1 / (1-p_inclusive)
                = 1.63154x
```

הפער הקטן בין כל תוצאה חזויה לבין הגבול שלה עבור component מושלם מדגים נקודה
חשובה: לאחר ש-section חם נעשה מהיר מאוד, ה-software שאינו מואץ שולט בזמן.

## 5.12 נוסחת time-accounting שקולה

נוסחה ישירה מציגה במפורש את ה-integration overhead:

```text
T_new = T_base - T_removed + T_core + H_integration
```

כאשר `H_integration` כולל overhead נוסף של packing, שליחת job ל-driver, ‏DMA
setup, ‏cache maintenance, ‏completion וכל overhead של returned-buffer שאינו
כבר קיים ב-baseline.

עבור `H_integration=0`:

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

ה-software ה-optimized האחרון אורך 430.0183 ms. כדי שהתחזית ל-hardware על
בסיס original-inclusive תגבר עליו:

```text
H_integration < 430.0183 - 407.3794
              < 22.6389 ms/job
```

תחזית ה-self-only השמרנית אינה יכולה לגבור על suite ה-optimized הנוכחי, וזה
מחזק את הסיבה לכך שה-reservoir ו-job יחיד ב-batch הם חיוניים.

כבדיקת sensitivity משנית באותה ריצה, יישום אותו מודל core של 1.482725 ms על
ה-profile ה-optimized האחרון נותן בקירוב:

| תחום optimized שמקבל זיכוי | סך זמן חזוי ללא overhead | Speedup לעומת 430.018 ms |
|---|---:|---:|
| Self, 65.627 ms | 365.874 ms | 1.175x |
| Inclusive, 176.896 ms | 254.605 ms | 1.689x |

אלה עדיין תחזיות ואין לערבב אותן עם תוצאה עתידית שתימדד על מימוש אמיתי.

## 5.13 רגישות ל-frequency ול-initiation interval

עבור מודל קבוע של 296,545 cycles עם II=2:

| Frequency שהושג | Period | זמן Core |
|---:|---:|---:|
| 100 MHz | 10.0 ns | 2.96545 ms |
| 156.25 MHz | 6.4 ns | 1.897888 ms |
| **יעד 200 MHz** | **5.0 ns** | **1.482725 ms** |
| 250 MHz | 4.0 ns | 1.186180 ms |

השורה 156.25 MHz תואמת לדוגמה ההמחשתית של critical path באורך 6.4 ns; זו
אינה תוצאה שהושגה.

ב-200 MHz קבועים:

| Architecture | II | מודל cycles | זמן Core |
|---|---:|---:|---:|
| Ideal עם speculation/bypass | 1 | `3 + 148271*1 = 148274` | 0.741370 ms |
| **ה-complete top הנוכחי** | **2** | **`3 + 148271*2 = 296545`** | **1.482725 ms** |
| Matcher stage נוסף ללא speculation | בערך 3 | `3 + 148271*3 = 444816` | 2.224080 ms |

טבלה זו מונעת טעות נפוצה: הוספת pipeline register ל-matcher אינה בהכרח שומרת
על throughput של ה-decoder השלם, משום שכל window הבא תלוי באורך שהוחזר לפניו.

## 5.14 נוסחת ביצועים מקצה לקצה ב-streaming

עבור memory bandwidth אפקטיבי `B_eff`:

```text
T_read  = input bytes / B_eff,read
T_write = output bytes / B_eff,write
```

עם מנועי source/output עצמאיים שחופפים זה לזה:

```text
T_job approximately = T_setup + T_config
                    + max(T_core, T_read, T_write)
                    + T_completion
```

כאשר ההעברות מתבצעות בסדרה:

```text
T_job approximately = T_setup + T_config + T_read
                    + T_core + T_write + T_completion
```

ההתנהגות האמיתית נמצאת בין המודלים ויש למדוד אותה. `cycle_count` נותן את מספר
ה-cycles שבהם ה-accelerator פעיל; host wall time נותן את התוצאה שהמשתמש רואה.

עבור ה-core עצמו, מודל cycles מלא יותר הוא:

```text
C_observed = C_fill + N*II + C_bubbles
```

`C_bubbles` הוא איחוד ההזדמנויות שאבדו עקב input starvation, ‏backpressure
והתנהגות ה-wrapper. שני מוני ה-stall החשופים עשויים לחפוף לעבודה אחרת או זה
לזה, ולכן אין לחבר אותם אוטומטית כדי לקבל את `C_bubbles`.

## 5.15 הנחות ומגבלות של ההערכה

הטווח 1.135x–1.626x עבור התוכנית המקורית מניח כי:

- ה-input שנצפה נשאר בתוך 16-bit codes, שש טבלאות, 147 entries ו-2,966 selectors;
- ה-workload פולט בדיוק 148,271 Huffman symbols גולמיים כולל EOB;
- ה-complete top עומד ביעד 200 MHz לאחר place-and-route;
- אין stalls של byte-source או symbol-sink במודל cycles של ה-core;
- ה-bit reservoir מחליף נכון את פעולות ה-bit-reader המיועדות;
- אפשר לעבד את ה-raw symbols המוחזרים ב-batch בלי לשנות את הסמנטיקה של
  RUNA/RUNB, ‏EOB, ‏MTF, ‏BWT או RLE הסופי;
- העברת table/selector ו-integration overhead אינם נכללים או נלקחים בחשבון
  בנפרד; וכן
- ה-output של ה-software/hardware זהה ל-golden output בגודל 399,360 בתים ול-MD5.

מגבלות ה-profiling:

- אחוזי sampling הם הערכות, לא timers מדויקים;
- ה-folded profile השתמש ב-Python executable מסוג debug בעוד `timing.json`
  השתמש ב-benchmark interpreter הרגיל, ולכן הכפלת היחס ב-mean משלבת executions
  סמוכות אך לא זהות;
- אחוזי inclusive חופפים ואי אפשר לחבר אותם על פני parent functions;
- samples של wrapper/startup סוננו לפי frame ה-benchmark;
- warnings של kernel-symbol relocation משפיעים על attribution ל-kernel, לא על
  ספירת ה-Python frames שנבחרו; וכן
- עדיין אין הרצה על FPGA, ‏synthesis Fmax או מדידת power של device.

בהתאם לכך, יש לדווח את ה-speedup הצפוי כ-**תחזית אנליטית בעלת תחום שמרני
ותחום אופטימי**, ולעולם לא כהאצה שנמדדה.

## 5.16 החלטה

`HuffmanTable.find_next_symbol` יחד עם גבול ה-bit-reader נשאר בחירה טובה
לפרויקט. הוא מדגים את שני צדי ה-hardware acceleration:

- software profiling, ‏batching, המרת representation, בעלות מוחלטת על bit-state,
  החלטות driver/MMIO/DMA וניתוח Amdahl; וכן
- אחסון tables ב-hardware, לוגיקת match מקבילית, priority resolution,
  streaming reservoir, ‏ready/valid backpressure, ‏feedback באורך משתנה,
  control, ‏counters, ‏errors ופשרות timing/PPA.

הרכיב צר מספיק כדי לממש אותו באופן עקבי ב-SystemVerilog, אך עשיר מספיק כדי
להראות מדוע accelerator הוא יותר מאשר תרגום של פונקציית Python אחת ל-RTL.
