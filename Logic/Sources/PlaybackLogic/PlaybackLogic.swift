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
    }
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
    static func merge(_ a: File, _ b: File, limit: Int = 3000) -> File {
        var out = a.progress
        for (k, e) in b.progress { if let o = out[k], o.at >= e.at { continue }; out[k] = e }
        if out.count > limit {
            let keep = out.sorted { $0.value.at > $1.value.at }.prefix(limit)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return File(v: 1, progress: out)
    }

    /// Entries of `remote` that are newer than this device's own (to apply locally).
    static func newer(_ remote: File, than local: File) -> [(key: String, entry: Entry)] {
        remote.progress.filter { k, e in (local.progress[k]?.at ?? -1) < e.at }.map { ($0.key, $0.value) }.sorted { $0.entry.at < $1.entry.at }
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
