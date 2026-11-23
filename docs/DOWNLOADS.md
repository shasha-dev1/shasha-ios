# Downloads for watching offline — iPhone 1.8.0 (NOT device-tested)

Owner's rules: one download at a time; paused while a video streams from the provider and resumed after; Wi‑Fi by
default, mobile data only after an explicit OK (alert in the app, notification action «موافق» in the background).
The IPTV account's stream limit isn't necessarily the file limit; the conservative setting stays until the
provider's policy is known.

## How it works (Sources/Data/Downloads.swift, rules in DownloadRule)
- Resume check before the first piece: `Range: bytes=0-0` (total from Content-Range), then 1 MiB from the middle;
  resumable only if the answer is **206** with exactly that **Content-Range** and exactly 1 MiB arrives
  (`DownloadRule.probe`). Not resumable → the download still runs, and the screen says any interruption restarts it.
- Pieces: background URLSession download tasks with `Range: bytes=<kept>-`. Each answer is checked before bytes are
  added (`DownloadRule.reply`): 206 starting exactly at the kept size (and same total) → appended; 200 → taken as the
  whole file from byte 0 (kept part dropped — never duplicated); other start / total → stopped ("file changed",
  "different position"), nothing added; 4xx/5xx → stopped with the code.
- Interruptions (pause, playback, Wi‑Fi lost, network error): `cancel(byProducingResumeData:)`; the bytes URLSession
  received are recovered from its temporary file (resume-data property list: temp file name + bytes received) and
  appended after the same checks; if they can't be found, they are re-downloaded (logged in the performance report:
  «تنزيل: انقطع — حُفظ ما وصل» or «لم يُسترجع الجزء الأخير»). The partial file and the list (`downloads.json`)
  are in Application Support/Downloads (excluded from backup) and survive app restarts; on launch the kept size is
  read from the file itself.
- Ready = every byte of the announced total is kept (`DownloadRule.isComplete`); then `.part` is renamed. A "done"
  file whose size no longer matches is shown as broken on the next launch.
- Free space: remaining bytes + 1 GB margin, else "المساحة لا تكفي".
- Playback: a film/episode with a complete download plays from the file (same key → resume point, Trakt, Drive sync
  unchanged); its kept subtitle is used without asking Drive first. Downloads screen: Home → ⬇ (reads only the phone).

## Background — what iOS does (Apple's documented behaviour; to be verified on the device)
- App in the background / screen locked: the background URLSession keeps transferring; iOS may slow it (power,
  network). The app is woken to add a finished piece and start the next.
- App swiped away in the app switcher: iOS cancels the app's background transfers and doesn't relaunch it for them.
  What was kept stays; the download goes on the next time the app is opened. No promise of downloading while closed.
- Restart of the phone / app killed by iOS for memory: same as above (kept bytes stay; resumes on open).

## Device tests needed (none done yet)
1. Resume check result on a film and an episode (performance report «تنزيل: فحص الاستكمال»: 206 + Content-Range).
2. Interrupt and resume: start a download, pause at ~30 %, resume; airplane mode mid-way, back on; play a stream
   mid-way (download must pause, then resume after closing the player). Final size must equal the announced total
   (screen shows «جاهز»; report «اكتمل وتحقق الحجم»), and «حُفظ ما وصل» lines show no gap/duplicate.
3. Full episode in airplane mode: play the start, the middle and the end (seek), with the kept subtitle.
4. Background: (a) go to Home screen, (b) lock the screen, (c) swipe the app away — note what happens in each.
5. Wi‑Fi → mobile data: alert in the app; in the background the notification with «موافق».
6. Restart the app during a download: list and progress come back; download continues.
7. Not enough space (large file on a nearly full phone): clear message, nothing deleted.

## 1.8.1 — fix after the first device test (owner, 20:08): pause went back to 0
- Cause: 1.8.0 kept the bytes of a stopped piece through iOS resume data. iOS makes resume data only when the server
  sends ETag / Last-Modified (besides accepting ranges); the provider evidently doesn't → nothing to recover → 0.
- Now, app open: a normal request with "Range: bytes=<kept>-" whose bytes are written to the .part file as they
  arrive (FgLoader), after the answer is checked (206 at exactly the kept size, or 200 = whole file from 0; the file
  is cut at the kept size before writing, so nothing is duplicated). Pause / playback / Wi‑Fi loss / airplane mode /
  network error lose nothing.
- Going to the background: that request stops (bytes kept) and the rest goes on as ONE background download; added when
  it finishes. Stopped before finishing → what it fetched in the background is re-downloaded unless iOS hands it
  back (logged: «إيقاف تنزيل الخلفية — لم يُسترجع … resumeData=لا/نعم»).
- Sizes show "0 KB" (not "Zero KB"); "not enough space" says what is needed and what is free.
