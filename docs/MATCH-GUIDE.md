# Match guide — step 1: coverage report from the provider's guide (iPhone 1.7.10 / TV 0.9.26, branches work/match-guide)

Owner's decision (21:04): start with the provider's own guide (EPG), no sign-up or paid service. Live scores later.
Source name shown to the viewer: «دليل برامج المزوّد».

## Rules (MatchGuideRule.swift = MatchGuideCore.kt, same test vectors)
- Sports channel: name or group contains a sports word / known sports network (list in the code).
- A programme names a match when its title (after "LIVE:", "[..]", "Competition:" prefixes) holds two teams around
  v / vs / x / × / ضد / – / -. A dash is weak: rejected when a side has a year or a show word (News, Episode, نشرة…).
- Kind from the programme's own words: replay / highlights (إعادة، ملخص، (R)) → replay; studio / pre-match / تحليل →
  studio; LIVE / مباشر / en vivo… → live; description saying live counts only for a programme ≥ 80 min. Otherwise
  "unknown". Teams + time is a strong hint, never a guarantee of a live broadcast.
- Same match = same two teams (any order, accents / FC / CF ignored) starting within 45 min → one card. Women's teams
  and age groups stay different teams (Arsenal ≠ Arsenal Women ≠ Arsenal U21). A later airing is its own card.
- Versions from the channel NAME: 4K/UHD → 1080p/FHD → 720p/HD → SD → «غير معروفة» (unknown is never "low");
  HEVC = codec badge, RAW = provider label; marked «(من الاسم)» until the player confirms. A UHD channel counts only
  through its own guide (never assumed to air what its HD sibling airs).

## Reports
- TV: Settings → «تقرير دليل المباريات (تجريبي)» (uses the guide already imported; file files/match-guide-report.txt).
- iPhone: Settings → التشخيص والأداء → «تقرير دليل المباريات (تجريبي)» (downloads xmltv.php once, streams it,
  keeps only sports channels' programmes; channels matched by the provider's epg_channel_id, else by name).
- Both list: sports channels, how many have a guide, guide span (first/last time, median days per channel),
  programmes, those naming two teams, live/replay/studio/unknown counts, cards in the next 48 h (and how many say
  live), 25 example cards with each channel's version, kind, source and title, and 15 sports titles where no teams
  were found (to improve the rules). No links, no account data.
- Decision after the owner's reports: is the guide enough, or is another schedule source needed.

## Step 1b (owner 21:23) — iPhone 1.7.11 / TV 0.9.27
- Cards per airing: anchored to the card's first entry (±45 min, no chaining: 18:00 / 18:40 / 19:20 → 2 cards), same
  live/unknown vs replay kind (replays apart), a different competition named in the title splits; studio shows are
  not cards (counted). Women / age groups stay different teams.
- Coverage reported twice: channel versions, and channels after merging versions (`channelKey`: version words only
  removed — number, country prefix and other words kept).
- The report says how sports channels are picked, and counts match titles on channels NOT picked as sports (general
  channels can air matches), with examples by guide id.
- Header: app version, report time, time zone, sources included (TV: every playlist with its last guide update and
  read error; iPhone: the active source, guide downloaded now and its size; parse errors), so a difference between the
  two devices can be told apart from a difference in data.
- iPhone: download to a file with a 400 MB limit (refused before/while downloading), cancel button (also on leaving
  the screen; the parser aborts), parse at utility priority off the main thread, memory measured before / after the
  download / after reading (performance report + the report's last line).
- «مباريات اكتشفناها من الدليل» is not «نسبة تغطية مباريات اليوم»: the latter needs an independent schedule.

## Rules v2 + screen (owner 22:04) — iPhone 1.8.5 / TV 0.9.29

From the first two reports (23/11, ~1,800–2,100 cards): versions mostly "unknown" (decorated letters), other sports
mixed in, round/sponsor text in names, movie titles on general channels, same-name versions, a 63k vs 88k gap.

- **Folding**: NFKC + small capitals + ⚽→o before any check (ᴴᴰ = HD, ʰᵉᵛᶜ = HEVC, ᵁᴴᴰ ³⁸⁴⁰ᴾ = 4K, SP⚽RTS = SPORTS).
- **Resolution**: the part after the provider prefix decides; the prefix counts only when the rest says nothing, and
  not at all when it is a *label in that source* — `prefixLabels`: a resolution-looking prefix with ≥ 3 channels
  whose bodies name another resolution ≥ 30 % of the time (8K: on the owner's source; 4K: stays). LQ = SD.
- **Sport**: another sport named in the category / title / description wins (BSL → basketball even for Beşiktaş),
  then football words or a football-only competition, then the channel's own name; else **unknown, kept apart**.
- **Cleaning** (titles are never changed): a round marker before the home team becomes `lead` ("BSL (26-27)
  09.Hafta"); after a slash only known markers go (Bant, Canlı…); women/age brackets stay; women/age named in the
  competition part ("Siatkówka kobiet:") are carried by both teams.
- **Kinds by words** ("Liverpool" ≠ live); Bant / différé / powtórka / tekrar = replay; "not stated" ≠ live.
- **General channels**: an entry counts only with football named in the guide entry itself (not the channel name).
- **Versions**: every channel version is its own entry and its own selectable row (same name = "نسخة 1/2").
- **Index**: today + tomorrow (local), each version apart. TV: one SQL pass over the imported guide (titles with a
  separator), `files/match-index.json`; guide `<category>` now stored (DB v12, filled at the next guide refresh).
  iPhone: the guide file streamed once, `Caches/match-index.json`; rebuilt on Wi‑Fi when older than 6 h or another day,
  over mobile data only on request.
- **Report v2** (both): guide totals and links (by id / by name / none), programmes per guide id and the old
  per-version count (TV: also with its 400 cap — the 63k vs 88k question is answered by these lines, not guessed),
  football / other / unknown cards, kinds, general channels, qualities, prefix labels, per network and per prefix,
  a varied sample with original titles, rejected titles, time and memory per stage.
- **Screen**: today / tomorrow / on now by the guide, sport filter, quality filter (hide HD / SD; 4K, 1080p and
  unknown always stay; nothing lower is played instead), match → versions → player (zapping between that match's
  versions). TV: nav bar + side menu, and over the live player (Menu → options); iPhone: Channels tab + a sheet in
  the live player. The video keeps playing behind the in-player panel/sheet; the list keeps its place.
- Coverage of "today's matches" is still not computed: it needs an independent fixtures list.
