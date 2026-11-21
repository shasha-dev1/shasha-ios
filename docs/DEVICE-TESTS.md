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

## 1.0.4 (built only, not tested on device)
- An empty movies/series list where the playlist had titles is treated as a failed reply (keeps the saved list, says «غالبًا مؤقت»); timings of background work are now taken inside the background task.
- Saved copy per playlist (Application Support/LibraryCache/<id>.json, excluded from backup, protected until first unlock; Xtream links not stored — rebuilt from the Keychain). Launch shows the saved copy, then refreshes in the background; a failed refresh keeps the shown lists and says so with retry and the time of the last good download. Saved only after a good download. Settings shows «آخر تحديث ناجح»; «تحديث القائمة الآن» is the manual refresh.
- Movies/series: a request that fails (network, or a reply that is not a JSON array) is shown as «تعذّر جلب …» with retry and keeps the previous list; «لا توجد أفلام» only when the provider sent an empty array.
- Leaving the player measured part by part: save resume, stop playback, rotate, first frame, screens redrawing, mpv destroy (still on the main thread — not moved).
- Report starts with a summary of the last launch: network / background processing / main-thread work / stalls.
