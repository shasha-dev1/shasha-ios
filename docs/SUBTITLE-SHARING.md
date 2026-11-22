# Subtitles shared between the iPhone and the TV (iPhone 1.7.5, TV 0.9.18) — not device-tested

Owner's decisions: a subtitle that arrives from the other device is turned on automatically (unless subtitles are off
for that series); old files must not pile up.

- Each subtitle downloaded from the internet (OpenSubtitles etc.) is kept for that film/episode on the device and
  uploaded to Google Drive as its own file. The sync file `shasha-sync-v1.json` (format v1) is not changed.
- Name: `shasha-sub-v1-<first 24 hex of SHA-256(key)>.srt`, key = `account|kind|id` (same as the sync entries).
  Test vectors (both apps): `0123456789abcdef|movie|12345` → `shasha-sub-v1-200a02eb8884dc7d433f9fe5.srt`,
  `0123456789abcdef|ep|987654` → `shasha-sub-v1-b89e90fd6ac239417f88da25.srt`.
- Drive `appProperties`: `shashaSub=1` (used to list them), `lang`, `label` (clipped to fit Drive's 124-byte limit).
- Opening a film/episode: the device's own kept file, else one Drive lookup by name → download → keep → turn on once
  the player has loaded the video. No call to the subtitle sites (no quota used).
- Retention (`SubSyncRule.prune` / `SubSyncCore.prune`): files not updated for 30 days go, and at most 150 are kept
  (oldest first). Drive: checked at most once a day after an upload. Local: on each keep/fetch.
- Not shared yet: the subtitle delay/offset and the TV's speed ratio (the apps adjust them differently); a later stage.
- Logged in the performance report (iPhone): «ترجمة: رفع إلى Drive», «ترجمة: من الجهاز الآخر», failures, clean-up.

## مزامنة الترجمات — الحالة الفعلية في آيفون 1.7.5 / تلفزيون 0.9.18 (من الكود، **غير مجرّبة على الأجهزة**)

لا شيء من الحذف أو التفعيل التلقائي أو الجلب من الجهاز الآخر مجرَّب على جهاز حتى الآن. النجاح الوحيد المثبت: البناء
(آيفون #118) والاختبارات (تلفزيون 209، ومنطق الآيفون في CI). يُعتمد هذا التسليم كما هو، والنواقص أدناه للدفعة القادمة.

### 1) هوية الترجمة
- الهوية الحالية = `الحساب|النوع|الرقم` (نفس مفتاح نقاط التوقف): **العمل والحلقة نعم**، و«الرقم» هو رقم البث عند
  المزوّد، فنسختان من نفس الفيلم برقمين مختلفين = هويتان مختلفتين (أي أنها لكل نسخة عند المزوّد، لا لكل عمل).
- **ليست** جزءًا من الهوية: اللغة، ونسخة الفيديو الفعلية (لو تغيّر الملف خلف نفس الرقم)، وبصمة ملف الترجمة.
- النتيجة: ترجمة واحدة فقط لكل فيلم/حلقة؛ تنزيل ترجمة أخرى (أي لغة) **يستبدل** السابقة في Drive وعلى الجهاز.
- لا توجد بصمة (hash) لمحتوى الترجمة، ولا مقارنة محتوى قبل الاستبدال.

### 2) آخر استخدام بين الأجهزة، والحذف
- Drive: الحذف حسب `modifiedTime` في Drive، وهذا يتغير **فقط عند الرفع**. فتح الترجمة على الجهاز الآخر **لا يحدّث**
  أي شيء في Drive.
- لذلك: ترجمة رُفعت قبل أكثر من 30 يومًا وتُستخدم يوميًا على الجهاز الآخر **قد تُحذف من Drive** في التنظيف اليومي
  (أو إذا تجاوز العدد 150). النسخة المحلية على الجهاز الذي يستخدمها تبقى (تُحسب محليًا بآخر استخدام فعلي على ذلك
  الجهاز)، لكن أي جهاز ثالث/إعادة تثبيت لن يجدها.
- الحذف يعتمد على قائمة Drive نفسها (وقت خادم Google)، لا على بيانات الجهاز المحلية، فجهاز «ببيانات قديمة» لا يحذف
  بناءً على ذاكرته. **لكن لا توجد حماية** لترجمة مستخدمة حديثًا على جهاز آخر (لأن الاستخدام لا يُسجَّل في Drive).
- نافذة سباق صغيرة: جهاز يقرأ القائمة ثم يحذف بالمعرّف؛ لو رفع الجهاز الآخر نفس الملف بين الخطوتين يُحذف الملف المحدَّث.
- المطلوب لاحقًا: تسجيل «آخر استخدام» في Drive عند الاستخدام (حقل في appProperties بتحديث خفيف، مرة يوميًا على الأكثر)،
  والحذف حسب الأحدث بين الرفع وآخر استخدام، وإعادة قراءة وقت الملف قبل حذفه مباشرة.

### 3) احترام «بدون ترجمة»
- الآيفون: الإيقاف المحفوظ موجود **للمسلسلات فقط** (تفضيل لكل مسلسل). عند فتح حلقة من مسلسل إيقافه محفوظ، لا تُجلب
  الترجمة المحفوظة ولا تُفعَّل.
- **ثغرة — الأفلام على الآيفون:** إيقاف الترجمة أثناء فيلم لا يُحفظ، فالترجمة المحفوظة لذلك الفيلم **ستُفعَّل تلقائيًا**
  في الفتح التالي. يجب إصلاحه قبل اعتبار السلوك محترمًا.
- **ثغرة — الإيقاف لا ينتقل بين الأجهزة:** «إيقاف» على التلفزيون يحذف نسخته ويمنع جلبها له فقط؛ نسخة Drive تبقى،
  فالآيفون **سيفعّلها**. والعكس كذلك.
- تنزيل ترجمة جديدة يدويًا = طلب صريح من المستخدم، فيُفعّلها في نفس التشغيل. على التلفزيون يلغي ذلك إيقاف تلك الحلقة.
  على الآيفون لا يلغي إيقاف المسلسل، فتلك الترجمة لن تعود تلقائيًا في الفتح التالي لنفس الحلقة (سلوك غير متّسق).
- المطلوب لاحقًا: إيقاف محفوظ لكل فيلم/حلقة على الآيفون، وعلامة «إيقاف» تنتقل عبر Drive (مثلًا في appProperties)
  يحترمها الجهازان، وقاعدة واحدة موثّقة: لا تفعيل تلقائي بعد إيقاف صريح إلا بتنزيل/اختيار يدوي جديد.

### 4) سلامة الملف ونجاح الإضافة قبل إعلان النجاح
- التلفزيون: الملف القادم من Drive يُحلَّل أولًا، ولا يُفعَّل ولا تظهر رسالة النجاح إلا إذا خرج بسطور صالحة. الرفع يُعتبر
  ناجحًا عند ردّ 200 فقط، وفشله **صامت** (بدون رسالة للمستخدم).
- الآيفون: الملف القادم من Drive يُقبل إذا لم يكن فارغًا فقط (**بدون تحليل**). الإضافة إلى mpv غير متزامنة، ورسالة
  «تمت إضافة الترجمة» تظهر **قبل** التأكد من ظهور مسار الترجمة؛ فشل الأمر يُسجَّل في التشخيص فقط. الرفع يُسجَّل
  في تقرير الأداء (نجاح عند 200 / فشل).
- لا حد لحجم ملف الترجمة عند الجلب، ولا فحص للترميز: ملف من OpenSubtitles بترميز غير UTF-8 (مثل Windows-1256)
  قد يظهر مشوّهًا على التلفزيون لأنه يقرأه كـUTF-8.
- لا تحقق بعد الرفع بقراءة الملف من Drive (بعكس ملف نقاط التوقف).
- المطلوب لاحقًا: تحليل الملف وحد للحجم قبل القبول على الجهازين، وتوحيد الترميز إلى UTF-8 قبل الرفع، وإعلان النجاح
  على الآيفون فقط بعد ظهور المسار فعلًا في قائمة mpv، ورسالة واضحة عند فشل الرفع.

### ترتيب الدفعة القادمة المقترح (أخطاء وحفظ بيانات أولًا)
1. إيقاف الأفلام على الآيفون + علامة الإيقاف عبر Drive.
2. التحقق من الملف والإضافة قبل رسالة النجاح، وحد الحجم والترميز.
3. آخر استخدام في Drive وحماية الحذف.
4. ثم: هوية تشمل اللغة وبصمة الملف (عدة ترجمات لكل حلقة)، وإدارة الترجمات، واستيراد/تصدير ASS/SRT، والتأخير لكل
   ترجمة ونسخة فيديو.

## مصدر sub-scene.com — فُحص ولم يُدمج (23:05)
- الفحص: لا توجد واجهة برمجة (API). صفحة الترجمة `/subtitle/{id}` وزر التنزيل `/download/{id}`، ويظهر فيها: اللغة،
  اسم الإصدار، FPS، الرافع، ونوع الترجمة. robots.txt يسمح بالزحف، لكن **شروط الاستخدام تمنع صراحة استخدام السكربتات
  والبوتات للوصول للموقع، وتمنع نسخ المحتوى أو استخدامه بدون إذن** (القسمان 4 و5)، ويحق لهم إيقاف الوصول (القسم 8).
- Subscene الأصلي أُغلق في مايو 2024، ومستخدمون في منتديات Emby وصفوا sub-scene.com بأنه نسخة مقلّدة. لا توجد جهة
  قانونية مسمّاة في الشروط.
- القرار: **لا دمج آلي** (بحث وتنزيل من داخل التطبيق = وصول آلي تمنعه الشروط). لا زر يوحي بأنه مصدر مدمج.
- البديل المطلوب (غير منفّذ بعد): تنزيل يدوي من المتصفح ثم «استيراد ملف ترجمة» يمرّ بنفس الحفظ المحلي ومزامنة Drive:
  - الآيفون: المستورد حاليًا يُضاف للتشغيل الحالي فقط (نسخة مؤقتة). المطلوب: فحص (نص، يحتوي `-->` أو `[Script Info]`،
    حد حجم 2 MB، ترميز UTF-8 أو Windows-1256 → UTF-8)، ثم `SubShare.keep`، وإعلان النجاح بعد ظهور المسار في mpv.
    ملفات zip: تطبيق «الملفات» يفكّها؛ فك الأرشيف داخل التطبيق (حدود حجم ومسارات، واختيار الحلقة) بند منفصل.
  - التلفزيون: لا يوجد استيراد؛ الأسهل أن يستلم الترجمة المستوردة من الآيفون عبر Drive. ملفات ASS تحتاج دعم قراءة في
    `SubtitleCore` (حاليًا SRT فقط).
- تنويع مصادر بشكل مسموح: التلفزيون فيه OpenSubtitles وSubDL (واجهات رسمية بمفتاح المستخدم)؛ الآيفون فيه OpenSubtitles
  فقط → إضافة SubDL للآيفون بمفتاح المستخدم هو التنويع المقترح. يحتاج فحص شروط SubDL الحالية قبل التنفيذ.
- الإثبات المطلوب من المالك لأي من ذلك: بحث فعلي، تنزيل فيلم وحلقة، ظهورها في المشغّل، ثم انتقالها للجهاز الثاني.

## 1.7.6 (iPhone) / 0.9.19 (TV) — import, checks, confirmation, "off" for films (not device-tested)
- Import from Files: size checked before reading, then content (`SubFileCheck`): SRT or ASS/SSA by content, UTF-8 /
  UTF-16 (BOM) / Windows-1256 → kept as UTF-8 (ASS styles and tags unchanged). Limits: SRT 8 MB, ASS 40 MB (embedded
  fonts). WebVTT and archives are refused with the reason (unzip in the Files app first).
- Imported and downloaded subtitles take one path: check → add to mpv → success only when mpv lists a new subtitle
  track and it is selected (5 s) → then kept for the film/episode and shared through Drive. Whether the text shows
  still needs a scene with dialogue.
- Kept copy uses the real extension (.srt / .ass); the Drive name keeps `.srt` (identity) with appProperties `fmt`.
  Files from Drive are checked the same way before use.
- "No subtitles" is now kept per film/episode too (series keep their preference); a kept/shared subtitle is not
  brought back for that item; choosing or adding a subtitle lifts it.
- TV: ASS from the iPhone → a clear "not supported on the TV" message (once per item), nothing turned on.
- Still open: identity has no language / file hash (one subtitle per item); "off" not shared between devices; Drive
  "last used" not recorded; zip/archives inside the app; SubDL on the iPhone; ASS on the TV.

## 1.7.7 (iPhone) / 0.9.20 (TV) — last use and "off" shared through Drive (not device-tested)
- appProperties gain `used` (ms of last use, written at most once a day by the device that uses the subtitle) and
  `off` ("1" after "no subtitles" for that film/episode on any device; a new download/import sets "0").
- Opening a film/episode (when linked): one Drive lookup first. `off=1` → not turned on (even if a copy is kept
  locally). Drive unreachable → the local copy is used as before.
- Clean-up goes by the later of last upload and last use, and reads each file again right before deleting it; a
  file used or replaced since the list is skipped.

## 1.7.8 (iPhone) — subtitle delay kept per subtitle and video version (local only; not device-tested)
- Key = film/episode copy (provider id = video version) + subtitle identity: an added file by the SHA-256 of its
  content, an embedded track by its number and language (`SubDelayRule`). Stored on the phone (`subs.delay`), at most
  500 entries (oldest use dropped). Applied when that subtitle is selected/added or first selected after loading.
- «الأصلي» resets to 0 and removes the kept value. Not shared with the TV.
