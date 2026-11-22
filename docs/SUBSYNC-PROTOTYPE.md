# Subtitle timing sync — evaluation and standalone prototype (not in the app)

Goal: fix subtitle **timing** (not translation). Nothing is merged into the app yet.

## Existing tools
| | Method | License | iOS fit |
|---|---|---|---|
| ffsubsync | 10 ms speech/no-speech signals from the subtitle (cue on screen) or from audio (VAD: WebRTC, auditok, Silero), FFT cross-correlation, max offset 60 s by default; a reference subtitle can replace the video | MIT | Python + numpy + ffmpeg: not embeddable; the method is simple to re-implement natively (Accelerate vDSP FFT) |
| alass | Dynamic programming that also handles splits (ad breaks, director's cuts) and framerate; split penalty 0–1000, default 7; audio extraction 10–20 s, alignment 5–10 s on desktop | GPL-3.0 | Rust; GPL-3.0 code can't be mixed into this app (LGPL/closed parts). Only the published ideas may be used, no code. |

Decision: our own implementation of the ffsubsync-style correlation (reference subtitle first), plus known framerate
ratios; splits are **detected and reported**, not corrected (a subtitle for another cut should be replaced, not shifted).

## Prototype (`tools/subsync-proto/subsync_proto.py`, run with Python 3 + numpy)
Signals at 10 ms; score = cross-correlation of (2·signal − 1); offset searched within ±60 s for 7 framerate ratios
(1, 25/23.976, 23.976/25, 24/23.976, 23.976/24, 25/24, 24/25); best = highest overlap of target speech with reference
speech; a 4-part check aligns each quarter alone to detect different cuts.
Verdicts: `confident` (overlap > 0.8, clear peak, quarters agree) · `uncertain` · `different_edit` (quarters need
offsets more than 1 s apart) · `no_match` (overlap < 0.6).

Results on synthetic 44-minute files (desktop, ≈0.5 s each, 7 ratios):
| Case | Verdict | Found |
|---|---|---|
| constant +2.50 s | confident | −2.50 s |
| constant −7.30 s | confident | +7.30 s |
| speed 25↔23.976 + 1.2 s | confident | ratio 1.0427, −1.25 s (= −1.2 × 25/23.976) |
| other translation: lines split/merged, ±0.3 s jitter, 15 % missing, +4 s | confident | −3.99 s, overlap 0.95 |
| different edit (scene −40 s at 15 min, +20 s at 30 min) | different_edit | quarters 0 / 40 / 40 / 20 s → not offered as a shift |
| another episode | no_match | overlap 0.50 |
ASS shifting check: only Start/End of `Dialogue:` lines change; styles, `{\an8\c…}` tags, Arabic text and Comment lines
are kept byte for byte.

## Plan for the app (each step separate, measured, opt-in)
1. Reference mode: when the viewer picks «مزامنة مع ترجمة أخرى» and an embedded/other subtitle with good timing exists,
   run the alignment on the phone (Swift + vDSP), show verdict, offset/ratio and overlap, with «تطبيق» and «تراجع».
   Apply = write a shifted copy (original kept), saved per file/version + subtitle (not per series).
   `different_edit` / `no_match` = no apply button; suggest choosing a matching subtitle.
2. Audio mode (no reference): needs speech detection on the audio of the **current playback session** — no second
   connection to the provider. To evaluate: an mpv audio tap (lavfi filter) or a short local buffer, run only when the
   viewer asks, never continuously. Unknown yet: CPU, memory and battery on the iPhone — must be measured before it ships.
3. Measurements to collect on the iPhone: time per run, peak memory, battery drain for a 44-min episode.

Limit: shifting can't fix a subtitle made for another cut or episode; the right fix is a matching subtitle.
FFmpeg being in the app helps with decoding, but auto-sync still needs this development and testing.
