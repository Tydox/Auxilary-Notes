# האצת Raytracing באמצעות Software–Hardware Co-Design

## מסע הדרגתי מעיבוד Ray אחד בכל פעם לעיבוד קבוצות עם NumPy

### תקציר מנהלים

הסיפור של העבודה הזאת מתחיל ב־Raytracer קטן וברור, אבל יקר מאוד להרצה: לכל pixel נוצר `Ray`, לכל `Ray` נבדקים כל האובייקטים, ולכל פגיעה מחושבים reflection, תאורה ו־shadow rays. בגרסה המקורית, רינדור התמונה שנמדדה בגודל 800×800 pixels ארך **29.833 שניות**.

לא שינינו את הבעיה, לא הורדנו precision, לא הוספנו threads ולא כתבנו RTL. במקום זאת עבדנו בלולאת Software–Hardware Co-Design: קראנו את ה־profiling ואת ה־hardware counters, מצאנו איזו עבודה מיותרת התוכנה מבקשת מה־CPU לבצע, שינינו את הקוד ואת צורת ארגון הנתונים, מדדנו שוב, ורק אז עברנו לצעד הבא.

אחרי ארבעה שלבים מצטברים, זמן הריצה ירד ל־**3.184 שניות** עם `batch size` של 2048. זהו `speedup` של **9.37×** והפחתה של **89.33%** בזמן. במקביל, מספר ה־instructions ירד ב־**90.18%** ומספר ה־cycles ירד ב־**88.62%**. כל שש התמונות השמורות — Original, ‏V1, ‏V2, ‏V3, ‏V4/1024 ו־V4/2048 — זהות `byte-for-byte` ובעלות אותו `SHA-256`.

המחיר של V4 הוא שימוש ביותר memory בזמן הריצה: כמות ה־RAM המרבית שנמדדה (`Peak RSS`) עלתה מכ־36.27 MiB לכ־48.91 MiB. בתמורה, Python משקיעה הרבה פחות זמן בניהול objects ובקריאות לפונקציות קטנות, ו־NumPy יכולה לבצע אותה פעולה על קבוצה של rays יחד. זו בדיוק נקודת המבט של Co-Design: לא כל מדד משתפר יחד, ולכן בוחרים פשרה שנותנת את זמן הריצה הטוב ביותר בלי לשנות את התוצאה.

### מילון קצר לפני שמתחילים

כדי שהדוח יהיה נוח לקריאה, הנה המשמעות של כמה מושגים שחוזרים בו:

- **Python object:** ערך ש־Python שומר יחד עם מידע נוסף הדרוש לניהולו. נוח לעבוד כך, אבל הניהול עולה זמן ו־memory.
- **Temporary object:** object שנוצר לצורך חישוב קצר ומיד אחר כך כבר אינו נחוץ.
- **Method call:** קריאה לפונקציה השייכת ל־object, לדוגמה `vector.normalized()`. לפני ההרצה Python צריכה למצוא את ה־method ולהכין את הקריאה.
- **Batch:** קבוצה של rays שמעובדת יחד במקום Ray אחד בכל פעם.
- **Compiled NumPy code:** פונקציות מוכנות של NumPy שכבר תורגמו לקוד מכונה, ולכן אינן עוברות שורת Python עבור כל מספר.
- **Instruction:** פעולה בסיסית שה־CPU מבצע. בדרך כלל פחות instructions עבור אותה תוצאה פירושם פחות עבודה.
- **Cycle:** פעימת שעון של ה־CPU. פחות cycles עבור אותה עבודה בדרך כלל פירושם זמן קצר יותר.
- **Cache:** memory קטן ומהיר הקרוב ל־CPU. נתונים שנמצאים בו נגישים מהר יותר מנתונים שנמצאים רחוק יותר ב־memory.

---

## 1. Overview — מה ה־benchmark עושה?

### 1.1 הבעיה שאנו פותרים

`raytrace` הוא benchmark מתוך suite בסגנון `pyperformance`. המדידה עצמה נעשית בעזרת ספריית `pyperf`, שאותה הקוד מייבא ישירות. חשוב להבדיל בין השניים: `pyperformance` הוא ה־suite, ו־`pyperf` הוא כלי המדידה.

ה־benchmark בונה Scene קבוע:

- Camera במיקום `(0, 1.8, 10)`, המסתכלת אל `(0, 3, 0)`, עם `field of view` של 45°.
- שני מקורות אור נקודתיים.
- Sphere צהוב גדול ועוד שישה Spheres קטנים — שבעה Spheres בסך הכול.
- `Halfspace` אחד עם `CheckerboardSurface`, המשמש כרצפה.
- שמונה אובייקטים בסך הכול ושני מקורות אור.
- `reflection` רקורסיבי עד ארבע רמות מחושבות; הקריאה הבאה מוחזרת כשחור.

לכל pixel נבנה `primary ray` — קו דמיוני שיוצא מה־Camera ועובר דרך אותו pixel. הקוד מאתר את האובייקט הראשון שהקו פוגש ומחשב את ה־normal, כלומר כיוון היוצא ישר מפני השטח. אחר כך הוא מחבר שלושה רכיבי צבע: `specular reflection` הוא ההשתקפות דמוית־המראה, `diffuse lighting` הוא האור הישיר על המשטח, ו־`ambient lighting` הוא אור בסיסי חלש. `Shadow ray` נוסף בודק אם אובייקט אחר חוסם את הדרך אל האור. אם ה־primary ray אינו פוגע בדבר, ה־pixel שחור.

```mermaid
flowchart LR
    I["Input: image size, scene, batch size"]:::input --> C["Generate primary rays"]
    C --> H["Find closest object hit"]
    H -->|Miss| B["Black background"]
    H -->|Hit| S["Compute hit point and normal"]
    S --> R["Recursive reflection"]
    S --> L["Shadow rays and Lambert lighting"]
    S --> A["Ambient lighting"]
    R --> M["Accumulate colour"]
    L --> M
    A --> M
    B --> P["Output: RGB Canvas / optional PPM"]:::output
    M --> P
    classDef input fill:#ffd6d6,stroke:#b91c1c,color:#111
    classDef output fill:#d9fdd3,stroke:#15803d,color:#111
```

### 1.2 המתמטיקה שנשמרה לאורך כל הדרך

ה־Ray מיוצג על ידי:

$$P(t)=P_0+tD$$

עבור Sphere, הקוד מחשב:

$$CP=C-P_0$$

$$v=CP\cdot D$$

$$\Delta=r^2-(CP\cdot CP-v^2)$$

הערך $\Delta$ אומר אם ה־Ray פוגע ב־Sphere: ערך שלילי פירושו שאין פגיעה. אם $\Delta \ge 0$, נבחר השורש הקטן, ו־$t$ מציין כמה צריך להתקדם לאורך ה־Ray עד נקודת הפגיעה:

$$t=v-\sqrt{\Delta}$$

מודל הצבע ניתן לתיאור כך:

$$C=k_sC_{reflection}+k_d\min\left(1,\sum_{visible}\max(0,L\cdot N)\right)C_{base}+k_aC_{base}$$

ברירת המחדל של `SimpleSurface` היא $k_s=0.2$, ‏$k_d=0.6$, ‏$k_a=0.2$. בכל שלבי האופטימיזציה שמרנו על סדר הפעולות, על דיוק `float64` של 64 bits, על סדר האובייקטים והאורות, ועל חוקי הבחירה של הפגיעה.

### 1.3 ספריות ומבני נתונים

הטבלה מפרטת רק את הספריות ואת מבני הנתונים המרכזיים שבהם הקוד משתמש.

| Category | Name | Simple purpose |
|---|---|---|
| Library | `array` | Provides the byte array used for RGB output |
| Library | `math` | Provides `sqrt`, `tan` and `pi` |
| Library | `pyperf` | Measures benchmark runtime |
| Library | `os` | Sets NumPy-related thread limits in V4 |
| Library | `NumPy 2.5.3` | Processes groups of rays in V4 |
| Data structure | `Vector`, `Point`, `Ray` | Store directions, positions and rays |
| Data structure | `Sphere`, `Halfspace` | Represent scene geometry |
| Data structure | `Scene` | Stores objects, lights and camera settings |
| Data structure | `SimpleSurface`, `CheckerboardSurface` | Store colour and lighting settings |
| Data structure | `Canvas`, `array.array('B')` | Store three RGB bytes for every pixel |
| Data structure | `BatchedRenderer` | Processes groups of rays with NumPy in V4 |
| Data structure | Python `list` and `tuple` | Store objects, surfaces, lights and colours |
| Data structure | NumPy `float64` arrays | Store many ray coordinates together in V4 |
| Data structure | NumPy Boolean arrays | Mark which rays are active, hit or blocked in V4 |

בגרסה המקורית, כל coordinate הוא `float` רגיל של Python שנמצא בתוך `Vector`, ‏`Point` או `Ray`. זה נוח וברור, אבל חיבור או נרמול של vectors יוצר לעיתים object חדש וקורא לכמה methods קטנים. ב־V4, החישובים החמים משתמשים גם במערכים שבהם נמצאים יחד ערכי `x`, ‏`y` ו־`z` של rays רבים. כך NumPy יכולה לבצע פעולה אחת על קבוצה של rays, במקום ש־Python תטפל בכל Ray בנפרד.

### 1.4 מה נכלל בזמן המדוד?

ה־timer של `bench_raytrace` כולל בכל איטרציה:

- יצירה ואתחול של `Canvas`.
- בניית ה־Scene, האובייקטים, החומרים והאורות.
- ב־V4, גם יצירת `BatchedRenderer` והמרת נתוני ה־Scene למערכי NumPy.
- יצירת ה־rays, חישוב החיתוכים, shading וכתיבת pixels ל־Canvas.

כתיבת קובץ ה־`PPM` האופציונלי מתבצעת אחרי עצירת ה־timer, ולכן אינה מנפחת את ה־speedup. כל מדידות ההשוואה שניתנו בוצעו במפורש על 800×800 pixels, גם אם ברירות המחדל ההיסטוריות בחלק מהקבצים שונות.

---

## 2. Initial Analysis — להבין לאן הזמן הולך

### 2.1 סביבת המדידה

כל הגרסאות נמדדו עם אותו גודל תמונה ואותו סוג סביבה. V4 מגבילה במפורש את ספריות החישוב ל־thread יחיד, כך שההאצה אינה תוצאה של multicore נסתר.

| Property | Recorded value |
|---|---|
| Workload | `800 × 800` pixels |
| CPU | `Intel Xeon E5-2630 v3 @ 2.40 GHz` |
| Available CPU count | `1` |
| Operating system | `Linux 5.15 KVM, x86-64` |
| Python | `CPython 3.12.13, 64-bit` |
| V4 NumPy | `2.5.3` |
| V4 numeric-library thread limit | `1` |
| Profiling event | `cpu-clock`, 199 Hz |
| Hardware measurement | `perf stat` |

### 2.2 ה־Flame Graph המקורי

ב־Flame Graph, כל מלבן מייצג function. מלבן רחב יותר פירושו שה־profiler ראה את אותה function לעיתים קרובות יותר, ולכן כדאי לבדוק אותה כמועמדת לאופטימיזציה. מלבן יכול להכיל functions שהוא קרא להן, ולכן האחוזים חופפים ואין לחבר אותם. ה־profiling נעשה עם גרסת Python שמציגה מידע מפורט יותר על הקריאות; לזמני הריצה עצמם אנו משתמשים ב־`pyperf`.

![Original Raytrace Flame Graph](assets/flamegraph-original.svg)

ה־Flame Graph מספר סיפור עקבי: כמעט כל העבודה נמצאת בתוך `Scene.render`, ורוב העבודה ממשיכה דרך `rayColour`, ‏`colourAt`, בדיקות האם האור חסום וחישובי Sphere. הטבלה מדרגת את ה־functions לפי חלקן בדגימות; כאן חץ למעלה פירושו “יעד חשוב יותר לבדיקה”, לא “קוד מהיר יותר”.

| Original function | Profiler sample share (%) ↑ |
|---|---:|
| `Scene.render` | **73.56** |
| `Scene.rayColour` | 62.73 |
| `SimpleSurface.colourAt` | 41.03 |
| `Scene.visibleLights` | 22.38 |
| `Scene._lightIsVisible` | 22.12 |
| `Sphere.intersectionTime` | 16.60 |
| `Point.__sub__` | 5.44 |
| `Vector.dot` | 5.40 |

### 2.3 מה ראינו מעבר ל־Flame Graph?

בגרסה המקורית נמדדו כ־71.648 billion cycles, ‏186.717 billion instructions ו־30.397 billion branch instructions. ה־CPU היה עסוק כמעט לחלוטין. כלומר, הבעיה לא הייתה CPU “רדום”; הוא ביצע הרבה מאוד פעולות כדי לנהל Python objects וקריאות ל־methods, אף שהמתמטיקה עצמה קצרה יחסית.

מהקוד ומה־profiling זיהינו ארבעה סוגי בזבוז:

1. **חישוב חוזר:** אותם camera components, ‏shadow directions ו־$r^2$ חושבו שוב ושוב.
2. **objects קצרי חיים:** פעולות חשבון יצרו `Vector`, ‏`Point`, lists ו־tuples שנדרשו רק לרגע.
3. **הרבה קריאות קטנות:** פעולה מתמטית קצרה עברה דרך כמה methods ובדיקות של סוג האובייקט לפני שהסתיימה.
4. **Ray אחד בכל פעם:** Python עיבדה כל Ray בנפרד, אף על פי ש־rays שונים אינם תלויים זה בזה.

זו הייתה נקודת המפתח: לפני שמנסים “להאיץ את המתמטיקה”, כדאי לצמצם את כל מה שמקיף אותה.

```mermaid
flowchart LR
    P["Profile software"] --> C["Read hardware counters"]
    C --> H["Form a hardware-aware hypothesis"]
    H --> S["Change software or data layout"]
    S --> V["Verify identical output"]
    V --> M["Measure again"]
    M --> P
```

---

## 3. Optimizations — המסע, צעד אחר צעד

כל גרסה נבנתה מעל קודמתה. לא מדובר בארבע חלופות נפרדות, אלא בסדרה מצטברת: בכל שלב פתרנו בעיה אחת, מדדנו שוב, ואז ראינו מה הפך לחלק האיטי הבא.

```mermaid
flowchart LR
    O["Original: Python processes one ray at a time"] --> V1["V1: reuse calculations and create fewer objects"]
    V1 --> V2["V2: use fewer small function calls"]
    V2 --> V3["V3: calculate fixed values once"]
    V3 --> V4["V4: process groups of rays with NumPy"]
    V4 --> Q["Same image, much less CPU work"]
```

### 3.1 V1 — קודם כול מפסיקים לבזבז עבודה

השלב הראשון הוא הגדול ביותר מבין השיפורים שעדיין מעבדים Ray אחד בכל פעם. הוא לא משנה את האלגוריתם; הוא מסיר עבודה שה־CPU לא היה צריך לבצע מלכתחילה.

#### א. `__slots__` ל־Vector, Point ו־Ray

בדרך כלל, כל instance שומר dictionary פנימי עם שמות השדות שלו. `__slots__` אומר מראש של־`Vector` ול־`Point` יש רק `x`, ‏`y`, ‏`z`, ול־`Ray` יש רק `point` ו־`vector`. לכן Python צריכה לנהל פחות מידע עבור כל object. ערכי ה־coordinates עצמם עדיין נשארים `float` רגילים של Python; רק צורת שמירת השדות נעשתה פשוטה יותר.

#### ב. חישוב Sphere ישירות עם מספרים מקומיים

במקום ליצור `cp` כ־Vector ולקרוא מספר פעמים ל־`dot`, הקוד מעתיק את `x`, ‏`y`, ‏`z` למשתנים מקומיים וכותב את אותה נוסחה ישירות. התוצאה המתמטית נשמרת, אך נחסכים object זמני וכמה קריאות ל־methods.

#### ג. Camera components פעם אחת לשורה ולעמודה

במקור חושבו `xcomp` ו־`ycomp` מחדש לכל pixel. ב־800×800 pixels מדובר ב־1,280,000 constructions של vectors רק עבור שני offsets. ב־V1, הרכיב האופקי מחושב פעם אחת לכל column והרכיב האנכי פעם אחת לכל row. החיסכון הוא:

$$2WH-W-H=1{,}278{,}400$$

Vector objects קצרי חיים, בנוסף לחיבורים ולכפלים שנדרשו כדי ליצור אותם.

#### ד. מציאת הפגיעה הקרובה באותה לולאה

המקור בנה list של שמונה tuples לכל Ray ורק אחר כך עבר עליה שוב באמצעות `firstIntersection`. ב־V1, `rayColour` בודק כל object פעם אחת ושומר מיד את הפגיעה הקרובה ביותר. כללי הבחירה נשארו זהים: אותו `EPSILON`, אותו סדר אובייקטים ואותה בחירה באובייקט הראשון במקרה של tie.

#### ה. Shadow Ray אחד לכל light

במקור, אותו `Ray(p, light-p)` נבנה מחדש עבור כל object, ובכל פעם כיוון ה־Ray הומר לאורך 1. לאחר שנמצא שהאור אינו חסום, אותה המרה בוצעה שוב לצורך התאורה. ב־V1 נבנה Shadow Ray אחד לכל צמד point/light, משתמשים בו לכל בדיקות החסימה, ואז משתמשים שוב באותו כיוון בתאורה.

#### ו. הסרת פעולה שלא השפיעה על התוצאה

ב־`CheckerboardSurface`, הקריאה `v.scale(1.0 / checkSize)` יצרה Vector חדש, אבל הקוד לא שמר אותו ולא השתמש בו. הסרת הקריאה אינה משנה את הדוגמה המצוירת; היא רק מפסיקה ליצור object ולבצע חישוב חסרי השפעה. לכן גם ההתנהגות ההיסטורית שבה `checkSize` אינו אפקטיבי נשמרת.

**התוצאה:** זמן הריצה ירד מ־29.833 ל־13.637 שניות — `speedup` של 2.19× והפחתה של 54.29%. גם ה־instructions ירדו בכ־55.56% לעומת Original. זהו אישור חזק לכך שרוב הזמן התבזבז על חישובים חוזרים וניהול objects, ולא מפני שהיה חסר אלגוריתם חיתוך חדש.

### 3.2 V2 — מקצרים את הדרך למתמטיקה

אחרי V1, כל Ray עדיין עבר לבדו דרך `normalized`, ‏`pointAtTime`, ‏`normalAt` ו־`reflectThrough`. כל פונקציה קטנה בפני עצמה, אבל היא נקראת פעמים רבות מאוד.

ב־V2 כתבנו את הנוסחה ישירות בתוך ארבע פונקציות חמות, במקום להרכיב אותה משרשרת של פונקציות קטנות:

- `Vector.normalized` מחשב ישירות $x^2+y^2+z^2$, ‏`sqrt`, חלוקה ושלוש פעולות כפל, בלי לעבור דרך `magnitude → dot → scale`.
- `Vector.reflectThrough` משתמש ב־`dot` אך יוצר רק Vector תוצאה אחד, במקום שלושה Vector objects זמניים.
- `Ray.pointAtTime` יוצר ישירות את ה־Point הסופי, בלי ליצור קודם Vector נוסף.
- `Sphere.normalAt` מחשב את הכיוון ואת אורכו במקום אחד ויוצר רק את ה־normal הסופי.

לא שינינו את סדר פעולות החשבון, כדי לא לשנות אפילו הבדלי rounding קטנים. לדוגמה, `Sphere.normalAt` עדיין מנרמל את ה־Vector ולא פשוט מחלק ברדיוס, ו־reflection שומר על שתי פעולות הכפל המקוריות.

מבחינת hardware, המשמעות פשוטה: Python מבצעת פחות קריאות לפונקציות ויוצרת פחות objects זמניים כדי להגיע לאותה תשובה. זמן הריצה ירד מ־13.637 ל־12.734 שניות — שיפור נוסף של 6.62%, ו־speedup מצטבר של 2.34×.

### 3.3 V3 — מחשבים פעם אחת ערכים שאינם משתנים

בשלב זה נשארו שתי פעולות קטנות אך חוזרות:

1. `radius * radius` חושב בכל בדיקת Sphere, אף שהרדיוס קבוע.
2. הביטוי `eye.vector + horizontalOffset` חושב לכל pixel, אף שהוא קבוע לאורך column.

לכן V3 מוסיף `radiusSquared` בזמן בניית כל Sphere, ושומר לכל column את `eye.vector + horizontalOffset`. ב־800×800, שמירת הביטוי השני חוסכת:

$$WH-W=639{,}200$$

יצירות של Vector objects ועוד 1,917,600 חיבורים של coordinates בכל render. החישוב המקדים עדיין נמצא בתוך הזמן המדוד, ולכן לא “החבאנו” עבודה מחוץ למדידה.

הרעיון כאן פשוט: ערך שאינו משתנה בתוך לולאה צריך לחשב פעם אחת לפני הלולאה, ולא שוב בכל סיבוב. מעט memory נוסף מחליף הרבה חישובים חוזרים. ההנחה היא שה־Scene סטטי; אם משנים `radius` אחרי יצירת ה־Sphere, צריך לעדכן גם את `radiusSquared`.

זמן הריצה ירד מ־12.734 ל־12.076 שניות — שיפור נוסף של 5.17% ו־speedup מצטבר של 2.47×.

### 3.4 V4 — משנים את צורת העבודה כדי להתאים ל־hardware

שלושת השלבים הראשונים הפכו את הקוד ליעיל בהרבה, אך Python עדיין עיבדה כל Ray בנפרד. כאן הגיע השינוי הגדול: V4 אוספת rays בלתי תלויים לקבוצות (`batches`), ו־NumPy מבצעת את אותו חישוב על כל הקבוצה.

`BatchedRenderer` נוצר בתוך ה־timer ומבצע:

- המרה של נתוני האובייקטים, החומרים והאורות למערכי NumPy פעם אחת לכל render.
- אחסון coordinates במערך `float64` בצורת `(3, N)`: שורה אחת ל־`x`, שורה אחת ל־`y`, שורה אחת ל־`z`, וכל עמודה מייצגת Ray.
- יצירת primary rays לפי סדר ה־pixels בתמונה, בקבוצות עוקבות ובקבוצה אחרונה קצרה במידת הצורך.
- חישוב זמן הפגיעה בכל object עבור כל ה־rays שעדיין פעילים.
- שמירת אותו סדר אובייקטים ואותה בחירה באובייקט הראשון כאשר שתי פגיעות שוות.
- סינון rays שכבר נחסמו לפני בדיקת ה־shadow object הבא.
- שימוש במערכי `True/False` כדי לסמן אילו rays פגעו, נחסמו או עדיין זקוקים ל־reflection.
- שמירת סדר הצבירה: reflection, אחר כך diffuse, אחר כך ambient.
- העברת הצבעים דרך `Canvas.plot` המקורי כדי לשמור בדיוק על אותו חיתוך ספרות, אותה הגבלה לטווח 0…255 ואותו כיוון תמונה.

```mermaid
flowchart LR
    I["Input: independent rays"]:::input --> P["Store ray coordinates in arrays"]
    P --> B["Process one group of rays"]
    B --> U["NumPy performs the calculations"]
    U --> F["Keep active rays and calculate reflections"]
    F --> C["Convert colours to RGB"]
    C --> O["Output: byte-identical RGB pixels"]:::output
    classDef input fill:#ffd6d6,stroke:#b91c1c,color:#111
    classDef output fill:#d9fdd3,stroke:#15803d,color:#111
```

#### למה זהו Co-Design גם בלי RTL?

האלגוריתם נשאר אותו Raytracer, אבל הקוד מוסר את העבודה ל־CPU בצורה נוחה יותר:

- coordinates של rays רבים נשמרים יחד במערכי NumPy.
- קריאת NumPy אחת מחליפה מאות או אלפי סיבובי לולאה של Python.
- NumPy משתמשת בפונקציות מהירות שכבר קומפלו לקוד מכונה. חלקן יכולות להשתמש ב־SIMD — instruction יחיד של CPU שמטפל בכמה מספרים יחד.
- עלות ההכנה של כל קריאה מתחלקת בין rays רבים.
- `batch size` הוא פשוט מספר ה־rays שמעובדים יחד. Batch גדול חוסך קריאות ל־NumPy, אבל דורש arrays זמניים גדולים יותר.

ב־profiling נצפו שמות כמו `DOUBLE_multiply_X86_V3`, ‏`DOUBLE_add_X86_V3` ו־`DOUBLE_subtract_X86_V3`. השמות מראים ש־NumPy בחרה פונקציות חישוב שהותאמו למשפחת ה־CPU. עם זאת, לא ספרנו ישירות SIMD instructions, ולכן איננו טוענים שכל פעולה השתמשה ב־SIMD.

מספר ה־threads הוגבל ל־1 לפני טעינת NumPy. לכן V4 משתמשת ב־CPU core אחד בלבד, וה־speedup לא הגיע מ־cores נוספים. הוא הגיע מכך ש־NumPy מבצעת חישובים רבים בקוד מכונה, בעוד Python מנהלת פחות עבודה לכל Ray.

ברירת המחדל הסופית היא `batch size = 2048`. מערך coordinates יחיד בגודל `3 × 2048 × 8` bytes תופס כ־48 KiB, לעומת כ־24 KiB עבור 1024. מכיוון שבזמן החישוב קיימים כמה arrays יחד, batch גדול יותר יכול להשתמש ביותר memory. לכן מדדנו את שני הגדלים במקום לנחש.

עם 2048, זמן הריצה ירד מ־12.076 שניות ב־V3 ל־3.184 שניות — שיפור של 3.79× בשלב אחד, והפחתה של 73.64% בזמן לעומת V3.

### 3.5 סיכום רעיוני של ארבעת השלבים

| Stage | Problem found | Change made | Result for the CPU |
|---|---|---|---|
| V1 | Repeated calculations and many temporary objects | Reuse values, scan objects once and calculate sphere values directly | Fewer Python operations and object creations |
| V2 | Small calculations required many Python function calls | Write four formulas directly where they are used | Fewer function calls and temporary objects |
| V3 | Constant values were recalculated inside loops | Calculate radius and camera values once | Fewer repeated calculations |
| V4 | Python still processed one ray at a time | Group rays in NumPy arrays and process them together | Much less Python work per ray |

---

## 4. Performance Comparison — מה השתפר בפועל?

### 4.1 זמני הריצה המצטברים

הערכים נלקחו ישירות מ־`timing.json`. כל השורות משתמשות ב־800×800 pixels. V4 מופיעה בשני גדלי batch כנדרש; בכל שאר הדיון V4 מתייחסת כברירת מחדל ל־2048.

| Version | Runtime (s) ↓ | Speedup vs Original (×) ↑ | Time reduction vs Original (%) ↑ | Maximum RAM (MiB) ↓ |
|---|---:|---:|---:|---:|
| Original | 29.833 | 1.00 | 0.00 | **36.27** |
| V1 | 13.637 | 2.19 | 54.29 | 36.39 |
| V2 | 12.734 | 2.34 | 57.31 | 36.43 |
| V3 | 12.076 | 2.47 | 59.52 | 36.48 |
| V4, batch 1024 | 3.862 | 7.72 | 87.05 | 48.97 |
| V4, batch 2048 | **3.184** | **9.37** | **89.33** | 48.91 |

```mermaid
xychart-beta
    title "Raytrace runtime by version (800x800)"
    x-axis ["Original", "V1", "V2", "V3", "V4-1024", "V4-2048"]
    y-axis "Runtime (seconds, lower is better)" 0 --> 32
    bar [29.833, 13.637, 12.734, 12.076, 3.862, 3.184]
```

הגרף ממחיש שני פרקים שונים בסיפור: V1 מסירה הרבה פעולות ניהול מיותרות של Python בבת אחת; V2 ו־V3 ממשיכות לצמצם חישובים וקריאות; V4 מעבדת rays רבים יחד ומביאה קפיצה נוספת.

### 4.2 התרומה של כל שלב לעומת קודמו

כאן V4 מיוצגת רק בברירת המחדל 2048, כדי לא לערבב configuration חלופי עם שלב אופטימיזציה נוסף.

| Stage | Runtime (s) ↓ | Incremental speedup (×) ↑ | Incremental time reduction (%) ↑ | Cumulative speedup (×) ↑ |
|---|---:|---:|---:|---:|
| Original | 29.833 | 1.000 | 0.00 | 1.00 |
| V1 | 13.637 | 2.188 | 54.29 | 2.19 |
| V2 | 12.734 | 1.071 | 6.62 | 2.34 |
| V3 | 12.076 | 1.055 | 5.17 | 2.47 |
| V4, batch 2048 | **3.184** | **3.793** | **73.64** | **9.37** |

### 4.3 מדוע 2048 נבחר כברירת המחדל?

| Batch size | Runtime (s) ↓ | Speedup vs Original (×) ↑ | Speedup vs 1024 (×) ↑ | Cycles (B) ↓ | Instructions (B) ↓ | Maximum RAM (MiB) ↓ |
|---:|---:|---:|---:|---:|---:|---:|
| 1024 | 3.862 | 7.72 | 1.00 | 9.715 | 21.010 | 48.97 |
| 2048 | **3.184** | **9.37** | **1.21** | **8.150** | **18.345** | **48.91** |

2048 קצר ב־17.57% בזמן לעומת 1024, עם 16.10% פחות cycles ו־12.69% פחות instructions. כמות ה־RAM המרבית שנמדדה כמעט זהה. ב־2048 העלות הקבועה של כל קריאת NumPy מתחלקת בין יותר rays. במקרה שנמדד, החיסכון הזה היה גדול יותר מהעלות של arrays גדולים יותר, ולכן 2048 היא הבחירה הנכונה.

### 4.4 Hardware counters לאורך המסע

לפני הטבלה, הנה פירוש פשוט של העמודות:

- `Cycles` הן פעימות השעון שעברו בזמן העבודה.
- `Instructions` הן פעולות בסיסיות שה־CPU ביצע.
- `Branch instructions` הן נקודות החלטה בקוד, ו־`branch misses` הן החלטות שה־CPU ניחש לא נכון ונאלץ לתקן.
- `L1D` הוא ה־data cache הקרוב והמהיר ביותר של ה־CPU.
- `IPC` הוא מספר ה־instructions הממוצע שהסתיימו בכל cycle. ערך גבוה לבדו אינו מבטיח זמן ריצה נמוך, מפני שחשוב גם כמה instructions יש בסך הכול.

הטבלה מציגה את הסכומים מתוך `perf stat`. האות `B` פירושה billion והאות `M` פירושה million. ה־CPU אינו יכול למדוד את כל האירועים בו־זמנית, ולכן `perf` עבר ביניהם והעריך את הסכומים. ההבדלים הגדולים שימושיים, אך אין לייחס משמעות רבה להבדלים קטנים.

| Version | Cycles (B) ↓ | Instructions (B) ↓ | Branch instructions (B) ↓ | Branch misses (M) ↓ | L1D loads (B) ↓ | L1D misses (M) ↓ | IPC ↑ |
|---|---:|---:|---:|---:|---:|---:|---:|
| Original | 71.648 | 186.717 | 30.397 | 173.482 | 42.988 | 585.915 | **2.606** |
| V1 | 33.030 | 82.982 | 13.709 | 79.909 | 19.108 | 410.781 | 2.512 |
| V2 | 30.326 | 77.799 | 12.949 | 68.097 | 18.230 | 326.121 | 2.565 |
| V3 | 29.442 | 74.432 | 12.386 | 66.875 | 17.154 | 376.699 | 2.528 |
| V4, batch 1024 | 9.715 | 21.010 | 3.579 | 24.252 | 4.304 | 213.002 | 2.163 |
| V4, batch 2048 | **8.150** | **18.345** | **3.140** | **18.213** | **3.799** | **201.150** | 2.251 |

התובנה החשובה היא שה־IPC הגבוה ביותר דווקא שייך ל־Original, והיא עדיין הגרסה האיטית ביותר. V4 אינה מנצחת מפני שכל cycle “עושה יותר”; היא מנצחת מפני שבסך הכול ה־CPU מקבל הרבה פחות instructions לבצע. Original → V4/2048 נותן:

- 90.18% פחות instructions.
- 88.62% פחות cycles.
- 89.67% פחות branch instructions.
- 89.50% פחות branch misses במספר מוחלט.
- 91.16% פחות L1D loads.
- 65.67% פחות L1D misses במספר מוחלט.

מצד שני, אחוז הפעמים שבהן הנתון לא נמצא ב־L1D cache עולה מ־1.36% ל־5.29%, וכמות ה־RAM המרבית עולה ב־34.84%. הסיבה היא שב־V4 קיימים arrays זמניים גדולים יותר. למרות זאת, סך ה־instructions וה־cycles קטן כל כך שזמן הריצה הכולל עדיין משתפר פי 9.37.

### 4.5 ה־Flame Graph לאחר V4

![V4 2048 Raytrace Flame Graph](assets/flamegraph-v4-2048.svg)

ב־V4/2048, ה־functions שטיפלו בכל Ray בנפרד — `rayColour`, ‏`colourAt`, ‏`visibleLights` ו־`Sphere.intersectionTime` — כבר אינן החלק המרכזי בגרף. `BatchedRenderer.render` מופיע ב־58.72% מהדגימות, ואילו `Canvas.plot` — שעדיין כותבת pixel אחד בכל פעם ב־Python כדי לשמר את ההמרה המקורית — מגיעה ל־45.45%. `BatchedRenderer.rayColours` עצמו מופיע בכ־2.43%, וכל אחת מהפונקציות הקטנות שלו מתחת ל־1%.

זהו רגע חשוב בסיפור: לאחר שמאיצים חלק אחד, חלק אחר שלא השתנה הופך למגבלה החדשה. אחרי שהחישובים עברו ל־batches, המרת הצבע וכתיבת pixels אחד־אחד הפכו ליעד הבא האפשרי.

### 4.6 Original מול התוצאה הסופית

| Metric | Original | V4, batch 2048 | Change | Preferred direction |
|---|---:|---:|---:|---:|
| Runtime (s) ↓ | 29.833 | **3.184** | **−89.33%** | ↓ |
| Speedup (×) ↑ | 1.00 | **9.37** | **9.37× overall** | ↑ |
| Cycles (B) ↓ | 71.648 | **8.150** | **−88.62%** | ↓ |
| Instructions (B) ↓ | 186.717 | **18.345** | **−90.18%** | ↓ |
| Branch instructions (B) ↓ | 30.397 | **3.140** | **−89.67%** | ↓ |
| L1D loads (B) ↓ | 42.988 | **3.799** | **−91.16%** | ↓ |
| Maximum RAM (MiB) ↓ | **36.27** | 48.91 | +34.84% | ↓ |

---

## 5. Verification — הוכחה שלא האצנו על ידי שינוי התוצאה

### 5.1 בדיקת התוצר בפועל

לכל גרסה נשמר קובץ `raytrace.ppm` של 800×800. ‏`SHA-256` הוא מעין טביעת אצבע המחושבת מכל ה־bytes בקובץ. לכל ששת הקבצים יש אותו גודל ואותה טביעת אצבע, ולכן התוצרים השמורים זהים `byte-for-byte`, כולל ה־header, סדר ה־pixels וערכי RGB.

| Version | File size (bytes) | SHA-256 | Result |
|---|---:|---|---|
| [Original](<../report raytracing/single Orignal/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |
| [V1](<../report raytracing/single v1/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |
| [V2](<../report raytracing/single v2/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |
| [V3](<../report raytracing/single v3/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |
| [V4, batch 1024](<../report raytracing/single v4 1024/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |
| [V4, batch 2048](<../report raytracing/single v4 2048/raytrace.ppm>) | **1,920,015** | **`3F8C8BBCA2BD3188BA3AD3B95AE29950C53E1F534983D82A6AF15256AB3D59F0`** | **BYTE-IDENTICAL** |

גודל הקובץ מתאים בדיוק ל־15 bytes של header ועוד $800\cdot800\cdot3=1{,}920{,}000$ bytes של RGB.

### 5.2 פרטים טכניים שנשמרו במכוון

ה־hash הזהה הוא ההוכחה החשובה ביותר. הכללים הבאים מסבירים כיצד שמרנו על אותה תמונה:

- אותו כלל מתמטי לבחירת נקודת הפגיעה ב־Sphere.
- אותם ערכי `EPSILON` שמחליטים אם הייתה פגיעה ואם נקודה נמצאת ב־shadow.
- אותו סדר objects ואותה בחירה באובייקט הראשון כאשר שתי פגיעות שוות.
- אותו סדר lights ואותו סדר חיבור של reflection, ‏diffuse ו־ambient.
- אותו עומק reflection ואותה camera geometry.
- אותה התנהגות של ה־Halfspace ושל דוגמת ה־checkerboard.
- אותה המרת RGB: כפל ב־255, חיתוך החלק העשרוני והגבלה לטווח 0…255.
- אותו דיוק מספרי מסוג `float64` ואותו סדר פעולות חשבון.

`OPTIMIZATIONS.md` מתעד בנוסף בדיקות במספר גדלי תמונה ומקרי קצה של Sphere, ‏shadow, ‏reflection ו־batches חלקיים. עבור ברירת המחדל החדשה 2048, קובץ ה־PPM השמור מספק בדיקה מלאה של התהליך מתחילתו ועד סופו על תמונה של 800×800.

### 5.3 קישור המדידות לקוד שסופק

לכל run נשמר `source_sha256`, כלומר טביעת אצבע של קובץ הקוד. לאחר שאיחדנו את סימון סוף השורה של Windows ושל Linux, הטביעות התאימו לכל חמש גרסאות הקוד. לכן ברור איזה קובץ מקור שייך לכל תוצאה.

### 5.4 גבולות ההבטחה

ההוכחה היא חזקה עבור ה־benchmark וה־Scene שנמדדו, אך אינה טענה שכל API אפשרי נשאר זהה:

- `__slots__` מתאים למחלקות שבהן רשימת השדות ידועה מראש; אי אפשר להוסיף להן שדות חדשים באופן חופשי.
- כתיבת הנוסחאות ישירות מתאימה למחלקות הקיימות, ולא ל־subclasses שמשנים את התנהגות פונקציות העזר.
- `radiusSquared` מניח שהרדיוס אינו משתנה לאחר יצירת ה־Sphere.
- `BatchedRenderer` מכיר את סוגי ה־geometry וה־surface של ה־benchmark, ולא נועד להיות מערכת plugins כללית.
- קלט לא תקין, Vector באורך אפס או `batch size` לא תקין אינם חלק מה־workload.

הגבולות האלה מקובלים כאן, מפני שהמטרה הייתה לשמר בדיוק את workload המוגדר — לא להרחיב את ה־Raytracer לספרייה כללית.

---

## 6. Conclusion — מה למדנו מן המסע?

השיפור המרכזי לא הגיע מטריק יחיד. הוא הגיע מסדרה של שאלות פשוטות שנשאלו בסדר הנכון.

בהתחלה שאלנו: **איזו עבודה חוזרת ללא צורך?** התשובה הובילה ל־V1: שימוש חוזר ב־Shadow Rays ובערכי Camera, מעבר אחד על האובייקטים, פחות objects זמניים ו־`__slots__`. זה לבדו חתך יותר ממחצית מזמן הריצה.

לאחר מכן שאלנו: **מדוע פעולה מתמטית קצרה דורשת כל כך הרבה קריאות Python?** התשובה הובילה ל־V2: כתיבת ארבע נוסחאות ישירות במקום שרשרת של פונקציות עזר.

אחר כך שאלנו: **אילו ערכים קבועים בתוך הלולאה?** התשובה הובילה ל־V3 ול־caching של `radiusSquared` ושל camera expressions לכל column.

לבסוף שאלנו: **איך כדאי למסור את העבודה ל־CPU?** Rays הם עצמאיים, ולכן V4 ארגנה אותם בקבוצות והעבירה את החישובים למערכי NumPy. כך קריאת NumPy אחת מטפלת ב־rays רבים. מספר ה־instructions ירד בכ־90% וזמן הריצה ירד בכ־89%, בלי threads נוספים ובלי שינוי בתמונה.

התוצאה הסופית היא מעבר מ־29.833 ל־3.184 שניות — **9.37× faster** — עם תוצר 800×800 זהה `byte-for-byte`. המחיר הוא שימוש בכ־34.84% יותר RAM בשיא. למרות שאחוז ה־L1D cache misses גבוה יותר, מספר ה־misses הכולל עדיין קטן ב־65.67%, משום שה־CPU מבצע הרבה פחות גישות בסך הכול.

זהו Software–Hardware Co-Design במובן המעשי שלו: לא בנינו hardware חדש, אלא שינינו את software כך שה־CPU יבצע פחות עבודה ויקבל rays רבים יחד בצורה שמתאימה ל־NumPy. אחר כך בדקנו בעזרת hardware counters שה־instructions וה־cycles אכן ירדו. המדידות לא היו רק קישוט בדוח; הן עזרו לבחור את הצעד הבא.

ה־Flame Graph הסופי גם מצביע על המשך טבעי: `Canvas.plot` היא כעת ה־function הבולטת ביותר. אופטימיזציה עתידית יכולה להמיר ולכתוב קבוצה של pixels יחד, אך היא חייבת לשמור בדיוק על אותו עיגול מספרים, אותה הגבלה ל־0…255, אותו סדר שורות ואותם PPM bytes. זה יהיה הפרק הבא באותו סיפור: למדוד, לשנות דבר אחד, ולאמת שוב.

---

## Appendix A — מגבלות וקריאה אחראית של המדידות

- קובצי התזמון שסופקו מכילים מדידה שמורה אחת לכל configuration, ולא סדרה שממנה אפשר לחשב את פיזור התוצאות. לכן אנו מדווחים בדיוק את מה שנמדד, בלי לטעון מה יהיה הטווח בהרצות נוספות.
- Original והגרסאות המשופרות נמדדו בזמנים שונים, אך עם אותו דגם CPU, אותה מהירות מדווחת, אותה גרסת Linux, אותה גרסת Python ו־CPU יחיד. השיפורים הגדולים ברורים; אם רוצים להעריך במדויק הבדל קטן, כדאי לחזור על המדידה כמה פעמים.
- Flame Graphs נאספו עם גרסת Python שמספקת מידע מפורט יותר על קריאות לפונקציות. זמני `pyperf` נאספו עם גרסת Python הרגילה. לכן Flame Graph משמש לאיתור functions איטיות, ולא לחישוב ה־speedup.
- ה־CPU לא יכול היה למדוד את כל ה־hardware counters בו־זמנית, ולכן `perf` עבר ביניהם והעריך את הסכומים. השינויים הגדולים שימושיים; הבדלים קטנים פחות ודאיים.
- כמה מדדי cache ועיכובים פנימיים של ה־CPU לא היו זמינים. לכן הדוח אינו מנסה להסביר נתונים שלא נמדדו.
- `perf stat` כולל גם את פתיחת תהליך Python וטעינת הספריות. זמני `pyperf` הם המקור להשוואת זמן ה־benchmark עצמו.
- בחלק מהמדידות תיקיית הקוד הכילה גם שינויים שלא נשמרו ב־Git. עם זאת, לכל מדידה נשמר hash של קובץ המקור המדויק, והוא תואם לגרסה שסופקה.

## Appendix B — קבצי Profiling

| Version | Flame Graph | Folded stacks source |
|---|---|---|
| Original | [Open SVG](assets/flamegraph-original.svg) | [Open folded stacks](<../report raytracing/single Orignal/speedscope.folded>) |
| V1 | [Open SVG](assets/flamegraph-v1.svg) | [Open folded stacks](<../report raytracing/single v1/speedscope.folded>) |
| V2 | [Open SVG](assets/flamegraph-v2.svg) | [Open folded stacks](<../report raytracing/single v2/speedscope.folded>) |
| V3 | [Open SVG](assets/flamegraph-v3.svg) | [Open folded stacks](<../report raytracing/single v3/speedscope.folded>) |
| V4, batch 1024 | [Open SVG](assets/flamegraph-v4-1024.svg) | [Open folded stacks](<../report raytracing/single v4 1024/speedscope.folded>) |
| V4, batch 2048 | [Open SVG](assets/flamegraph-v4-2048.svg) | [Open folded stacks](<../report raytracing/single v4 2048/speedscope.folded>) |

## Appendix C — מקורות הנתונים הגולמיים

| Version | Timing | Hardware counters | Profiling report | Run metadata |
|---|---|---|---|---|
| Original | [timing.json](<../report raytracing/single Orignal/timing.json>) | [perf_stat.txt](<../report raytracing/single Orignal/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single Orignal/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single Orignal/run_metadata.txt>) |
| V1 | [timing.json](<../report raytracing/single v1/timing.json>) | [perf_stat.txt](<../report raytracing/single v1/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single v1/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single v1/run_metadata.txt>) |
| V2 | [timing.json](<../report raytracing/single v2/timing.json>) | [perf_stat.txt](<../report raytracing/single v2/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single v2/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single v2/run_metadata.txt>) |
| V3 | [timing.json](<../report raytracing/single v3/timing.json>) | [perf_stat.txt](<../report raytracing/single v3/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single v3/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single v3/run_metadata.txt>) |
| V4, batch 1024 | [timing.json](<../report raytracing/single v4 1024/timing.json>) | [perf_stat.txt](<../report raytracing/single v4 1024/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single v4 1024/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single v4 1024/run_metadata.txt>) |
| V4, batch 2048 | [timing.json](<../report raytracing/single v4 2048/timing.json>) | [perf_stat.txt](<../report raytracing/single v4 2048/perf_stat.txt>) | [perf_report.txt](<../report raytracing/single v4 2048/perf_report.txt>) | [run_metadata.txt](<../report raytracing/single v4 2048/run_metadata.txt>) |

## Appendix D — גרסאות הקוד שנמדדו

ה־hashes בטבלה הם טביעות האצבע שנשמרו בזמן כל מדידה. הם תואמים לקבצים המקומיים לאחר שאיחדנו את סימון סוף השורה של Windows ושל Linux.

| Version | Source file | Recorded source SHA-256 | Snapshot check |
|---|---|---|---|
| Original | [Open source](../suites/original/bm_raytrace/run_benchmark.py) | `88ef4d9060d8e8f6ce40f376477aaf89cc808fa44813225a3071a05a1467f017` | **MATCH** |
| V1 | [Open source](<../suites/optimized/bm_raytrace/run_benchmark - First Improvemnt 2x speed.py>) | `35872f2da93b7017c640ccf29dc0836f220581ddbbd4b2041a4ffb5c625b5154` | **MATCH** |
| V2 | [Open source](<../suites/optimized/bm_raytrace/run_benchmark - Second Improvent remove direct function calls and write the math.py>) | `79b0af0a0c8f2f53783ae92bf232626128da14c0b829735a30300cd54d42b34f` | **MATCH** |
| V3 | [Open source](<../suites/optimized/bm_raytrace/run_benchmark - Third improvement - chacing the radious and camera values instead of repeated calcs.py>) | `373cc992befa2630fc74bce65dc9ec1aea297810ee52bbf6cbbce3b2c6bd8d34` | **MATCH** |
| V4 | [Open source](../suites/optimized/bm_raytrace/run_benchmark.py) | `be6eee7feabb67293512738eb68bbc569766a69b817e65ff1c72130ce7f2a432` | **MATCH** |

מסמך התכנון המלא ששימש לפענוח הכוונה של כל שלב: [OPTIMIZATIONS.md](../suites/optimized/bm_raytrace/OPTIMIZATIONS.md).
