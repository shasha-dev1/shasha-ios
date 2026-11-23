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
