# Shasha cloud sync format (iPhone app ↔ TV app)

One JSON file, `shasha-sync-v1.json`, in the signed-in Google account's **appDataFolder** (scope
`https://www.googleapis.com/auth/drive.appdata` — the app sees only its own file). Both apps use the **same OAuth client**
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
