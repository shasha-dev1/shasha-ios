# External match / broadcaster sources — evaluation (23/11/2026, owner's request 23:39)

Goal: fixtures independent of the provider's EPG + who broadcasts each match, merged with the EPG and manual links.
Every fact keeps its source and time: «مدرجة في جدول الناقل» (official broadcaster) · «مدرجة في دليل نقل خارجي»
(LiveSoccerTV-type guide) · «موجودة في EPG المزوّد» · «نسخة محتملة بلا دليل» (never auto-played, never counted).

| Source | What it gives | Access | Terms / limits found | Status |
|---|---|---|---|---|
| LiveOnSat | matches + channels (satellite), by day/league | static HTML | robots.txt: `Content-Signal: ai-train=no, use=reference`; **ClaudeBot / anthropic-ai disallowed** | Explicit block for our agent → sample discarded, not used. Contact: ljsport@liveonsat.com |
| LiveSoccerTV | per-match broadcaster list for ~200 countries (sample: Brentford–Everton) | HTML; day list loads through `/xloadday.php` which robots.txt **disallows**; match pages allowed | Disclaimer: copying only for **personal use, with the source acknowledged**; no API/licence mentioned; contact form only | Best channel data. Automated use in the app needs written permission (docs/PERMISSION-REQUESTS.md — drafts, not sent). |
| Sky Sports «Football on Sky» | official UK schedule: kickoff + Sky channel + programme start | HTML, `/watch/` allowed in robots (`/api/` disallowed) | **Sky.com T&Cs §2.8** (https://www.sky.com/help/articles/skycom-terms-and-conditions — applies to «Sky's websites, platforms, services, products and apps»): no access, search or collection of data «by any means (whether automated or manual) unless Sky has given its express written authorisation», incl. robots, scripts or manual tools to «scrape, data mine, or aggregate any Content … for any purpose». §2.7: copying only for «own personal non-commercial home use». | **Explicit restriction for the app's use** (automatic or by hand). Not integrated; would need Sky's written authorisation. |
| TNT Sports (UK) | official schedule | geo-blocked outside UK («not available in your region») | — | Not reachable from here. |
| TheSportsDB | fixtures, TV listings | documented JSON API v1, public key `123` (v2 = premium only) | Free limits **per endpoint** (docs_api_guide): 30 requests/min; Schedule Day (`eventsday`) 3; Schedule TV (`eventstv`) 1; Lookup Event TV Broadcasts 2; Schedule Season 15; Schedule League Next/Previous 1; Lookup Event 1. Tested: `eventsday?d=2026-11-24&s=Soccer` → 3 events; `eventstv?d=2026-11-23&s=Soccer` → 1. No terms on app use found on the API pages. Premium $9/month lifts the caps. | Free key too small for a day's schedule; premium needs the owner's approval. |

## Owner 23:57 — LiveSoccerTV International Coverage + Live-FootballOnTV (incl. 4K)

| Source | What it gives | Access | Terms found | Use in the app |
|---|---|---|---|---|
| LiveSoccerTV match pages | **International Coverage**: every country with every channel/platform, on the match page itself (the same full list from a US address: not limited to the device's country) | HTML match pages, allowed by robots.txt; the day list loads through `/xloadday.php`, which robots.txt disallows | Disclaimer (https://www.livesoccertv.com/disclaimer/): «Downloading, printing or copying of any content from this web site is permitted only for the purposes of personal use in which case you must acknowledge the source of the material.» No API, licence or terms page found; contact form only. | Personal use with the source named; automatic fetching inside the app needs their permission (docs/PERMISSION-REQUESTS.md — drafts, not sent). Tested by hand + import file. |
| Live-FootballOnTV (UK) | UK broadcasters per match, incl. **Sky Sports Ultra HDR** and **TNT Sports Ultimate** on its 4K page | HTML; robots.txt `User-agent: * / Disallow:` (nothing disallowed) | No terms, copyright or reuse statement on the home page, the 4K page, About or Contact (only a privacy policy). Times are UK local (not stated on the page; GMT = UTC+0 in November, BST in summer). | No explicit permission and no explicit ban found. Tested by hand + import file; automatic fetching left for the owner's decision / permission. |

Sample 24/11 (two files in `docs/samples/`, read by hand, sources named):
- LiveSoccerTV: 23 matches, 285 distinct names — 176 channels, 102 platforms (TOD, beIN CONNECT, HBO Max, DAZN <country>,
  myCANAL, Sky Go…), 7 whole networks (Canal+, Movistar+…). Kickoffs converted from America/New_York (UTC−5).
  International coverage: Man City–Napoli 254 entries, Real Madrid–PSV 269, Wolves–Derby, Rangers–Aberdeen in full.
  **No 4K channel named anywhere.**
- Live-FootballOnTV: 30 matches (24/11 + Stoke–Millwall 25/11), 13 channels + 8 platforms; 4K: «Sky Sports Ultra HDR»
  (Wolves–Derby, Rangers–Aberdeen, Stoke–Millwall), «TNT Sports Ultimate» (Man City–Napoli).
- Same matches in both: **20** (18 by name + «Wolves» = Wolverhampton Wanderers + «QPR» = Queens Park Rangers, read
  through a short-name table); kickoff equal in all 20 after time-zone conversion. Only in Live-FootballOnTV: 10 (EFL Trophy
  U21 sides, UEFA Youth League U19 — Arsenal U19 stays apart from Arsenal —, Santos–Grêmio, St. Louis–LAFC, Cesena–Ascoli,
  Cardiff–Preston, Blackpool–Leicester, Hibernian–Dundee, Stoke–Millwall 25/11). Test: theTwoSamplesMergeIntoOneRowPerMatch.
- Library matches and channels outside the EPG need the owner's library and guide: the device report lists them in full
  after importing the two files (sections «قنوات طابقت مكتبتك», «قنوات 4K», «منصات وشبكات عامة»).

Rules added (0.9.33 / 1.8.6): a listed name is a **channel**, a **whole network** (Canal+, Movistar+, TNT Sports with
nothing else) or a **platform** (an app/service word: Connect, TOD, Go, Now, Play, HBO Max, Paramount+, DAZN <country>…)
— platforms and networks are shown under the match, never linked to a channel. Country words inside names
(«Arena Sport 3 Croatia») are the country, not the channel; the channel number must be equal; another country = possible
only. Commentary language only when the name says it (English / French…). A named 4K channel («Sky Sports Ultra HDR»,
«TNT Sports Ultimate») matches the library's 4K versions of the channels listed with it for that match as **possible**,
and a library channel with the same 4K name as confirmed; an HD channel alone never brings a 4K one.

## Our tools vs the app

The blocks above are of two kinds and are kept apart:
- **Blocks on our research tool** (Claude/Firecrawl): LiveOnSat's robots.txt disallows ClaudeBot / anthropic-ai — we
  don't read it with these tools. That says nothing by itself about the app; the app's own use still needs the site's
  permission because no terms grant it.
- **Terms on the data's use in the app**: Sky §2.8 (explicit, automated or manual), LiveSoccerTV (personal use with
  attribution; its day loader is disallowed in robots.txt), TheSportsDB (free caps per endpoint).

## Import file — "shasha-matches" v1 (both apps)

```json
{"format": "shasha-matches", "version": 1,
 "source": {"name": "…", "kind": "broadcaster" | "guide", "url": "optional", "fetchedAt": "2026-11-24T08:00:00Z"},
 "matches": [{"home": "…", "away": "…", "kickoff": "2026-11-24T20:00:00Z", "competition": "optional", "sport": "football",
              "channels": [{"name": "beIN Sports HD 3", "country": "Bahrain", "programmeStart": "optional ISO-8601"}]}]}
```
Times are ISO-8601 with an offset. A file is refused whole, with the reason, if a match lacks both teams or a valid
kickoff (≤ 5,000 matches, ≤ 5 MB). The latest file per source name is kept on the device; nothing is uploaded.
Sample: `docs/samples/shasha-matches-livesoccertv-2026-11-24.json` (23 matches of 24/11, read by hand for the
owner's personal test, source named).

## Merge rules (MatchSourcesCore.kt = MatchSourcesRule.swift, same vectors)

- Same match: both teams (either order, women/age markers equal, one name's words inside the other's), and the
  schedule's kickoff within the EPG card's programmes −3 h … +1 h. EPG replays never join a scheduled match.
- Times stay apart: the schedule's kickoff and the EPG programme times are both shown. They "fit" when a programme
  starts ≤ 2 h before and ≤ 15 min after the kickoff; otherwise (or two schedules disagreeing) the match says
  «⚠ الجدول وEPG مختلفان في الموعد» and nothing is overwritten.
- A schedule's channel → library channel: same network and the same distinguishing words = match; inside a longer
  name or another country = possible (shown apart, not confirmed). A UHD/4K library version is taken only when the
  schedule itself names UHD/4K.
- Every channel keeps every proof with source and time: «أضفتها يدويًا» · «مدرجة في جدول الناقل» · «مدرجة في دليل نقل
  خارجي» · «موجودة في EPG المزوّد» · «نسخة محتملة بلا دليل» (suggestions: apart, never zapped or counted).
- Manual links (add / remove) are per match (teams + local day), kept on the device, and win over every source.
- Report: the complete comparison (no first-N cut): matches the schedules added, channels matched / possible / not in
  the library, and every time conflict.

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
