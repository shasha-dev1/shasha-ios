# شاشة — iPhone

The iPhone version of Shasha (Arabic, right-to-left). SwiftUI + mpv (MPVKit: libmpv + FFmpeg + libplacebo + libass, LGPL). Plays live MPEG-TS, MKV, Dolby Vision, AC-3/E-AC-3, ASS subtitles, picture in picture. VLC was removed in 1.0.0 (last VLC version: branch `vlc-engine`).

## Build (no Mac needed)
Every push to `main` runs **GitHub Actions** (`.github/workflows/build.yml`) on a macOS runner:
the patched libmpv is built (`scripts/build-libmpv.sh`, cached) → `scripts/vendor-mpvkit.sh` makes `vendor/MPVKit` → XcodeGen generates the project → `xcodebuild` builds an **unsigned** app → `Shasha-unsigned.ipa`.

Download: repository → **Actions** → latest "Build IPA" run → **Artifacts** → `Shasha-unsigned-ipa` (a zip containing the IPA). Sign it with your own tool/certificate.

A short build summary (result + errors) is pushed to the `ci-logs` branch (`ci-summary.txt`).

## Features (0.1)
- Add an Xtream account (checked against the server; password in the Keychain) or an M3U link; several playlists.
- Live TV: groups, favourites (swipe / long press), search, channel up/down in the player.
- Movies: continue watching, categories, newest first, details (plot, genre, year), resume.
- Series: recently updated first, seasons/episodes, resume next episode.
- Live: now-playing programme and progress on each channel (Xtream short EPG), shown in the player too.
- Movies/Series: sort (newest / top rated / A–Z), "my list" (☆ on the details page, filter in the sort menu).
- Player: mpv, audio/subtitle track menu, ±10 s buttons and double tap, seek bar, picture shape (fit / fill / 16:9 / 4:3), speed, screen stays awake, retry button when a stream drops (no automatic reconnect loop).
- About: credit line comes from the `SHASHA_CREDIT` Actions secret at build time (not stored in the source).
