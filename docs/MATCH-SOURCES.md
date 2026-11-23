# External match / broadcaster sources — evaluation (23/11/2026, owner's request 23:39)

Goal: fixtures independent of the provider's EPG + who broadcasts each match, merged with the EPG and manual links.
Every fact keeps its source and time: «مدرجة في جدول الناقل» (official broadcaster) · «مدرجة في دليل نقل خارجي»
(LiveSoccerTV-type guide) · «موجودة في EPG المزوّد» · «نسخة محتملة بلا دليل» (never auto-played, never counted).

| Source | What it gives | Access | Terms / limits found | Status |
|---|---|---|---|---|
| LiveOnSat | matches + channels (satellite), by day/league | static HTML | robots.txt: `Content-Signal: ai-train=no, use=reference`; **ClaudeBot / anthropic-ai disallowed** | Explicit block for our agent → sample discarded, not used. Contact: ljsport@liveonsat.com |
| LiveSoccerTV | per-match broadcaster list for ~200 countries (sample: Brentford–Everton) | HTML; day list loads through `/xloadday.php` which robots.txt **disallows**; match pages allowed | Disclaimer: copying only for **personal use, with the source acknowledged**; no API/licence mentioned; contact form only | Best channel data. Automated use in the app needs written permission (draft below). |
| Sky Sports «Football on Sky» | official UK schedule: kickoff + Sky channel + programme start | HTML, `/watch/` allowed in robots (`/api/` disallowed) | Site terms not yet reviewed | Good official confirmation for Sky; no UHD info. |
| TNT Sports (UK) | official schedule | geo-blocked outside UK («not available in your region») | — | Not reachable from here. |
| TheSportsDB | fixtures by day; TV by day (`eventstv`) | documented JSON API, public key `123` | Free: 30 req/min, **Schedule Day 3 results, Schedule TV 1 result**; full data = $9/month premium | Free tier too small; paid needs owner's approval. |

## Sample (Monday 23/11, LiveSoccerTV + Sky, read once by hand for evaluation)

- Brentford vs Everton — Premier League — 20:00 UK (23:00 Bahrain). Sky: Main Event + Premier League **from 18:30**
  (programme starts 90 min before kickoff → the EPG slot starts early; v2 grouping by overlap keeps one card).
  LiveSoccerTV lists, among ~200 countries: Bahrain/GCC beIN Sports HD 2 · beIN Sports English · beIN CONNECT · TOD;
  UK Sky Sports Main Event · Premier League · Arena; France Canal+ Foot; Spain DAZN / DAZN1 / Movistar+; Germany /
  Austria Sky Sport Premier League; Italy Sky Sport Arena; Greece Nova Sports Premier League; Cyprus Cytavision Sports 3;
  Poland Canal+ Extra 1; Croatia Arena Sport 1; Serbia Arena 1 Premium; Turkey beIN Sports 3; Portugal DAZN1;
  Netherlands Viaplay; Norway V Sport Premier League; Sweden V Sport Premium; USA USA Network; Mexico TNT Sports.
  **No UHD channel is named by either source** → Sky Sports UHD / TNT UHD stay «نسخة محتملة بلا دليل».
- Conflict example: Wieczysta–Motor (Ekstraklasa): EPG programme 20:00 Bahrain on Arena Sport 1/2; LiveSoccerTV kickoff
  13:00 New York = 21:00 Bahrain. Handling: the external kickoff is the match time; the EPG programme joins the card by
  overlap and is shown with its own time ("programme from 20:00"); neither is overwritten.
- Tuesday 24/11 Sky lists 19 matches, incl. EFL Trophy with U21 sides (Leeds United U21…) → age group kept in the team
  key, never merged with the senior team.
- The LiveSoccerTV day page served to us lists 26 matches only (US-centred, rest via the disallowed loader) — not a full
  day; per-match pages are complete.

## Next (pending owner decision)

1. Send the permission requests (owner sends; texts in the reply of 23/11).
2. Build now, source-independent: the merge model with provenance + time, manual links saved on device
   (add a channel to a match / remove a wrong link), and the four labels on both apps.
3. Plug a source in only after its permission (or a paid plan the owner approves).
