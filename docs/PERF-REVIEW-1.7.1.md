# Performance review from code (1.7.1) — causes to confirm with the next device report

Latest device numbers (1.1.0 report): return stall ≈ 600–650 ms after the player's first frame and before the rotation to
portrait completes (mpv destroy 1–5 ms, not the cause); opening the player stalls ≈ 440–540 ms; memory peak ≈ 997 MB during
a library refresh and ≈ 1,311 MB during playback. 56k films / 24k series.

## Return / open stall — likely causes seen in the code
1. **All tabs stay mounted under the player.** `RootView` draws the player as an overlay on top of the TabView (needed so
   the player survives in PiP). Every rotation (landscape on open, portrait on close) re-lays out Home, the Movies grid and
   the Series grid behind it — a `LazyVGrid` changing width rebuilds its rows and poster cells. This matches "after the
   first frame, before the rotation completes".
   → **A/B in 1.7.1, off by default**: Settings → diagnostics → «تجميد الشاشات خلف المشغّل». While the full-screen player
   is up, the screens keep their portrait size. Compare «رجوع: …», «اكتمال الدوران» and «فتح المشغّل» with it off and on.
   The report logs which state each player opening used («A/B: تجميد الشاشات خلف المشغّل»).
2. **Three screens recomputed on opening the player.** Home, Movies and Series each did `tick += 1` when `play` changed —
   on open as well as close — re-running Continue watching, favourites, recently added and grid bodies under the player
   while it starts. → **Changed in 1.7.1**: only on close. Expected effect: smaller «فتح المشغّل» stall; the return
   path is unchanged by this.
3. Closing still recomputes those three screens at once (to refresh Continue watching). If the A/B shows the rotation is
   not the main cost, the next step is to refresh only the visible tab and the others when they appear.

## Playback memory — what is known
- mpv network cache is set to 150 MiB ahead (`demuxer-max-bytes`, part of the working player settings — not changed);
  mpv's own default keeps up to 50 MiB behind. Decoder and GPU surfaces for 4K/HDR come on top.
- The library itself (arrays, folded search names, index, copy keys) is in memory all the time; its size is the
  refresh peak's base.
- **New in 1.7.1**: at 30 s and 90 s of playback the report also logs mpv's cache («ذاكرة: كاش mpv …»: ahead / total MB),
  so the next report separates mpv's share from the app's. Any change to mpv's cache needs that number first and the
  owner's agreement (working player settings are frozen).

## Refresh peak
Already lowered earlier (sectioned cache save, serial parse in an autorelease pool). Remaining suspects for the next
report: old and new lists held together until the new index is published (see `OldLists`), and the folded search
strings built for every title during `LibraryIndex.build`.
