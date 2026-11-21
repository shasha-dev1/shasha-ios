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
