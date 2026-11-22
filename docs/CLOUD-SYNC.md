# Shasha cloud sync format (iPhone app ↔ TV app)

One JSON file, `shasha-sync-v1.json`, in the signed-in Google account's **My Drive** (scope
`https://www.googleapis.com/auth/drive.file` — the app sees only files it created; changed from drive.appdata on 2026-11-22 because Google's device flow refuses drive.appdata with "Invalid device flow scope"). Both apps use the **same OAuth client**
(type "TVs and Limited Input devices", the viewer's own Google Cloud project), so they share the folder.
Sign-in: Google device flow (`/device/code`, poll `/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code`).

```json
{"v":1,"progress":{"<account>|movie|<streamId>":{"pos":1234.5,"dur":5400,"w":false,"at":1732280000000},
                   "<account>|ep|<episodeId>":{"pos":0,"dur":2700,"w":true,"at":1732281000000,"show":"<seriesId>"}}}
```
- `<account>` = first 16 hex chars of SHA-256 of `host:port|username` of the Xtream account (host lower-case,
  port 80/443 when absent; never the password). Same account on both devices ⇒ same ids.
- `pos`/`dur` in seconds, `w` = watched (finished), `at` = time of that device's save in ms since 1970.
- Merge: per key the larger `at` wins; the file keeps the newest 3000 entries. A device applies only entries of its
  active account that are newer than its own, and uploads the merged file when it changed.
- iPhone keys: `movie:<id>` / `ep:<id>`. TV keys: `<playlistId>:movie:<id>` / `<playlistId>:ep:<id>`.

## 1.6.0 additions (iPhone; format stays `"v":1`)
- Optional `"x":true` on an entry = removed from "Continue watching" at `at`. Readers that don't know it ignore it
  (TV 0.9.10/0.9.11 parse it away; when such a TV rewrites the file the flag is dropped, which only means the other
  device doesn't learn about the removal — no progress is lost).
- `w:false` with `pos` ≤ 5 = marked "not watched / start over" at `at`.
- A file that can't be parsed, is larger than 4 MB, or has `v` > 1 is refused: nothing applied, nothing uploaded.
- Entries whose `at` is more than 24 h in the future are ignored in merges (wrong device clock).
- Before writing, the phone re-reads Drive's `version` of the file; if the other device wrote meanwhile it merges
  again (once), so simultaneous saves don't overwrite each other.
- Before the first change of a day the previous contents are saved as `shasha-sync-v1.backup.json`.

## 1.7.0 / TV 0.9.13 — simultaneous writes (what is and isn't guaranteed)
Drive v3 has no conditional upload, so a write can't be refused when the file changed. Instead:
1. Before uploading, the phone compares Drive's `version` with the one it read; if it changed, it reads and merges again.
2. After uploading, both apps read the file again and check `covers(file, mine)` (every own entry present, or a newer
   one). If not, the other device overwrote this upload: merge with what is there now and upload again (max 2–3 times).
3. Every sync re-merges the device's whole local state, so an entry overwritten in a race comes back at the latest on
   that device's next sync. Merges are per key, newest `at` wins, so repeating them is safe.
Tests: CloudSyncConcurrencyTests (iPhone), CloudSyncCoreTest.lostWriteIsDetectedAndRepaired (TV).

## Removal flag `x` — compatibility
- iPhone ≥ 1.6.0 writes it; TV ≥ 0.9.13 applies it (hides the title from its Continue watching until played again
  after that time) and writes it back for titles hidden there. TV 0.9.12 keeps it when rewriting but doesn't hide.
- TV ≤ 0.9.11 drops it on rewrite: the removal then stays only on the iPhone. No progress is lost in any combination.
- An older copy elsewhere can't undo a removal (its `at` is older); playing the title again later brings it back.
Tests: CloudSyncConcurrencyTests.testRemovalSurvivesRepeatedMergesWithTheTvsRow, CloudSyncCoreTest.removedItemStaysRemovedOverRepeatedSyncs.

## Clock
Entries more than 24 h ahead are not applied and don't win merges, but stay in the file; both apps report how many.
The phone compares its clock with Google's `Date` header and warns when it differs by more than 5 minutes.

## 1.7.1 / TV 0.9.14 — the honest limit, and clocks
**Known limit (not "no data loss").** Drive v3 can't refuse an upload when the file changed. Case tested in both apps
(`…StaleUpload…KnownLimit…`, `staleUploadAfterTheOtherFinishedLosesItWithoutVersionCheck`): A uploads and verifies; then B,
which read the file before A's upload, uploads its stale merge and verifies too. Without a version check A's entry is gone
from the cloud. Since 0.9.14 the TV checks the version before uploading as the iPhone already did, which catches this
case (`…CaughtByTheVersionCheck`). A write that lands between one device's version check and its upload can still replace
the other's entries in the cloud; they are never removed from the device that made them (its local data is the source) and
go back up on that device's next sync — if it stays offline, the other device doesn't see them until then.
To evaluate later, with a planned migration and no format break: one file per device (each device writes only its own
file, readers merge all), or an append-only event log. Not changed now.

**Clocks.** Each app measures its clock against Google's `Date` header and sends its save times in Google's clock
(`stamp`), storing the other device's times back in its own clock (`toLocal`). Device 2 days ahead: its saves arrive
with the right time. Device 2 days behind: its newer action still wins (without the correction it lost). Saves made while
a clock was ahead and before it was measured sit in the file as "future" (not applied, counted, kept); once the clock is
right (or measured) the device re-sends them capped at "now", the other device applies them, nothing stays stuck.
Tests: CloudSyncRaceAndClockTests (iPhone), CloudSyncCoreTest clock* (TV).

## 1.7.2 / TV 0.9.15 — event time is kept; unknown order never replaces a newer entry
Correction of 1.7.1: capping own times at "now" let an old event, re-sent after a clock fix, beat a newer correct
watch from the other device. Now the time an event happened is kept (`stamp` = local time − measured skew, no cap).
An own entry still ahead of Google's "now" (+2 min) after the correction was saved while the clock was wrong and before
the skew was measured; its order is unknown (`prepareOwn`):
- the file has a valid entry for that title → ours is not uploaded, the other device's entry is applied here, and the
  sync message reports it («لم يُرسل … واعتُمد هو»);
- the file has nothing valid → ours is sent with "now".
The send time is not stored separately in the file (format v1 unchanged); identity stays the per-title key.
Tests: testOldEventFromAWrongClockNeverBeatsANewerCorrectWatch (iPhone), oldEventFromAWrongClockNeverBeatsANewerCorrectWatch (TV).
**Status: release candidate for device testing; the write-race limit above still applies — the version check narrows,
but doesn't close, the gap between check and upload.**
