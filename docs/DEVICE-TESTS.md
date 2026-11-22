# Device test log (iPhone)

Only results reported by the owner from his own iPhone are recorded here. A successful CI build is not a device test.

| Version (CI build) | Commit | Date | Reported working on device | Not reported yet |
|---|---|---|---|---|
| 1.0.0 (57) | `08868a7` | 2026-11-21 | Colours (incl. Dolby Vision), subtitles, picture in picture | Live channels, resume / next episode, audio switching, Apple player hand-off, Control Center |
| 0.9.9 (56) | `6167ba8` | 2026-11-21 | All tests of that round: repeated PiP, PiP on live, Dolby Vision PiP with correct colours and Arabic subtitles (last version with VLC, branch `vlc-engine`) | — |

Build 58 (`000e2cb`) has the same app code as build 57 (only README changed); the owner tested build 57.

## Playback settings proven on device (keep unless a test proves otherwise)
- Normal output: `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`, `hwdec=videotoolbox`.
- Subtitles: bundled Noto Sans Arabic through `sub-fonts-dir` / `sub-font` (libass has no CoreText provider here).
- PiP: output switched `vo=null` → `wid` → `vo=avfoundation` and back; a new sample-buffer layer + controller per session.
- Dolby Vision in PiP only: `hwdec=videotoolbox-copy` + `vf=libplacebo=w=1280:h=720:...:format=nv12:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv`.

## 1.0.1 (built only, not tested on device)
- Every async mpv write (property or command) now has a reply id; failures from `MPV_EVENT_SET_PROPERTY_REPLY` / `MPV_EVENT_COMMAND_REPLY` (`mpv_event.error < 0`, per mpv 0.41 `client.h`) are written to the session log as `[خطأ أمر]`. Commands log only their name (`loadfile` carries the link).
- A failed `vo`/`wid` write of the current PiP switch ends that attempt at once (before: seen only as the 4 s timeout). Failed DV filter / hwdec writes are logged, not fatal. Late replies from an older switch are ignored.
- Old PiP start attempts are cancelled on a new start, on stop of the window, on opening another item and on leaving the player, including the delayed retry; an output switched for an attempt that never became a window is switched back.
- No mpv playback option changed.

## 1.0.2 — performance measurements (baseline, no behaviour change; built only)
Settings → «قياسات الأداء». Records (step names and counts only, no links): launch → first screen and → library ready
(kernel process start time), each Xtream request (network time + size, JSON parse, conversion), whole library load with
counts, Home shelves and search, Movies/Series list filter+sort, channel list filter, series detail open → episodes shown,
return from the player (until the next frame), and every frame longer than 50 ms attributed to the step running.
Device model, iOS version and memory footprint are in the report. The log survives restarts (Caches/perf.log).

## 1.0.2 baseline — owner's report, 2026-11-21
Device iPhone14,3, iOS 27.2.1. Library: 52,989 channels, 0 movies, 24,103 series; groups 826/181/214. Memory 557 MB.
- Launch → first screen 809 ms; → library ready 5,964 ms (network: get_series 4.2 s / 36.7 MB, get_live_streams 3.2 s / 19.6 MB; JSON parse 546 + 163 ms and conversion 343 ms already off the main thread).
- Return from the player: stalls of 883 and 914 ms; the measured list computations were only ~70 ms of that.
- Series detail: a 285 ms stall on opening (before the network), 817 ms after the episodes arrived; open → episodes shown 450 ms (3 episodes) and 1,605 ms (123 episodes, network 1.36 s).
- Browsing: 15 frames > 50 ms, longest 764 ms. Home + series list recomputed 2–3 times per navigation (4–30 ms each).

## 1.0.3 — CI build 63 = commit `73fc915` (built only, not tested on device)
- Library index built once per load off the main thread: folded search names (Arabic variants, case, accents), the three sort orders, copy groups, id → position.
- Movies/Series lists and Home search run off the main thread when their inputs change (200 ms pause while typing); a newer request cancels the older, which can't overwrite it; grids add posters 90 at a time while scrolling.
- Series/movie "other copies" from the index (was CopyRule.key over all 24,103 series on every redraw — the likely cause of the opening stall).
- Channel list recomputed only when search/library/favourites change (was on every guide update); favourites looked up by id.
- Library load: a second request for the same playlist joins the running one; switching playlist cancels the old load and drops its results; all lists published in one update.
- Bounded image cache (40 MB memory / 200 MB disk).
- Measurement added: time of closing mpv (to check whether it causes the stall when leaving the player). No mpv playback setting changed.

## 1.0.3 (63) — owner's report, 2026-11-22 (same steps as 1.0.2)
Library this time: 52,989 channels, **56,207 movies** (1.0.2 got "[]" for get_vod_streams in 0.5 s — a bad reply, not a real empty list), 24,103 series. Memory 852 MB.

| Step | 1.0.2 | 1.0.3 |
|---|---|---|
| Launch → first screen | 809 ms | 485–497 ms |
| Launch → library ready | 5,964 ms (no movies) | 11,151 ms (with 56k movies) |
| — longest network request | get_series 4.2 s | get_vod_streams 8.5 s / 23 MB |
| — background processing | parse 0.7 s + convert 0.4 s | parse 0.9 s + convert 0.7 s + index 1.4 s (shown as «واجهة» by a labelling mistake: it ran off the main thread) |
| Return from player, stall | 883, 914 ms | 309, 333, 603 ms |
| Series open → episodes, minus network | ~240 ms | ~30 ms |
| Longest browsing stall | 764 ms | 302 ms (still 42 frames > 50 ms) |
| Home shelves / series list on main thread | 4–30 ms, 2–3× per navigation | < 4 ms (not logged) / 8 ms off main |

## 1.0.4 — CI build 65 = commit `b9258b8` (built only, not tested on device)
- An empty movies/series list where the playlist had titles is treated as a failed reply (keeps the saved list, says «غالبًا مؤقت»); timings of background work are now taken inside the background task.
- Saved copy per playlist (Application Support/LibraryCache/<id>.json, excluded from backup, protected until first unlock; Xtream links not stored — rebuilt from the Keychain). Launch shows the saved copy, then refreshes in the background; a failed refresh keeps the shown lists and says so with retry and the time of the last good download. Saved only after a good download. Settings shows «آخر تحديث ناجح»; «تحديث القائمة الآن» is the manual refresh.
- Movies/series: a request that fails (network, or a reply that is not a JSON array) is shown as «تعذّر جلب …» with retry and keeps the previous list; «لا توجد أفلام» only when the provider sent an empty array.
- Leaving the player measured part by part: save resume, stop playback, rotate, first frame, screens redrawing, mpv destroy (still on the main thread — not moved).
- Report starts with a summary of the last launch: network / background processing / main-thread work / stalls.

## 1.0.5 — CI build 66 = commit `1e00fa0` (built only; superseded by 1.0.6 before install)
- Memory measured at named points (footprint now + kernel peak since launch): before/after loading the saved copy, before the provider load, after network+parse+convert, after index+publish, steady 5 s / 20 s later, player open / 3 s after closing, series detail open, every 450 posters scrolled; iOS memory warnings logged. Instruments isn't available without a Mac, so this in-app sampling (same number as Xcode's gauge, `phys_footprint`) is the measuring tool.
- Frame smoothness per step as a ratio (slow = longer than 25 ms), e.g. «تمرير الأفلام».
- Saved copy timed in parts inside the background task (read file, JSON, convert, index) and the main-thread publish separately, plus read-start → on screen.
- Images decoded at display size with a 60 MB / 600-image memory cache emptied on memory warnings; off/on switch in «قياسات الأداء» for an A/B on the same build.
- Empty reply after a full list: state «emptyReply», saved list kept with a notice «المعروض نسخة محفوظة لم يتأكد تحديثها», retry, and «القائمة فعلًا فارغة» (with confirmation) to accept it.
- Saved copy keyed by playlist id + SHA-256 of type/server/user name (no password); stale results still dropped after a playlist switch.

## 1.0.4 (65) — owner's report, 2026-11-22 (first launch only; the relaunch from the saved copy was not in this report)
- No saved copy yet: provider load 7.3 s (longest request get_series 5.1 s), launch → updated 7.9 s; index 1.4 s and saving 2.1 s, both off the main thread.
- Leaving the player, by part: save resume 0–1 ms, stop 0 ms, rotate request 0 ms, first frame 10–198 ms; the 605 ms stall came after that («تحديث الشاشات»).
- **No «mpv: إغلاق المحرّك» line in 3 player closes** → mpv's destroy never ran: the player model / mpv engine were apparently not released (possible leak, and a memory suspect). Not proven yet.
- The 1.0.4 summary counted whole operations (e.g. the 7.3 s load) as main-thread work — fixed in 1.0.6 («مدة» tag).

## 1.0.6 — CI build 67 = commit `67c7d96`
- Live counts of player models and mpv engines logged on create/release and 3 s after leaving the player.
- Rotation back to portrait timed until it completes; stalls after it are attributed to «إعادة رسم بعد الدوران».
- Whole-operation durations tagged «مدة» and excluded from main-thread work in the summary.

## 1.0.6 (67) — owner's report, 2026-11-22
- **Saved copy:** read 13 ms (33.9 MB file), JSON 388 ms, convert 467 ms, index 1,435 ms — all in the background; publish on the main thread 0 ms; read → on screen 2.35 s; launch → saved library shown 2.6 s (vs 19.1 s to the provider's update this time: get_series took 14.2 s). One 286 ms stall right after it appeared. Memory 19 MB before → 230 MB with the saved library shown.
- **Proven leak:** player models / mpv engines alive after each close: 1, 2, 3, 4, 5, 6 (never released; mpv destroy never ran). Memory 3 s after each close: 464 → 579 → 619 → 673 → 827 → 965 MB.
- **Refresh peak:** 1,002 MB after network+parse+convert (saved lists + JSON + new lists together), peak 1,147 MB; 394 MB 20 s later. Peak 1,538 MB later in the session (with the leaked players).
- 2,101 ms stall right after the refreshed library replaced the saved one.
- Scrolling (display-size images): movies 3.0 % slow frames (longest 173 ms), series 2.0 % (longest 305 ms). No A/B with images off yet.
- Return: save/stop/rotate ≈ 0 ms; 400–617 ms stall before the rotation, rotation itself 139–327 ms.

## 1.0.7 — CI build 68 = commit `beaf73b` (built only, not tested on device)
- Leak fix: the screen's PiP-message closure stored in the player model captured the screen, which owns the model — cleared on leaving the player.
- Replaced lists released on a background thread after a refresh; publish timed and the frames after it named «بعد نشر المكتبة المحدّثة».

## Overnight builds 2026-11-22 (all built by CI, none tested on the device yet)
| Version | CI build | Commit | What |
|---|---|---|---|
| 1.0.8 | 70 | `a4334e2` | Big lists parsed+converted one at a time in autorelease pools (lower refresh peak; memory logged after each JSON is freed). TmdbRule (unit-tested) + TMDB client with the viewer's own key; Settings key save+test. New movie/series detail pages: backdrop header, letter placeholder, expandable overview (provider first, TMDB fallback), clear play/resume, season chips, episode rows (progress, current, watched), retry when episodes fail. |
| 1.0.9 | 71 | `8b8cb0f` | New Home: resume hero, «متابعة المشاهدة», «المفضلة» (channels + my list), «أضيف حديثًا»; TMDB trending/popular rows with «في مكتبتك» / «غير متوفر» (no play button for titles not in the library). |
| 1.1.0 | 72 | `6d1d1da` | Settings sections (المصادر، التشغيل، الصوت والترجمة، TMDB، المظهر، التخزين، التشخيص)، poster size، storage sizes + clearing، live search over all channels، visible sort and counts. |

### Test list for the owner (1.1.0)
1. Install over the old app with the same certificate; resume points, favourites and groups must still be there.
2. Open twice (second open = from the saved copy): «قياسات الأداء» → copy the report.
3. Play / leave the player 3 times: the report should say «نماذج المشغّل الحية 0 · محركات mpv 0» after each return, and show «mpv: إغلاق المحرّك».
4. Picture in picture twice, on a film and a live channel; Rings of Power colours and Arabic subtitles (must be unchanged).
5. Settings → TMDB: paste your key → «حفظ واختبار» must say «المفتاح يعمل». Then a film and a series page: backdrop, overview; Home: trending rows with «في مكتبتك» / «غير متوفر»; tapping «غير متوفر» opens info only.
6. Series page: seasons, current episode, progress, watched mark.
7. Live: search from the groups screen; favourites.
8. Settings → التخزين: sizes; «مسح الصور المؤقتة».

## 1.1.0 (73) — owner's report, 2026-11-22 13:07
- **Leak fixed (verified):** after every return «نماذج المشغّل الحية 0 · محركات mpv 0»; mpv destroy 1–5 ms → **mpv destroy is not the return stall**. Memory 3 s after closes: 330, 413, 358, 556 MB (no steady climb).
- Return stall still 614–647 ms after the first frame, before the rotation completes; opening the player also stalls 438–538 ms.
- Refresh: memory after each JSON freed 599 → 641 → 602 MB (1st refresh, with the saved copy still in memory), 293 → 364 → 376 MB (2nd). Peak rose 792 → 997 MB while the library was being SAVED (one JSON encode of everything). Peak 1,311 MB later, during playback (cause not measured).
- 2,279 ms stall after the refreshed library was published. Found in code: the Movies/Series screens rebuilt a dictionary of ALL films / series on the main thread on every redraw (continue-watching helper), unmeasured until now.
- Scrolling: movies 0.8 % slow frames (was 3.0 % in 1.0.6), series stalls ≤ 113 ms.
- A 9,956 ms "stall" in browsing: most likely the app was inactive (frames stop) — not counted any more.

## 1.1.1 — CI build 74 = commit `541a62a` (built only)
- Continue-watching on Movies/Series from the index (no full dictionaries per redraw), measured.
- Saved library written and read part by part (format 2; old file ignored → one refresh).
- Frame gaps while the app is inactive are ignored; memory sampled 30 s and 90 s into playback.

## 1.2.0 (built only) — Trakt, shared with the TV app
- Settings → Trakt: the viewer's own Client ID / Secret (same Trakt app as the TV), device-code sign-in (code + trakt.tv/activate, polling with Trakt's codes), username shown, «مزامنة الآن», log (no tokens), disconnect (revoke + local tokens and pauses removed). Keys/tokens in the Keychain only.
- Scrobbling: films and episodes only (never live): start when playback runs, pause on the viewer's pause, on leaving pause (< 95 %) or stop (≥ 95 %, same rule as the app and the TV). Identity = title + year (+ TMDB id when a TMDB key is set). Unit-tested rules (TraktRule).
- Pull: /sync/playback at launch, when the app returns to the front (≤ every 2 min) and on demand. A pause from another device wins only when this phone has no position or the pause is newer than the phone's own save (TraktResumeRule, tested); playback then starts at that percentage. Home «متابعة المشاهدة» merges those titles («تكملة من جهاز آخر»); a series page points at the episode paused on the TV.
- Local positions now carry a save time (needed for the comparison); positions saved before 1.2.0 are kept as they are.

## 1.4.1 — Arabic machine translation of descriptions (built only, not tested on device)
- When a description has no Arabic text (no Arabic TMDB overview, or the provider's plot is in another language), the phone translates it on the device with Apple's Translation framework (iOS 18+). Nothing is sent anywhere by the app.
- Source language detected on the device (NaturalLanguage, confidence ≥ 0.6); unsure or unsupported pair → the original stays, with no prompt.
- First use: the system asks to download the language. If the viewer dismisses it, no more automatic prompts until the app restarts; a «ترجم» button retries.
- Labelled «ترجمة آلية على الجهاز», with «النص الأصلي» to switch back. Switch in Settings → TMDB (on by default, like the TV app).
- Timing goes to the diagnostics report as «ترجمة آلية».
- To test: open a film whose summary is English → Arabic text + label; tap «النص الأصلي»; turn the switch off → English.

## 1.4.2 — episode descriptions (built only, not tested on device)
- Cause: the phone showed only the provider's episode plot, and most providers send it empty. The TV app already used TMDB per season; the phone did not.
- Now: when the series is matched on TMDB, the selected season's episodes take TMDB's name, overview and still image where the provider has none (Arabic first, English per episode when Arabic is missing). GET /tv/{id}/season/{n}, kept in memory for the run.
- English overviews are machine-translated on the device in one batch per season (iOS 18+, same switch), labelled «ترجمة آلية».
- Needs a TMDB key in Settings. Timings: «TMDB حلقات الموسم», «ترجمة آلية (حلقات)».
