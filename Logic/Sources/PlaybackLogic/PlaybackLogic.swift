import Foundation

// Pure playback rules for the iPhone player. No UIKit / VLC here: the player screen feeds plain numbers in
// and acts on the answers. Unit-tested in Logic/Tests (run by CI with `swift test`).

/// Engine state reduced to what the rules need (mapped from VLCMediaPlayerState by the player).
enum EngineState: Equatable {
    case opening, buffering, playing, paused, stopped, ended, error
}

// MARK: - Stall (spinner)

/// Spinner rule: the spinner means "the playback clock is not moving although we expect it to".
/// VLC reports `buffering` almost all the time while playing, so its state alone is useless.
/// - Not shown when the viewer paused, or the engine is paused / stopped / ended / failed.
/// - Shown while opening (nothing decoded yet).
/// - Otherwise shown after `stallTicks` consecutive samples with the same clock (2 Hz → 1.5 s).
/// - `reset()` after a seek or a new item: the jump of the clock must not count as progress or as a stall.
/// Live streams: VLC's clock also advances for live, so the same rule applies.
struct StallDetector {
    var stallTicks = 3
    static let tickMs: Int32 = 500
    /// How long the clock has not moved.
    var frozenMs: Int32 { Int32(frozenTicks) * Self.tickMs }
    private(set) var lastTime: Int32? = nil
    private(set) var frozenTicks = 0

    mutating func reset() { lastTime = nil; frozenTicks = 0 }

    /// Feed one sample; returns whether the spinner should show.
    mutating func sample(timeMs: Int32, state: EngineState, viewerPaused: Bool) -> Bool {
        defer { lastTime = timeMs }
        if let last = lastTime, last == timeMs { frozenTicks += 1 } else { frozenTicks = 0 }
        if lastTime == nil { frozenTicks = 0 }
        switch state {
        case .paused, .stopped, .ended, .error: return false
        case .opening: return !viewerPaused
        case .buffering, .playing: return !viewerPaused && frozenTicks >= stallTicks
        }
    }
}

// MARK: - End of a film / episode

enum EndDecision: Equatable {
    /// Really finished: mark watched; may move on to the next episode.
    case finished
    /// Stopped before the end (server closed the connection, file shorter than its length…):
    /// keep the resume point, offer Retry; never mark watched.
    case stoppedEarly
}

enum EndRule {
    /// "Watched" threshold, same as the resume store (≥ 95 %).
    static let watchedFraction = 0.95
    /// …or less than this left (short credits are often cut by providers).
    static let maxTailMs: Int32 = 60_000

    /// Whether a position counts as the end of the item. Unknown length (0) never counts.
    static func isComplete(timeMs: Int32, lengthMs: Int32) -> Bool {
        guard lengthMs > 0, timeMs > 0 else { return false }
        let left = lengthMs - min(timeMs, lengthMs)
        return Double(timeMs) / Double(lengthMs) >= watchedFraction || left <= maxTailMs
    }

    /// Clock frozen this long inside the completion zone = the file is over (some providers keep the
    /// connection open after the last byte, so the engine never says "ended").
    static let tailFreezeMs: Int32 = 4_000

    /// Whether the item has stopped playing by itself, so an end decision must be made now.
    /// - `ended` or `stopped`: the engine stopped on its own (the player's own stop ends the session first,
    ///   so this is never called for it). VLCKit sometimes reports `stopped` instead of `ended` at the end.
    /// - playing/buffering with a frozen clock only counts inside the completion zone; a freeze earlier in
    ///   the file is a stall (spinner), never an end.
    static func engineStopped(state: EngineState, viewerPaused: Bool, frozenMs: Int32, timeMs: Int32, lengthMs: Int32) -> Bool {
        switch state {
        case .ended, .stopped: return true
        case .playing, .buffering:
            return !viewerPaused && frozenMs >= tailFreezeMs && isComplete(timeMs: timeMs, lengthMs: lengthMs)
        case .opening, .paused, .error: return false
        }
    }

    /// Decision when the engine reports `ended`. `lastTimeMs` = last clock seen while playing
    /// (the clock may already read 0 after the end).
    static func onEnded(lastTimeMs: Int32, lengthMs: Int32) -> EndDecision {
        isComplete(timeMs: lastTimeMs, lengthMs: lengthMs) ? .finished : .stoppedEarly
    }
}

// MARK: - Next-episode card

/// The card is information only. It shows near the end; it never starts the next episode by itself.
/// The next episode starts automatically only after a `.finished` end, or when the viewer taps "Play now".
enum NextCardRule {
    static let showWithinMs: Int32 = 40_000
    static let hideAboveMs: Int32 = 45_000        // hysteresis after seeking back
    static let minLengthMs: Int32 = 120_000

    /// New visibility given the current one.
    static func visible(current: Bool, hasNext: Bool, dismissed: Bool, timeMs: Int32, lengthMs: Int32, scrubbing: Bool) -> Bool {
        guard hasNext, !dismissed, lengthMs > minLengthMs, timeMs > 0 else { return false }
        let left = lengthMs - min(timeMs, lengthMs)
        if current { return left < hideAboveMs }
        return !scrubbing && left < showWithinMs
    }
}

// MARK: - Resume saving

/// One playback session = one item opened in the engine. Every timer/task and every save carries the
/// session id, so work started for episode 3 can never act on (or save under) episode 4.
struct PlaybackSession: Equatable {
    let id: Int
    let key: String
}

struct ResumeSave: Equatable {
    let key: String
    let positionS: Double
    let durationS: Double
}

enum ResumeRule {
    /// Periodic save interval while playing.
    static let periodMs: Int32 = 10_000
    /// Below this the resume point is not offered (start over).
    static let minResumeS = 15.0

    /// What to save for the session that is on screen, given the engine sample.
    /// `engineSessionId` = session the engine's numbers belong to (set when the item is opened).
    /// Nothing is saved when the numbers belong to another session, the length is unknown or the clock is 0
    /// (a fresh item reads 0 before it starts; saving it would wipe the real resume point).
    static func save(screen: PlaybackSession?, engineSessionId: Int?, timeMs: Int32, lengthMs: Int32) -> ResumeSave? {
        guard let s = screen, s.id == engineSessionId, lengthMs > 0, timeMs > 0 else { return nil }
        return ResumeSave(key: s.key, positionS: Double(timeMs) / 1000, durationS: Double(lengthMs) / 1000)
    }

    /// Whether a periodic save is due.
    static func periodicDue(lastSavedAtMs: Int32?, timeMs: Int32) -> Bool {
        guard let last = lastSavedAtMs else { return timeMs >= periodMs }
        return abs(timeMs - last) >= periodMs
    }

    /// Where to start an item from its stored position (nil = from the start).
    static func startPosition(stored: Double?) -> Double? {
        guard let p = stored, p >= minResumeS else { return nil }
        return p
    }
}

// MARK: - Play / pause

/// Single source of truth for "the viewer wants it paused", shared by on-screen buttons and Control Center.
enum PauseCommand: Equatable { case play, pause, toggle }

enum PauseRule {
    static func apply(_ c: PauseCommand, viewerPaused: Bool) -> Bool {
        switch c {
        case .play: return false
        case .pause: return true
        case .toggle: return !viewerPaused
        }
    }
}

// MARK: - Sessions and delayed work

/// Hands out playback sessions. Opening a new item ends the previous session; leaving the player ends it too.
final class SessionGate {
    private(set) var current: PlaybackSession?
    private var counter = 0

    func begin(key: String) -> PlaybackSession {
        counter += 1
        let s = PlaybackSession(id: counter, key: key)
        current = s
        return s
    }

    func end() { current = nil }

    func isCurrent(_ id: Int?) -> Bool { id != nil && current?.id == id }
}

enum Delayed {
    /// Sleeps, then runs `action` only if the task was not cancelled and `stillValid()` holds
    /// (checked after the sleep, right before acting). Returns whether the action ran.
    @discardableResult
    static func run(after nanoseconds: UInt64, stillValid: @escaping () async -> Bool, _ action: @escaping () async -> Void) async -> Bool {
        do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return false }
        guard !Task.isCancelled, await stillValid() else { return false }
        await action()
        return true
    }
}

// MARK: - Group order

enum GroupOrderRule {
    /// Viewer's saved order first (ids that still exist, no duplicates), then new provider groups in provider order.
    static func arrange(provider: [String], saved: [String]) -> [String] {
        let exists = Set(provider)
        var seen = Set<String>()
        var out: [String] = []
        for id in saved where exists.contains(id) && seen.insert(id).inserted { out.append(id) }
        for id in provider where seen.insert(id).inserted { out.append(id) }
        return out
    }
}

// MARK: - Diagnostics

enum DiagRule {
    /// Removes stream links and any secret (user name, password, server) from text before it is shown or copied.
    static func redact(_ text: String, secrets: [String]) -> String {
        var s = text.replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+"#, with: "[رابط مخفي]", options: .regularExpression)
        for secret in secrets where secret.count >= 3 {
            s = s.replacingOccurrences(of: secret, with: "•••")
        }
        return s
    }

    /// Four-character code as text ("hevc", "dvhe", "subt"); VLC stores them little-endian.
    static func fourcc(_ v: UInt32) -> String {
        guard v != 0 else { return "غير متاح" }
        let bytes = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", v) : String(format: "0x%08x", v)
    }

    /// Readable lines from the provider's ffprobe data (Xtream "info.video" / "info.audio"), when it sends it.
    /// Only keys that are present are printed; nothing is guessed.
    static func probeLines(video: [String: Any]?, audio: [String: Any]?) -> [String] {
        var out: [String] = []
        func str(_ v: Any?) -> String? {
            if let s = v as? String, !s.isEmpty { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        if let v = video {
            for (k, label) in [("codec_name", "ترميز"), ("codec_tag_string", "وسم الترميز"), ("profile", "profile"), ("level", "level"),
                               ("width", "العرض"), ("height", "الارتفاع"), ("pix_fmt", "pix_fmt"), ("color_range", "color_range"),
                               ("color_space", "color_space"), ("color_transfer", "color_transfer"), ("color_primaries", "color_primaries"),
                               ("r_frame_rate", "fps")] {
                if let s = str(v[k]) { out.append("فيديو \(label): \(s)") }
            }
            for sd in v["side_data_list"] as? [[String: Any]] ?? [] {
                let type = str(sd["side_data_type"]) ?? "side data"
                var parts: [String] = []
                for k in ["dv_version_major", "dv_profile", "dv_level", "rpu_present_flag", "el_present_flag", "bl_present_flag", "dv_bl_signal_compatibility_id"] {
                    if let s = str(sd[k]) { parts.append("\(k)=\(s)") }
                }
                out.append("فيديو side data: \(type)" + (parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"))
            }
        }
        if let a = audio {
            for (k, label) in [("codec_name", "ترميز"), ("profile", "profile"), ("channels", "قنوات"), ("channel_layout", "توزيع")] {
                if let s = str(a[k]) { out.append("صوت \(label): \(s)") }
            }
        }
        return out
    }
}

// MARK: - Copies of the same title and Dolby Vision 5

enum CopyRule {
    /// Same work across provider groups: "4K-AMZ - The Lord of the Rings: The Rings of Power (2022) (US)" and
    /// "The Lord of the Rings The Rings of Power" give the same key. Drops a short leading tag ("4K-NF - "),
    /// bracketed parts, and punctuation.
    static func key(_ name: String) -> String {
        var s = name
        if let r = s.range(of: #"^\s*[A-Za-z0-9|\[\]]{1,4}([\-|][A-Za-z0-9]{1,6}){0,3}\s*[-:|]\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return s.split(separator: " ").joined(separator: " ")
    }

    /// Provider data says Dolby Vision profile 5 with no HDR10/SDR fallback layer: VLCKit on iPhone shows it green/purple.
    static func isDolbyVision5(_ probe: [String]) -> Bool {
        guard let line = probe.first(where: { $0.contains("DOVI") }) else { return false }
        let p5 = line.contains("dv_profile=5")
        let compat = line.range(of: #"dv_bl_signal_compatibility_id=(\d+)"#, options: .regularExpression).map { String(line[$0]) }
        return p5 && (compat == nil || compat!.hasSuffix("=0"))
    }
}

/// 1.0.3: search text folded once per title (off the main thread) and once per query, then compared with a plain
/// `contains`. Case, accents and width are ignored, and common Arabic spelling variants match:
/// أ إ آ ٱ → ا, ة → ه, ى → ي, ؤ → و, ئ → ي, tatweel and harakat removed.
enum SearchRule {
    static func fold(_ s: String) -> String {
        let base = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(base.unicodeScalars.count)
        for u in base.unicodeScalars {
            switch u.value {
            case 0x0623, 0x0625, 0x0622, 0x0671: out.append("\u{0627}")
            case 0x0629: out.append("\u{0647}")
            case 0x0649, 0x0626: out.append("\u{064A}")
            case 0x0624: out.append("\u{0648}")
            case 0x0640, 0x064B...0x0652, 0x0670: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    static func matches(_ foldedName: String, _ foldedQuery: String) -> Bool {
        foldedQuery.isEmpty || foldedName.contains(foldedQuery)
    }
}

/// 1.0.9: matching provider titles to TMDB (ported from the TV app's TitleClean / TmdbParse rules).
/// A match is accepted only when the normalised name or original name equals the search term and, when both years
/// are known, they are within one year; more than one such result = no match (never guess).
enum TmdbRule {
    struct Candidate: Equatable { let id: Int; let name: String; let originalName: String; let year: Int? }

    /// "AR-TR-S - Yeraltı (2026)" → (tag "AR-TR-S", title "Yeraltı (2026)").
    static func split(_ name: String) -> (tag: String?, title: String) {
        let pattern = #"^\s*([A-Z0-9]{2,4}(?:[-_][A-Z0-9]{1,4}){0,3})\s*[-|:•]\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), m.numberOfRanges == 3,
              let t = Range(m.range(at: 1), in: name), let r = Range(m.range(at: 2), in: name) else {
            return (nil, name.trimmingCharacters(in: .whitespaces))
        }
        let title = name[r].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? (nil, name.trimmingCharacters(in: .whitespaces)) : (String(name[t]), title)
    }

    /// Year written in the title, "(2019)" or "[2019]".
    static func year(_ title: String) -> Int? {
        guard let r = title.range(of: #"[(\[]\s*(19|20)\d{2}\s*[)\]]"#, options: .regularExpression) else { return nil }
        return Int(title[r].filter(\.isNumber))
    }

    /// "Yeraltı (2026) تحت الارض" → ["Yeraltı تحت الارض", "Yeraltı", "تحت الارض"].
    static func searchTerms(_ title: String) -> [String] {
        func squeeze(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let noYear = squeeze(title.replacingOccurrences(of: #"[(\[]\s*(19|20)\d{2}\s*[)\]]"#, with: " ", options: .regularExpression))
        let isArabic: (Character) -> Bool = { c in c.unicodeScalars.allSatisfy { (0x0600...0x06FF).contains($0.value) } }
        let arabic = squeeze(String(noYear.filter { isArabic($0) || $0 == " " }))
        let latin = squeeze(String(noYear.filter { !isArabic($0) }))
        var out: [String] = []
        for t in [noYear, latin, arabic] where t.count >= 2 && !out.contains(t) { out.append(t) }
        return out
    }

    /// Letters and digits only, folded (case, accents, Arabic variants).
    static func key(_ s: String) -> String {
        String(SearchRule.fold(s).unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    static func choose(_ results: [Candidate], term: String, year: Int?) -> Int? {
        let k = key(term)
        guard !k.isEmpty else { return nil }
        let m = results.filter { r in
            (key(r.name) == k || key(r.originalName) == k) && (year == nil || r.year == nil || abs(r.year! - year!) <= 1)
        }
        return m.count == 1 ? m[0].id : nil
    }

    /// Library title key for "available in your library": tag and year removed, folded letters/digits.
    static func libraryKey(_ providerName: String) -> String {
        let t = split(providerName).title.replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        return key(t)
    }
}

/// 1.2.0: pure parts of Trakt (ported from the TV app's TraktAuth / TraktScrobble, unit-tested). No tokens here.
enum TraktRule {
    enum Poll: Equatable { case success, pending, slowDown, expired, denied, alreadyUsed, invalidCode, failed(Int) }

    /// Device-token poll status codes (Trakt device flow): 200 ok, 400 waiting for the user, 404 bad code,
    /// 409 already used, 410 expired, 418 denied, 429 polling too fast.
    static func poll(_ http: Int) -> Poll {
        switch http {
        case 200: return .success
        case 400: return .pending
        case 404: return .invalidCode
        case 409: return .alreadyUsed
        case 410: return .expired
        case 418: return .denied
        case 429: return .slowDown
        default: return .failed(http)
        }
    }

    enum Action: String { case start, pause, stop }

    /// Percent watched (two decimals), nil when the duration is unknown.
    static func percent(positionMs: Int, durationMs: Int) -> Double? {
        guard durationMs > 0 else { return nil }
        let p = Double(min(max(positionMs, 0), durationMs)) * 100 / Double(durationMs)
        return (p * 100).rounded() / 100
    }

    /// A pause at 0 % says nothing.
    static func worthSending(_ progress: Double) -> Bool { progress >= 1 }

    /// Leaving: `stop` only when the app itself counts it watched (≥ 95 %), otherwise `pause` — Trakt's own stop
    /// rule (≥ 80 % = watched) must not mark it watched earlier than the app does.
    static func exitAction(_ progress: Double) -> Action { progress >= 95 ? .stop : .pause }

    /// Search title + year from a provider name: the line with Latin letters, a trailing "(2026)" taken as the year.
    static func searchTitle(_ name: String, fallbackYear: Int?) -> (title: String, year: Int?) {
        let lines = name.split(whereSeparator: { $0 == "\n" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pick = lines.first { $0.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) } } ?? lines.first ?? name.trimmingCharacters(in: .whitespaces)
        if let r = pick.range(of: #"[\s\-–]*[(\[]((19|20)\d{2})[)\]]\s*$"#, options: .regularExpression) {
            return (String(pick[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), Int(pick[r].filter(\.isNumber)))
        }
        return (pick, fallbackYear)
    }

    /// Scrobble identity: {"movie": {...}} or {"show": {...}, "episode": {"season", "number"}}.
    static func identity(title: String, year: Int?, tmdb: Int?, season: Int?, number: Int?) -> [String: Any] {
        var media: [String: Any] = ["title": title]
        if let year, year > 1800 { media["year"] = year }
        if let tmdb, tmdb > 0 { media["ids"] = ["tmdb": tmdb] }
        if let season, let number { return ["show": media, "episode": ["season": season, "number": number]] }
        return ["movie": media]
    }

    static func body(_ identity: [String: Any], progress: Double) -> Data? {
        var b = identity
        b["progress"] = (progress * 100).rounded() / 100
        return try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
    }
}

/// 1.2.0: where to resume when both this phone and Trakt (another device, e.g. the TV app) have a position.
enum TraktResumeRule {
    enum Choice: Equatable { case local, trakt(Double), none }
    /// Trakt wins only when this phone has no position, or when its pause is clearly newer than this phone's save.
    /// A local position without a save time (saved before 1.2.0) is kept: never overwrite the viewer's own data on a guess.
    static func choose(localPos: Double?, localAt: Date?, traktPct: Double?, traktAt: Date?) -> Choice {
        let t = traktPct.flatMap { $0 >= 1 && $0 < 95 ? $0 : nil }
        guard let localPos, localPos > 5 else { return t.map { .trakt($0) } ?? .none }
        guard let t, let traktAt, let localAt else { return .local }
        return traktAt.timeIntervalSince(localAt) > 60 ? .trakt(t) : .local
    }
}

/// 1.3.0: progress shared between the iPhone app and the TV app through ONE small file in the viewer's own
/// Google Drive (hidden app-data folder). Both apps use the same keys, so a film or episode matches exactly
/// (same Xtream account = same ids) and resumes at the same second. Format (both apps, see docs/CLOUD-SYNC.md):
/// {"v":1,"progress":{"<account>|movie|<id>":{"pos":s,"dur":s,"w":false,"at":ms,"show":"<seriesId>"}}}
enum CloudSyncRule {
    struct Entry: Codable, Equatable {
        var pos: Double
        var dur: Double
        var w: Bool
        var at: Int64
        var show: String?
        /// 1.6.0, optional: removed from "Continue watching" at `at`. Older readers ignore it (format stays v1).
        var x: Bool? = nil
    }

    enum FileError: Error, Equatable { case tooBig(Int), unreadable, newerFormat(Int) }

    /// 1.6.0: a file that can't be read, is too big or is from a newer format is refused instead of being treated
    /// as empty (an empty "remote" merged with local data and uploaded would wipe the other device's entries).
    static func decode(_ data: Data, maxBytes: Int = 4_000_000) throws -> File {
        guard data.count <= maxBytes else { throw FileError.tooBig(data.count) }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { throw FileError.unreadable }
        guard f.v <= 1 else { throw FileError.newerFormat(f.v) }
        return f
    }

    /// 1.6.0: a save time more than a day in the future comes from a wrong clock; such an entry would win every
    /// merge forever, so it is left out of merges and never applied.
    static let futureSlackMs: Int64 = 24 * 3600 * 1000
    static func sane(_ e: Entry, nowMs: Int64) -> Bool { e.at <= nowMs + futureSlackMs && e.at > 0 }
    struct File: Codable, Equatable {
        var v = 1
        var progress: [String: Entry] = [:]
    }

    /// Account part of a key: SHA-256 of "host:port|user" (no password), first 16 hex characters. Same on both apps.
    static func account(server: String, user: String, sha256: (String) -> String) -> String? {
        guard let u = URL(string: server.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        let port = u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
        return String(sha256("\(host):\(port)|\(user)").prefix(16))
    }

    static func key(account: String, kind: String, id: String) -> String { "\(account)|\(kind)|\(id)" }

    /// Newest entry wins for each key; the file keeps at most `limit` entries (newest).
    static func merge(_ a: File, _ b: File, limit: Int = 3000, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> File {
        var out = a.progress
        for (k, e) in b.progress where sane(e, nowMs: nowMs) {
            if let o = out[k], sane(o, nowMs: nowMs), o.at >= e.at { continue }
            out[k] = e
        }
        if out.count > limit {
            let keep = out.sorted { $0.value.at > $1.value.at }.prefix(limit)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return File(v: 1, progress: out)
    }

    /// 1.7.0: `file` holds each of `mine`'s entries or a newer one. Checked by reading the file again after an
    /// upload: false means the other device wrote between our read and our upload (our write was overwritten), so
    /// we merge and upload again. Same rule as the TV app's CloudSyncCore.covers.
    static func covers(_ file: File, _ mine: File, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        mine.progress.allSatisfy { k, e in !sane(e, nowMs: nowMs) || (file.progress[k]?.at ?? -1) >= e.at }
    }

    /// 1.7.1: a local save time in Google's clock. `skewMs` = this phone's clock minus Google's (Date header; nil =
    /// unknown). Never later than "now" in Google's clock, so saves made while the clock was ahead come unstuck once
    /// it is right. Same rule as the TV app's CloudSyncCore.stamp.
    /// 1.7.2: not capped at "now" any more — capping let an old event, re-sent after the clock was fixed, beat a newer
    /// correct watch. The time the event happened is kept; an entry still in the future is handled by `prepareOwn`.
    static func stamp(_ localMs: Int64, skewMs: Int64?, nowLocalMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Int64 {
        localMs - (skewMs ?? 0)
    }

    static let ownJitterMs: Int64 = 2 * 60 * 1000
    struct Prepared { var send = File(); var withheld: Set<String> = []; var restamped: Set<String> = [] }

    /// 1.7.2: this phone's entries before comparing and uploading. One still ahead of Google's "now" after the clock
    /// correction was saved while the clock was wrong, so its real order is unknown: if the file has a valid entry for
    /// the title, ours is withheld (not uploaded, not used to refuse the other device's entry, which is then applied)
    /// and reported; if the file has nothing valid, it is sent with "now". Same rule as the TV app.
    static func prepareOwn(_ mine: File, file: File, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Prepared {
        var p = Prepared()
        for (k, e) in mine.progress {
            if e.at <= nowMs + ownJitterMs { p.send.progress[k] = e; continue }
            if let other = file.progress[k], sane(other, nowMs: nowMs) { p.withheld.insert(k) }
            else { var x = e; x.at = nowMs; p.send.progress[k] = x; p.restamped.insert(k) }
        }
        return p
    }
    /// A time from the file (Google's clock) in this phone's clock, for storing locally.
    static func toLocal(_ fileMs: Int64, skewMs: Int64?) -> Int64 { fileMs + (skewMs ?? 0) }

    /// 1.7.3: Google's Date header has 1-second resolution and arrives after a network delay, so each sync measured
    /// the skew a little differently (device report: "applied 46" on every sync with nothing new). Entries stored with
    /// one measurement and re-stamped with the next moved by that jitter and looked newer on one side or the other,
    /// so every sync re-applied or re-uploaded the same entries. The stored skew changes only when a new measurement
    /// differs by more than this (a real clock change is minutes; jitter stays under 2 s). Same rule as the TV app.
    static let skewHysteresisMs: Int64 = 2_000
    static func steadySkew(old: Int64?, measured: Int64) -> Int64 {
        guard let old else { return measured }
        return abs(measured - old) > skewHysteresisMs ? measured : old
    }
    /// 1.7.3: seconds since 1970 (as stored in Date) to ms, rounded. Truncating turned some stored times 1 ms earlier
    /// than the file's on the way back, so the file's entry looked newer again.
    static func ms(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    /// Entries ignored because their time is more than a day ahead (reported, never deleted from the file).
    static func futureCount(_ file: File, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Int {
        file.progress.values.filter { $0.at > nowMs + futureSlackMs }.count
    }

    /// Entries of `remote` that are newer than this device's own (to apply locally).
    static func newer(_ remote: File, than local: File, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [(key: String, entry: Entry)] {
        remote.progress.filter { k, e in sane(e, nowMs: nowMs) && (local.progress[k]?.at ?? -1) < e.at }
            .map { ($0.key, $0.value) }.sorted { $0.entry.at < $1.entry.at }
    }
}

// MARK: - Category names on screen (1.4.3)

/// Display form of a provider's group name: decorative letters turned into plain ones, emoji, flags and ornament
/// symbols removed, separators tidied. Only for showing — order, hiding and locks keep using the provider's id.
public enum CategoryNameRule {
    private static let smallCaps: [Character: Character] = [
        "ᴀ": "A", "ʙ": "B", "ᴄ": "C", "ᴅ": "D", "ᴇ": "E", "ꜰ": "F", "ɢ": "G", "ʜ": "H", "ɪ": "I", "ᴊ": "J", "ᴋ": "K",
        "ʟ": "L", "ᴍ": "M", "ɴ": "N", "ᴏ": "O", "ᴘ": "P", "ǫ": "Q", "ʀ": "R", "ꜱ": "S", "ᴛ": "T", "ᴜ": "U", "ᴠ": "V",
        "ᴡ": "W", "ʏ": "Y", "ᴢ": "Z",
    ]
    /// Ornaments seen around group names; treated as separators.
    private static let ornaments: Set<Character> = ["|", "┃", "│", "║", "•", "●", "◆", "◇", "■", "□", "▪", "▶", "►", "◀", "◄",
                                                    "★", "☆", "✦", "✧", "✪", "✯", "✰", "❖", "⭐", "♦", "»", "«", "~", "*", "#", "_", "=", "+"]

    public static func display(_ raw: String) -> String {
        let nfkc = raw.precomposedStringWithCompatibilityMapping      // 𝐁𝐎𝐋𝐃 / ＦＵＬＬ / ² → plain
        var out = ""
        for ch in nfkc {
            if let m = smallCaps[ch] { out.append(m); continue }
            if ornaments.contains(ch) { out.append(" "); continue }
            let scalars = ch.unicodeScalars
            if scalars.contains(where: { isDecoration($0) }) { out.append(" "); continue }
            out.append(ch)
        }
        // Collapse spaces; trim spaces and dashes / colons left at the edges.
        var words = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let f = words.first, f.allSatisfy({ "-–—:.,".contains($0) }) { words.removeFirst() }
        while let l = words.last, l.allSatisfy({ "-–—:.,".contains($0) }) { words.removeLast() }
        let s = words.joined(separator: " ")
        return s.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }

    private static func isDecoration(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if (0x1F1E6...0x1F1FF).contains(v) { return true }           // flag letters
        if (0xFE00...0xFE0F).contains(v) || v == 0x200D || v == 0x20E3 { return true } // variation selectors, joiners
        if (0x1F000...0x1FAFF).contains(v) { return true }           // emoji and pictographs
        if (0x2600...0x27BF).contains(v) { return true }             // dingbats and misc symbols
        if (0x2500...0x25FF).contains(v) { return true }             // box drawing and geometric shapes
        if (0xE0000...0xE007F).contains(v) { return true }           // tag characters (sub-flags)
        return false
    }
}

// MARK: - One work across provider copies (1.6.0)

/// Identity of a film or series independent of the provider's item id, for "Continue watching": one card per work.
/// Conservative on purpose: the cleaned title (CopyRule) plus the year when the name carries one. Two names with
/// different years never match (a remake is another work); a name with a year and one without don't match either,
/// so ambiguous copies stay separate rather than being merged by mistake. Films and series are keyed apart by the
/// caller (different prefixes).
public enum WorkRule {
    /// A 4-digit year 1900–2099 in brackets "(2022)" / "[2022]" or as the last word.
    public static func year(_ name: String) -> Int? {
        let patterns = [#"[\(\[]\s*((19|20)\d{2})\s*[\)\]]"#, #"(?:^|\s)((19|20)\d{2})\s*$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = name as NSString
            if let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                return Int(ns.substring(with: m.range(at: 1)))
            }
        }
        return nil
    }

    /// "movie|the lord of the rings the rings of power|2022"; empty when the name has no letters or digits.
    public static func key(_ name: String, kind: String) -> String {
        var base = CopyRule.key(name)
        if let y = year(name) {
            // CopyRule keeps a bare trailing year as a word; drop it so "(2022)" and "2022" give the same key.
            if base.hasSuffix(" \(y)") { base = String(base.dropLast(5)) }
            else if base == "\(y)" { base = "" }
        }
        guard !base.isEmpty else { return "" }
        return "\(kind)|\(base)|\(year(name).map(String.init) ?? "")"
    }
}

/// 1.7.5: subtitles downloaded from the internet, shared between the iPhone and the TV through Google Drive — one
/// file per film/episode, next to the sync file (which is not changed). Same rules as the TV app's SubSyncCore.
enum SubSyncRule {
    static let prefix = "shasha-sub-v1-"
    /// Owner's rule: old subtitles must not pile up. A file not updated for 30 days goes; at most 150 are kept.
    static let maxAgeMs: Int64 = 30 * 24 * 3600 * 1000
    static let maxCount = 150
    /// Clean-up runs at most once a day.
    static let pruneEveryMs: Int64 = 24 * 3600 * 1000

    /// Drive file name for a sync key (`CloudSyncRule.key`): the key itself (it holds the account hash) is not in the
    /// name, only the first 24 hex characters of its SHA-256.
    static func fileName(key: String, sha256: (String) -> String) -> String { prefix + String(sha256(key).prefix(24)) + ".srt" }

    struct Stored: Equatable { let id: String; let modifiedMs: Int64 }

    /// 1.7.7: a device that uses a shared subtitle writes "last used" to the Drive file (at most once a day), so the
    /// clean-up counts use on the other device too, not only the last upload.
    static let touchEveryMs: Int64 = 24 * 3600 * 1000
    /// The time the clean-up goes by: the later of the last upload and the last recorded use.
    static func stamp(modifiedMs: Int64, usedMs: Int64?) -> Int64 { max(modifiedMs, usedMs ?? 0) }
    static func needsTouch(usedMs: Int64?, modifiedMs: Int64, nowMs: Int64) -> Bool {
        nowMs - stamp(modifiedMs: modifiedMs, usedMs: usedMs) > touchEveryMs
    }
    /// Files to delete: every file older than 30 days, then the oldest beyond 150. A file with an unknown time
    /// (modifiedMs <= 0) counts as old.
    static func prune(_ files: [Stored], nowMs: Int64) -> [String] {
        let fresh = files.filter { $0.modifiedMs > 0 && nowMs - $0.modifiedMs <= maxAgeMs }.sorted { $0.modifiedMs > $1.modifiedMs }
        let old = files.filter { !($0.modifiedMs > 0 && nowMs - $0.modifiedMs <= maxAgeMs) }.map(\.id)
        return old + fresh.dropFirst(maxCount).map(\.id)
    }

    /// Short text for Drive's appProperties (key + value must stay under 124 bytes).
    static func clip(_ s: String, maxBytes: Int = 90) -> String {
        var out = ""
        for ch in s { if (out + String(ch)).utf8.count > maxBytes { break }; out.append(ch) }
        return out
    }
}

/// 1.7.9: subtitle identity v2 = film/episode copy (sync key: work/episode + provider id = video version) + language
/// + SHA-256 of the UTF-8 content. Compatible with v1:
/// - The v1 file (`SubSyncRule.fileName`) stays "the selected subtitle for this item": the TV app (0.9.22) and older
///   iPhone builds read and write only that one, unchanged.
/// - Each kept language also gets its own v2 file `shasha-sub-v2-<h>-<lang>.<fmt>` (h = same 24 hex as v1), marked
///   appProperties shashaSub=2 (so the TV's clean-up, which lists shashaSub=1, never sees or deletes them), item=h,
///   lang, fmt, sha. A download/import in one language never removes another language.
/// - Same content (Drive's md5Checksum = md5 of our bytes) → nothing uploaded.
/// - Replacing the selected v1 file with a different content: its old content is first kept as the v2 file of its
///   language when that copy is missing or differs (server-side copy), and the viewer is told which language was
///   replaced. A v1 file without `lang` counts as "und".
enum SubIdentityRule {
    static let prefix = "shasha-sub-v2-"
    /// 24 hex of SHA-256(sync key) — the same part as in the v1 name, so both point at the same item.
    static func itemHash(key: String, sha256: (String) -> String) -> String { String(sha256(key).prefix(24)) }

    /// A language tag safe for a file name: "ar", "en", "pt-br", "zh-cn"…; anything else (empty, "?", names,
    /// symbols) → "und".
    static func lang(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0 >= "a" && $0 <= "z" }),
              parts.count <= 2 else { return "und" }
        if parts.count == 2 {
            let r = parts[1]
            guard (2...8).contains(r.count), r.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) else { return String(first) }
        }
        return s
    }

    static func fileName(key: String, lang: String, format: String, sha256: (String) -> String) -> String {
        prefix + itemHash(key: key, sha256: sha256) + "-" + self.lang(lang) + "." + (format == "ass" ? "ass" : "srt")
    }

    /// (item hash, lang, format) of a v2 name; nil for anything else (v1 names included).
    static func parse(_ name: String) -> (item: String, lang: String, format: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dot = rest.lastIndex(of: "."), let dash = rest.firstIndex(of: "-"), dash < dot else { return nil }
        let item = String(rest[..<dash]), lang = String(rest[rest.index(after: dash)..<dot]), fmt = String(rest[rest.index(after: dot)...])
        guard item.count == 24, item.allSatisfy({ $0.isHexDigit }), self.lang(lang) == lang, fmt == "srt" || fmt == "ass" else { return nil }
        return (item, lang, fmt)
    }

    /// What is on Drive for one item before keeping a new subtitle.
    struct Remote: Equatable { let lang: String; let md5: String? }

    /// What to do on Drive to keep a new subtitle (`lang`, content `md5`) for one item.
    struct Plan: Equatable {
        /// Copy the current v1 content to the v2 file of this language first (it would be lost otherwise).
        var preserveOldAs: String?
        var putV2 = false
        var putV1 = false
        /// Language of the selected subtitle that is being replaced by one in another language (told to the viewer).
        var replacedLang: String?
        /// A different subtitle in the same language is replaced (one copy per language and item).
        var replacedSameLang = false
    }

    static func plan(lang rawLang: String, md5: String, v1: Remote?, v2: [String: String?]) -> Plan {
        let lang = self.lang(rawLang)
        var p = Plan()
        // v2 copy of this language: missing or different content → upload. Unknown md5 on Drive → upload (safe).
        let mine = v2[lang] ?? nil
        p.putV2 = mine == nil || mine! != md5
        if let old = mine, old != md5 { p.replacedSameLang = true }
        guard let v1 else { p.putV1 = true; return p }
        let oldLang = self.lang(v1.lang)
        if let m = v1.md5, m == md5 { return p }          // already the selected one
        p.putV1 = true
        if oldLang == lang {
            p.replacedSameLang = true
            return p                                     // same slot: the new choice replaces it
        }
        p.replacedLang = oldLang
        let kept = v2[oldLang] ?? nil
        if v1.md5 == nil || kept == nil || kept! != v1.md5! { p.preserveOldAs = oldLang }
        return p
    }

    /// Drive clean-up for v2 files (`shashaSub=2`), separate from v1 (whose rule the TV shares): a v2 file counts as
    /// used whenever the v1 file of its item holds the same content (the selected one is used through v1 only).
    /// Same 30 days; up to twice as many files as v1.
    struct Listed: Equatable { let id: String; let name: String; let stampMs: Int64; let md5: String? }
    static let maxCount = SubSyncRule.maxCount * 2
    static func prune(v2: [Listed], v1: [Listed], nowMs: Int64, v1Name: (String) -> String = { SubSyncRule.prefix + $0 + ".srt" }) -> [String] {
        let byName = Dictionary(v1.map { ($0.name, $0) }, uniquingKeysWith: { a, b in a.stampMs >= b.stampMs ? a : b })
        let stamped = v2.map { f -> SubSyncRule.Stored in
            var st = f.stampMs
            if let p = parse(f.name), let sel = byName[v1Name(p.item)], let m = f.md5, m == sel.md5 { st = max(st, sel.stampMs) }
            return SubSyncRule.Stored(id: f.id, modifiedMs: st)
        }
        let fresh = stamped.filter { $0.modifiedMs > 0 && nowMs - $0.modifiedMs <= SubSyncRule.maxAgeMs }.sorted { $0.modifiedMs > $1.modifiedMs }
        let old = stamped.filter { !($0.modifiedMs > 0 && nowMs - $0.modifiedMs <= SubSyncRule.maxAgeMs) }.map(\.id)
        return old + fresh.dropFirst(maxCount).map(\.id)
    }

    /// Readable language for the viewer.
    static func display(_ lang: String) -> String {
        switch self.lang(lang) {
        case "ar": return "العربية"
        case "en": return "الإنجليزية"
        case "fr": return "الفرنسية"
        case "und": return "لغة غير معروفة"
        case let l: return l
        }
    }
}

/// 1.7.6: checks a subtitle file before it is used, kept or shared — imported by the viewer or downloaded.
/// Content first (not the file name): SRT (timestamps with -->) or ASS/SSA ([Script Info] + [Events] + Dialogue).
/// Text is decoded (UTF-8 / UTF-16 with BOM, else Windows-1256 for older Arabic files) and kept as UTF-8, so ASS
/// styles and tags are untouched. Limits per format: SRT is plain text (a feature film is well under 1 MB); ASS may
/// carry embedded fonts, so it gets more room.
enum SubFileCheck {
    enum Format: String { case srt, ass }
    struct Checked: Equatable { let format: Format; let text: String; let lang: String }
    enum Problem: Error, Equatable {
        case empty, tooBig(bytes: Int, limit: Int), binary, unknownEncoding, notSubtitle, unsupported(String)
    }
    static let maxSRTBytes = 8 * 1024 * 1024
    static let maxASSBytes = 40 * 1024 * 1024
    /// Before decoding: nothing above the larger limit is even read as text.
    static var maxBytes: Int { maxASSBytes }

    static func check(_ data: Data) -> Result<Checked, Problem> {
        if data.isEmpty { return .failure(.empty) }
        if data.count > maxBytes { return .failure(.tooBig(bytes: data.count, limit: maxBytes)) }
        guard let text = decode(data) else { return .failure(.unknownEncoding) }
        if text.contains("\u{0}") { return .failure(.binary) }
        let head = String(text.prefix(4096)).lowercased()
        let format: Format
        if head.contains("[script info]") && text.range(of: "[Events]", options: .caseInsensitive) != nil
            && text.range(of: "Dialogue:", options: .caseInsensitive) != nil {
            format = .ass
        } else if text.range(of: #"\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}"#, options: .regularExpression) != nil {
            if head.hasPrefix("webvtt") { return .failure(.unsupported("WebVTT")) }
            format = .srt
        } else {
            return .failure(.notSubtitle)
        }
        let limit = format == .ass ? maxASSBytes : maxSRTBytes
        if data.count > limit { return .failure(.tooBig(bytes: data.count, limit: limit)) }
        return .success(Checked(format: format, text: text, lang: guessLang(text)))
    }

    static func decode(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(3))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(data: data.dropFirst(3), encoding: .utf8) }
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s }
        let arabic = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: arabic))
    }

    /// "ar" when most letters are Arabic, else "und" (unknown). Only a hint for the label.
    static func guessLang(_ text: String) -> String {
        var arabic = 0, letters = 0
        for u in text.unicodeScalars.prefix(20_000) where CharacterSet.letters.contains(u) {
            letters += 1
            if (0x0600...0x06FF).contains(u.value) || (0x0750...0x077F).contains(u.value) || (0xFB50...0xFEFF).contains(u.value) { arabic += 1 }
        }
        return letters > 0 && arabic * 2 > letters ? "ar" : "und"
    }

    /// Why a file was refused, for the viewer.
    static func text(_ p: Problem) -> String {
        switch p {
        case .empty: return "الملف فارغ"
        case .tooBig(let b, let l): return "الملف أكبر من المسموح (\(b / 1024) KB، الحد \(l / 1024 / 1024) MB)"
        case .binary: return "الملف ليس نصًا (قد يكون أرشيفًا مضغوطًا — فكّه أولًا من تطبيق الملفات)"
        case .unknownEncoding: return "ترميز الملف غير معروف"
        case .notSubtitle: return "الملف ليس ترجمة SRT أو ASS"
        case .unsupported(let f): return "صيغة \(f) غير مدعومة بعد — استخدم SRT أو ASS"
        }
    }
}

/// 1.7.8: subtitle delay kept on this phone per film/episode copy (video version = provider id) AND per subtitle:
/// an added file by the SHA-256 of its content, an embedded track by its number and language. Not shared between
/// devices. Old entries go once there are more than `maxEntries` (oldest use first).
enum SubDelayRule {
    static let maxEntries = 500
    static func key(item: String, subtitle: String) -> String { item + "|" + subtitle }
    static func fileIdent(sha256: String) -> String { "sha:" + String(sha256.prefix(32)) }
    static func trackIdent(id: String, lang: String) -> String { "track:" + id + ":" + lang }
    struct Entry: Equatable { var delay: Double; var usedMs: Int64 }
    /// Keys to drop: the oldest beyond the limit.
    static func prune(_ d: [String: Entry], max: Int = maxEntries) -> [String] {
        guard d.count > max else { return [] }
        return d.sorted { $0.value.usedMs < $1.value.usedMs }.prefix(d.count - max).map(\.key)
    }
}

/// Match-guide report (iPhone side of the TV's MatchGuideCore — same rules and test vectors, docs/MATCH-GUIDE.md).
/// Football matches found in the provider's programme guide («دليل برامج المزوّد»). Teams + time is a strong hint,
/// not proof the channel shows the match live; each programme is classified from its own words and length.
/// Versions are ranked from the NAME only (4K → 1080p → 720p/HD → SD → unknown); HEVC is a codec badge, RAW a
/// provider label. A UHD channel is never assumed to show what its HD sibling shows (each counts by its own guide).
enum MatchGuideRule {
    private static let sportWords = [
        "sport", "sports", "رياض", "bein", "ssc", "alkass", "al kass", "الكاس", "ad sport", "abu dhabi sport", "dubai sport",
        "sharjah sport", "dazn", "espn", "eurosport", "sky sport", "tnt sport", "bt sport", "arena sport", "sportklub",
        "sport klub", "supersport", "star sports", "sony ten", "setanta", "movistar", "laliga", "canal+ sport", "rmc sport",
        "fox sports", "tudn", "tyc", "premier sports", "nova sport", "cosmote", "digi sport", "polsat sport", "match!",
        "viaplay", "football", "futbol", "fútbol", "futebol", "calcio", "kora", "كورة", "on time sports",
        "thmanyah", "ثمانية", "shahid sport", "mbc action", "ksa sport", "kss", "oman sport", "bahrain sport", "kuwait sport",
        "qatar sport", "iraq sport", "sport tv", "ziggo sport", "sportdigital", "magenta sport", "ssport", "s sport",
        "tivibu spor", "beın", "spor", "sportitalia", "sportv", "premiere", "fanatiz", "win sports", "directv sports",
    ]
    static func isSportsChannel(name: String, group: String) -> Bool {
        let s = (name + " | " + group).lowercased()
        return sportWords.contains { s.contains($0) }
    }

    enum Res: Int, Comparable {
        case uhd = 0, fhd, hd, sd, unknown
        static func < (a: Res, b: Res) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["4K", "1080p", "720p/HD", "SD", "غير معروفة"][rawValue] }
    }
    struct Version: Equatable {
        let res: Res; let hevc: Bool; let raw: Bool
        func label() -> String {
            [res.label, hevc ? "HEVC" : nil, raw ? "RAW" : nil].compactMap { $0 }.joined(separator: " · ") + (res != .unknown ? " (من الاسم)" : "")
        }
    }
    static func version(_ name: String) -> Version {
        let up = name.uppercased()
        let t = Set(up.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "+") }).map(String.init))
        let res: Res
        if t.contains("4K") || t.contains("UHD") || t.contains("2160P") || t.contains("2160") { res = .uhd }
        else if t.contains("FHD") || t.contains("1080P") || t.contains("1080") || t.contains("FULLHD") { res = .fhd }
        else if t.contains("HD") || t.contains("720P") || t.contains("720") { res = .hd }
        else if t.contains("SD") || t.contains("576P") || t.contains("480P") { res = .sd }
        else { res = .unknown }
        return Version(res: res, hevc: t.contains("HEVC") || t.contains("H265") || t.contains("X265") || up.contains("H.265"), raw: t.contains("RAW"))
    }

    struct Teams: Equatable { let home: String; let away: String }
    private static let separators = [" vs. ", " vs ", " v ", " v. ", " x ", " × ", " ضد ", " – ", " — ", " - "]
    private static let nonTeamWords: Set<String> = ["news", "edition", "episode", "ep", "part", "season", "show", "live", "highlights",
        "magazine", "weekly", "daily", "special", "documentary", "نشرة", "حلقة", "برنامج", "الجزء", "موسم", "أخبار", "اخبار"]

    static func teams(_ title: String) -> Teams? {
        var s = title.trimmingCharacters(in: .whitespaces)
        let lead = #"^\s*(?:\[[^\]]*\]|\([^)]*\)|(?:live|en vivo|en direct|ao vivo|direct|مباشر|مباشرة|canlı|dal vivo)\s*[:\-–|]?)\s*"#
        for _ in 0..<3 { if let r = s.range(of: lead, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) } }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "：" }).map(String.init)
        guard let seg = parts.last(where: { p in separators.contains { p.range(of: $0, options: .caseInsensitive) != nil } }) else { return nil }
        s = seg.trimmingCharacters(in: .whitespaces)
        guard let sep = separators.first(where: { s.range(of: $0, options: .caseInsensitive) != nil }),
              let r = s.range(of: sep, options: .caseInsensitive) else { return nil }
        var a = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var b = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if sep != " - " {
            for d in [" - ", " – ", " — "] { if let x = b.range(of: d) { b = String(b[..<x.lowerBound]) } }
            b = b.trimmingCharacters(in: .whitespaces)
        }
        let tail = #"\s*(?:\([^)]*\)|\[[^\]]*\]|\|.*)$"#
        if let x = a.range(of: tail, options: .regularExpression) { a.removeSubrange(x) }
        if let x = b.range(of: tail, options: .regularExpression) { b.removeSubrange(x) }
        a = a.trimmingCharacters(in: .whitespaces); b = b.trimmingCharacters(in: .whitespaces)
        func ok(_ x: String) -> Bool { (2...40).contains(x.count) && x.contains { $0.isLetter } && x.split(separator: " ").count <= 6 }
        let weak = ["-", "–", "—"].contains(sep.trimmingCharacters(in: .whitespaces))
        func showLike(_ x: String) -> Bool {
            x.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil ||
            x.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { nonTeamWords.contains(String($0)) }
        }
        if weak && (showLike(a) || showLike(b)) { return nil }
        return ok(a) && ok(b) && a.lowercased() != b.lowercased() ? Teams(home: a, away: b) : nil
    }

    enum Kind: Int, CaseIterable {
        case live, replay, studio, unknown
        var label: String { ["مباشر", "إعادة/ملخص", "استوديو", "غير محدد"][rawValue] }
    }
    private static let liveWords = ["live", "en vivo", "en direct", "ao vivo", "مباشر", "canlı", "dal vivo", "(l)", "[l]", "live:"]
    private static let replayWords = ["replay", "rerun", "re-run", "repeat", "re-air", "delayed", "highlights", "إعادة", "اعادة", "ملخص",
        "أهداف", "(r)", "[r]", "rediffusion", "repetición", "reprise", "tekrar", "classic", "كلاسيكو قديم", "best of"]
    private static let studioWords = ["studio", "استوديو", "ستوديو", "preview", "pre-match", "prematch", "post-match", "build-up", "buildup",
        "magazine", "countdown", "تحليل", "قبل المباراة", "بعد المباراة", "review", "debate", "talk show"]

    static func kind(title: String, description: String?, minutes: Int64) -> Kind {
        let t = (" " + title + " ").lowercased()
        let d = (description ?? "").lowercased()
        if replayWords.contains(where: { t.contains($0) }) { return .replay }
        if studioWords.contains(where: { t.contains(" " + $0) || (t.contains($0) && $0.unicodeScalars.contains { $0.value > 127 }) }) { return .studio }
        if liveWords.contains(where: { t.contains($0) }) { return .live }
        if replayWords.contains(where: { d.contains($0) }) { return .replay }
        if liveWords.contains(where: { d.contains($0) }) && minutes >= 80 { return .live }
        return .unknown
    }

    private static let clubWords: Set<String> = ["fc", "cf", "sc", "afc", "ac", "cd", "ud", "sd", "club", "sk", "fk", "nk", "bk", "if", "the"]
    private static let womenWords: Set<String> = ["women", "womens", "w", "ladies", "femenino", "feminine", "féminine", "frauen", "سيدات", "للسيدات", "نساء", "wfc"]

    static func teamKey(_ name: String) -> String {
        var n = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        n = n.replacingOccurrences(of: #"u-(\d{2})"#, with: "u$1", options: .regularExpression)
        n = n.replacingOccurrences(of: #"تحت\s*(\d{2})"#, with: "u$1", options: .regularExpression)
        let words = n.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        var markers = Set<String>(); var core: [String] = []
        for w in words {
            if womenWords.contains(w) { markers.insert("women") }
            else if let m = w.range(of: #"^(?:u|sub|under|تحت)-?(\d{2})$"#, options: .regularExpression) {
                markers.insert("u" + w[m].filter(\.isNumber))
            } else if clubWords.contains(w) { continue }
            else { core.append(w) }
        }
        return (core.joined(separator: " ") + markers.sorted().map { "#" + $0 }.joined()).trimmingCharacters(in: .whitespaces)
    }

    struct Entry: Equatable { let channel: String; let source: String; let start: Int64; let stop: Int64; let title: String; let teams: Teams; let kind: Kind }
    struct Group { let key: String; let home: String; let away: String; let start: Int64; let entries: [Entry]
        var live: Bool { entries.contains { $0.kind == .live } } }

    static func group(_ entries: [Entry], windowMs: Int64 = 45 * 60_000) -> [Group] {
        let byPair = Dictionary(grouping: entries) { e in [teamKey(e.teams.home), teamKey(e.teams.away)].sorted().joined(separator: " | ") }
        var out: [Group] = []
        for (pair, list) in byPair {
            var cur: [Entry] = []
            for e in list.sorted(by: { $0.start < $1.start }) {
                if let f = cur.first, e.start - f.start > windowMs {
                    out.append(Group(key: pair, home: f.teams.home, away: f.teams.away, start: f.start, entries: cur)); cur = []
                }
                cur.append(e)
            }
            if let f = cur.first { out.append(Group(key: pair, home: f.teams.home, away: f.teams.away, start: f.start, entries: cur)) }
        }
        return out.sorted { $0.start < $1.start }
    }
}
