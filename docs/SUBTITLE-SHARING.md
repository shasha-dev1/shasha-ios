# Subtitles shared between the iPhone and the TV (iPhone 1.7.5, TV 0.9.18)

Owner's decisions: a subtitle that arrives from the other device is turned on automatically (unless subtitles are off
for that series); old files must not pile up.

- Each subtitle downloaded from the internet (OpenSubtitles etc.) is kept for that film/episode on the device and
  uploaded to Google Drive as its own file. The sync file `shasha-sync-v1.json` (format v1) is not changed.
- Name: `shasha-sub-v1-<first 24 hex of SHA-256(key)>.srt`, key = `account|kind|id` (same as the sync entries).
  Test vectors (both apps): `0123456789abcdef|movie|12345` → `shasha-sub-v1-200a02eb8884dc7d433f9fe5.srt`,
  `0123456789abcdef|ep|987654` → `shasha-sub-v1-b89e90fd6ac239417f88da25.srt`.
- Drive `appProperties`: `shashaSub=1` (used to list them), `lang`, `label` (clipped to fit Drive's 124-byte limit).
- Opening a film/episode: the device's own kept file, else one Drive lookup by name → download → keep → turn on once
  the player has loaded the video. No call to the subtitle sites (no quota used).
- Retention (`SubSyncRule.prune` / `SubSyncCore.prune`): files not updated for 30 days go, and at most 150 are kept
  (oldest first). Drive: checked at most once a day after an upload. Local: on each keep/fetch.
- Not shared yet: the subtitle delay/offset and the TV's speed ratio (the apps adjust them differently); a later stage.
- Logged in the performance report (iPhone): «ترجمة: رفع إلى Drive», «ترجمة: من الجهاز الآخر», failures, clean-up.
