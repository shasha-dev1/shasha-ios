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

// MARK: - 1.10.4 / 1.10.5 (owner 20:50, 21:17, 21:18): competition → territory → rights holder (TV RightsCore 0.9.58)

/// Rights say who MAY show a competition in a country; never which channel shows a match. The channels of a match come only
/// from a schedule or the EPG («القنوات الناقلة»); a holder whose network is in the library is a shortcut to its versions
/// there (4K first), opened by hand. Each record keeps its source, season, stated contract and kind of rights; a technical
/// season window only marks a match outside it; unverified territories are missing data, never guessed.
enum RightsRule {
    struct BadFile: Error { let reason: String }
    struct Source: Equatable {
        let url: String, title: String, publisher: String, kind: String, retrievedAt: String
        var label: String { "\(publisher) (\(kind == "official" ? "رسمي" : "مصدر ثانوي"))" }
    }
    struct Holder: Equatable {
        let name: String, entity: String, rights: [String], channels: [String], brands: [String]
        let brandsFrom: String?, sublicence: String?, note: String?
        var highlightsOnly: Bool { !rights.isEmpty && rights.allSatisfy { $0 == "highlights" } }
        var entityLabel: String? { ["company": "شركة", "platform": "منصة", "channel": "قناة"][entity] }
        var rightsLabel: String { rights.compactMap { ["live": "مباشر", "highlights": "ملخصات", "digital": "رقمي", "selected": "مباريات مختارة", "unspecified": "نوع الحقوق غير مذكور في المصدر"][$0] }.joined(separator: " · ") }
    }
    struct Territory: Equatable {
        let territory: String, region: String?, countries: [String], status: String, source: Source?, contract: String?, note: String?, holders: [Holder]
        /// 1.10.5: the season this record states when it differs from the file's (Lega Serie A's page says 2025/26).
        var season: String? = nil
        var verified: Bool { status == "verified" }
    }
    struct Rights: Equatable {
        let competition: String, keys: [String], excludes: [String], season: String
        let windowFrom: Int64?, windowTo: Int64?
        let source: Source, territories: [Territory]
        var label: String { "\(source.label) · موسم \(season)" }
    }

    private static func day(_ s: String) -> Int64? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970 * 1000) }
    }
    private static func src(_ o: [String: Any]?) -> Source? {
        guard let o else { return nil }
        return Source(url: o["url"] as? String ?? "", title: o["title"] as? String ?? "", publisher: o["publisher"] as? String ?? "",
                      kind: o["kind"] as? String ?? "", retrievedAt: o["retrievedAt"] as? String ?? "")
    }
    private static func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }

    static func parse(_ data: Data) throws -> Rights {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BadFile(reason: "ليس JSON") }
        guard o["format"] as? String == "shasha-rights", let v = o["version"] as? Int, (1...2).contains(v) else { throw BadFile(reason: "ليس ملف shasha-rights الإصدار 1 أو 2") }
        guard let c = o["competition"] as? [String: Any], let source = src(o["source"] as? [String: Any]), !source.url.isEmpty,
              let season = o["season"] as? String, let ts = o["territories"] as? [[String: Any]] else { throw BadFile(reason: "حقول ناقصة") }
        let terr = ts.map { t -> Territory in
            let hs = (t["holders"] as? [[String: Any]] ?? []).map { h -> Holder in
                var rights = h["rights"] as? [String] ?? []
                if rights.isEmpty { rights = (h["highlightsOnly"] as? Bool ?? false) ? ["highlights"] : ["live"] }   // v1
                return Holder(name: h["name"] as? String ?? "", entity: h["entity"] as? String ?? "unknown", rights: rights, channels: h["channels"] as? [String] ?? [],
                              brands: h["brands"] as? [String] ?? [], brandsFrom: str(h["brandsFrom"]), sublicence: str(h["sublicence"]), note: str(h["note"]))
            }
            return Territory(territory: t["territory"] as? String ?? "", region: str(t["region"]), countries: t["countries"] as? [String] ?? [],
                             status: t["status"] as? String ?? "verified", source: src(t["source"] as? [String: Any]), contract: str(t["contract"]),
                             note: str(t["note"]), holders: hs, season: str(t["season"]))
        }
        let win = o["technicalWindow"] as? [String: Any]
        let wf = (str(win?["from"]) ?? str(o["validFrom"])).flatMap(day)
        let wt = (str(win?["to"]) ?? str(o["validTo"])).flatMap(day).map { $0 + 86_400_000 - 1 }
        return Rights(competition: c["name"] as? String ?? "", keys: (c["keys"] as? [String] ?? []).map(MatchGuideRule.words),
                      excludes: (c["excludes"] as? [String] ?? []).map(MatchGuideRule.words), season: season, windowFrom: wf, windowTo: wt,
                      source: source, territories: terr)
    }

    /// About this competition: a key's words in its name, no excluded word (the season never hides rights).
    static func appliesTo(_ r: Rights, competition: String?) -> Bool {
        guard let competition else { return false }
        return appliesToWords(r, " " + MatchGuideRule.words(competition) + " ")
    }

    struct Fact: Equatable {
        let rights: Rights; let territory: Territory; let holder: Holder
        var library: [MatchSourcesRule.LibCh] = []
        var outsideSeason = false
        var inLibrary: Int { library.count }
        var source: Source { territory.source ?? rights.source }
        static func == (a: Fact, b: Fact) -> Bool { a.rights == b.rights && a.territory == b.territory && a.holder == b.holder && a.library.map(\.id) == b.library.map(\.id) }
    }

    private static let holderAlias = ["telefonica": "Movistar", "digi": "Digi Sport", "tnt sports": "TNT", "cyta": "Cytavision"]
    static func holderNetwork(_ name: String) -> String { holderAlias[MatchGuideRule.words(name)] ?? MatchGuideRule.network(name) }
    static func holderNetworks(_ h: Holder) -> [String] {
        let b = h.brands.map { let n = MatchGuideRule.network($0); return n == "أخرى" ? $0 : n }
        return b.isEmpty ? [holderNetwork(h.name)] : b
    }
    private static let missing = Holder(name: "", entity: "unknown", rights: [], channels: [], brands: [], brandsFrom: nil, sublicence: nil, note: nil)

    static func facts(_ all: [Rights], competitions: [String?], kickoff: Int64, idx: MatchSourcesRule.LibIndex? = nil,
                      quality: @escaping (String) -> Int = { _ in 0 }) -> [Fact] {
        facts(all, competitions: competitions, kickoff: kickoff, cache: Cache(idx: idx, quality: quality))
    }

    /// 1.10.6 (owner 22:26, TV 0.9.59): a rights file's facts and each holder's library versions are the same for every match
    /// of the competition — worked out once per merge (quality and competition words memoized), not once per match.
    final class Cache {
        let idx: MatchSourcesRule.LibIndex?
        private let quality: (String) -> Int
        private var byFile: [Int: [Fact]] = [:]
        private var q: [String: Int] = [:]
        private var w: [String: String] = [:]
        init(idx: MatchSourcesRule.LibIndex?, quality: @escaping (String) -> Int) { self.idx = idx; self.quality = quality }
        func qualityOf(_ n: String) -> Int { if let v = q[n] { return v }; let v = quality(n); q[n] = v; return v }
        func words(_ s: String) -> String { if let v = w[s] { return v }; let v = " " + MatchGuideRule.words(s) + " "; w[s] = v; return v }
        func base(_ i: Int, _ r: Rights) -> [Fact] { if let v = byFile[i] { return v }; let v = RightsRule.baseFacts(r, cache: self); byFile[i] = v; return v }
    }

    static func appliesToWords(_ r: Rights, _ w: String) -> Bool {
        if r.excludes.contains(where: { !$0.isEmpty && w.contains(" \($0) ") }) { return false }
        return r.keys.contains { !$0.isEmpty && w.contains(" \($0) ") }
    }

    static func facts(_ all: [Rights], competitions: [String?], kickoff: Int64, cache: Cache) -> [Fact] {
        Array(parts(all, competitions: competitions, kickoff: kickoff, cache: cache).joined())
    }

    /// The facts of each applicable file as the cache keeps them: the same array for every match (no copy per match).
    static func parts(_ all: [Rights], competitions: [String?], kickoff: Int64, cache: Cache) -> [[Fact]] {
        var out: [[Fact]] = []
        let ws = Array(Set(competitions.compactMap { $0 })).map(cache.words)
        for (i, r) in all.enumerated() where ws.contains(where: { appliesToWords(r, $0) }) {
            var outside = false
            if let a = r.windowFrom, let b = r.windowTo { outside = kickoff < a || kickoff > b }
            let base = cache.base(i, r)
            out.append(outside ? base.map { var f = $0; f.outsideSeason = true; return f } : base)
        }
        return out
    }

    fileprivate static func baseFacts(_ r: Rights, cache: Cache) -> [Fact] {
        var out: [Fact] = []; var seen = Set<String>(); var netSource: [String: String] = [:]
        var byNetCountry: [String: [MatchSourcesRule.LibCh]] = [:]
        func lib(_ net: String, _ countries: [String]) -> [MatchSourcesRule.LibCh] {
            let k = net + "|" + countries.sorted().joined(separator: ",")
            if let v = byNetCountry[k] { return v }
            let v = (cache.idx?.byNet[net] ?? []).filter { $0.origin.firm && countries.contains($0.origin.country ?? "") }.map(\.ch)
            byNetCountry[k] = v; return v
        }
        for t in r.territories {
            if !t.verified {
                if seen.insert("?|" + t.territory).inserted { out.append(Fact(rights: r, territory: t, holder: missing)) }
                continue
            }
            for h in t.holders {
                // UEFA lists «Middle East/North Africa» and «MENA» both: one fact per holder and country set
                guard seen.insert(h.name + "|" + t.countries.sorted().joined(separator: ",") + "|" + (t.countries.isEmpty ? t.territory : "")).inserted else { continue }
                let nets = holderNetworks(h).filter { $0 != "أخرى" }
                // the same network for the same country from a second source (Cyta's page and LaLiga's list): the first record stands
                if !nets.isEmpty && !t.countries.isEmpty {
                    let nk = "net|" + nets.sorted().joined(separator: ",") + "|" + t.countries.sorted().joined(separator: ",")
                    let src = (t.source ?? r.source).url
                    if let o = netSource[nk], o != src { continue }
                    if netSource[nk] == nil { netSource[nk] = src }
                }
                var l: [MatchSourcesRule.LibCh] = []
                if cache.idx != nil, !nets.isEmpty, !t.countries.isEmpty, !h.highlightsOnly {
                    var ids = Set<String>()
                    for n in nets { for c in lib(n, t.countries) where ids.insert(c.id).inserted { l.append(c) } }
                    l.sort { (cache.qualityOf($0.name), $0.name) < (cache.qualityOf($1.name), $1.name) }
                }
                out.append(Fact(rights: r, territory: t, holder: h, library: l))
            }
        }
        return out
    }

    static func passes(_ f: Fact, country: String?) -> Bool { country == nil || f.territory.countries.contains(country!) || f.territory.territory == country }

    static func noteFor(_ facts: [Fact], channelName: String, country: String?, firm: Bool) -> String? {
        noteFor([facts], channelName: channelName, country: country, firm: firm)
    }
    static func noteFor(_ parts: [[Fact]], channelName: String, country: String?, firm: Bool) -> String? {
        guard parts.contains(where: { !$0.isEmpty }), let country, firm else { return nil }
        let here = parts.joined().filter { $0.territory.countries.contains(country) && $0.territory.verified && !$0.holder.highlightsOnly }
        guard let first = here.first else { return nil }
        let net = MatchGuideRule.network(channelName)
        if net != "أخرى", let hit = here.first(where: { holderNetworks($0.holder).contains(net) }) {
            return "صاحب حقوق البطولة في \(hit.territory.territory): \(hit.holder.name) (\(hit.source.label) · موسم \(hit.territory.season ?? hit.rights.season))"
        }
        return "لم نجدها ضمن قائمة الحقوق المستخدمة لـ\(first.territory.territory) (\(first.source.label)) — غيابها لا يثبت أنها غير مرخّصة"
    }

    static func competitionsOf(_ r: MatchSourcesRule.Row) -> [String?] {
        [r.competition] + (r.group?.entries ?? []).flatMap { [$0.competition, $0.title] }
    }

    static func annotate(_ rows: [MatchSourcesRule.Row], _ all: [Rights], idx: MatchSourcesRule.LibIndex?,
                         quality: @escaping (String) -> Int = { _ in 0 }) -> [MatchSourcesRule.Row] {
        if all.isEmpty { return rows }
        var origins: [String: MatchSourcesRule.Origin] = [:]
        if let idx { for l in idx.byNet.values { for e in l { origins[e.ch.id] = e.origin } } }
        let cache = Cache(idx: idx, quality: quality)
        return rows.map { r in
            let f = parts(all, competitions: competitionsOf(r), kickoff: r.kickoff ?? r.start, cache: cache)
            if !f.contains(where: { !$0.isEmpty }) { return r }
            var x = r
            x.rightsParts = f
            x.links = r.links.map { l in
                if l.proofs.allSatisfy({ $0.kind == .candidate }) { return l }
                let o = origins[l.channelId]
                let pc = MatchGuideRule.country(l.name)
                let country = o?.country ?? ((pc == "بدون بادئة" || pc.hasPrefix("تسمية")) ? nil : pc)
                var y = l; y.rightsNote = noteFor(f, channelName: l.name, country: country, firm: o?.firm ?? (country != nil)); return y
            }
            return x
        }
    }

    static func holderLine(_ f: Fact) -> String {
        [f.holder.entityLabel, f.holder.rightsLabel.isEmpty ? nil : f.holder.rightsLabel, f.holder.sublicence.map { "ترخيص فرعي: " + $0 }, f.holder.note,
         f.territory.contract.map { "العقد: " + $0 } ?? "موسم \(f.territory.season ?? f.rights.season)", f.outsideSeason ? "المباراة خارج موسم الملف (تقدير تقني)" : nil,
         (f.holder.brandsFrom == "shasha" && !f.holder.brands.isEmpty) ? "أسماء القنوات في القوائم: \(f.holder.brands.joined(separator: "، ")) (ربطنا)" : nil,
         f.source.label].compactMap { $0 }.joined(separator: " · ")
    }

    static func load(_ urls: [URL]) -> (ok: [Rights], bad: [String]) {
        var ok: [Rights] = [], bad: [String] = []
        for u in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do { ok.append(try parse(Data(contentsOf: u))) } catch { bad.append(u.lastPathComponent + ": " + ((error as? BadFile)?.reason ?? "تعذّر")) }
        }
        return (ok, bad)
    }
}

// MARK: - 1.10.3 (owner 19:37): reports — no playback links at all, no account data anywhere (same rules as the TV's Redact)

enum RedactRule {
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let urlRe = rx(#"\b[a-z][a-z0-9+.\-]{1,15}://[^\s"'<>«»()\[\]]+"#)
    private static let playback = rx(#"(\.(m3u8?|ts|mp4|mkv|avi|mov|mpd|flv|aac|mp3)(\?|#|$)|/(live|movie|movies|series|timeshift|streaming|hls|play)/|get\.php|player_api\.php|xmltv\.php|panel_api\.php|/c/|portal\.php|stalker)"#)
    private static let credParam = rx(#"[?&;](user(name)?|login|pass(word)?|pwd|token|auth|key|api_?key|secret|sig(nature)?|session|sid|mac)="#)
    private static let xtreamPath = rx(#"/[^/]+/[^/]+/\d+(\.[a-z0-9]+)?$"#)
    private static let ipHost = rx(#"^\d{1,3}(\.\d{1,3}){3}$"#)
    private static let credText = rx(#"\b(user(name)?|login|pass(word)?|pwd|token|api_?key|secret|auth(orization)?)\s*[=:]\s*("[^"]*"|[^\s&,;]+)"#)
    private static let userAt = rx(#"\b[\w.+%\-]+:[^\s@/]+@[\w.\-]+"#)
    private static let bareIp = rx(#"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"#)
    private static func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A link in a report: playback / account links removed entirely; any other one as its host only (an IP host hidden too).
    static func link(_ raw: String) -> String {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)), let host = c.host, !host.isEmpty else { return "[رابط محذوف]" }
        let path = c.percentEncodedPath
        let scheme = (c.scheme ?? "").lowercased()
        if c.user != nil || c.password != nil || has(playback, raw) || has(credParam, raw) || has(xtreamPath, path)
            || ["rtmp", "rtmps", "rtsp", "rtp", "udp", "mms", "srt"].contains(scheme) { return "[رابط تشغيل أو حساب محذوف]" }
        if has(ipHost, host) { return "[خادم محذوف]" }
        return "\(scheme)://\(host)" + ((!path.isEmpty && path != "/") || c.percentEncodedQuery != nil ? "/…" : "")
    }

    /// Any report text, error messages included: every link through `link`, credentials and server addresses removed.
    static func text(_ s: String) -> String {
        let ns = s as NSString
        var out = ""; var last = 0
        for m in urlRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += link(ns.substring(with: m.range)); last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        func sub(_ r: NSRegularExpression, _ t: String, _ x: String) -> String { r.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: x) }
        out = sub(userAt, out, "[حساب محذوف]")
        out = sub(credText, out, "$1=•••")
        return sub(bareIp, out, "[خادم محذوف]")
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
        return RedactRule.text(s)      // 1.10.3: also credentials and server addresses in the remaining text
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

/// Matches found in the provider's programme guide («دليل برامج المزوّد») — rules v2, the iPhone side of the TV's
/// MatchGuideCore: same rules and test vectors (docs/MATCH-GUIDE.md). Teams + time is a strong hint, not proof the
/// channel shows the match live. Each programme is classified from its own guide entry: kind (tagged live / replay /
/// studio / not stated — "not stated" is never turned into live) and sport (football / another named sport / unknown,
/// from the title, description and guide category, then the channel's own name; a team name alone never decides).
/// Versions are ranked from the NAME only (4K → 1080p → 720p/HD → SD → unknown), after folding decorated letters
/// (ᴴᴰ ʰᵉᵛᶜ ʜᴅ, ⚽ for O). HEVC is a codec badge, RAW a provider label. A leading "8K:"-style prefix is a group label
/// only for a source where its own channel names show it (prefixLabels).
enum MatchGuideRule {
    // ---------- folding ----------

    private static let smallCaps: [Character: Character] = [
        "ᴀ": "a", "ʙ": "b", "ᴄ": "c", "ᴅ": "d", "ᴇ": "e", "ꜰ": "f", "ɢ": "g", "ʜ": "h", "ɪ": "i", "ᴊ": "j",
        "ᴋ": "k", "ʟ": "l", "ᴍ": "m", "ɴ": "n", "ᴏ": "o", "ᴘ": "p", "ʀ": "r", "ꜱ": "s", "ᴛ": "t", "ᴜ": "u",
        "ᴠ": "v", "ᴡ": "w", "ʏ": "y", "ᴢ": "z", "⚽": "o",
    ]

    /// Display letters → plain letters: NFKC (ᴴᴰ → HD, ³⁸⁴⁰ᴾ → 3840P, fullwidth), small capitals, ⚽ → o. Case kept.
    static func foldName(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.map { smallCaps[$0] ?? $0 })
    }

    /// For word matching: folded, lower case, without accents, a few letters that don't decompose, Arabic forms unified.
    static func foldWords(_ s: String) -> String {
        let n = foldName(s).lowercased().decomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        for u in n.unicodeScalars {
            if u.properties.generalCategory == .nonspacingMark { continue }
            switch u {
            case "ß": out.append("s"); out.append("s")
            case "ł": out.append("l")
            case "đ": out.append("d")
            case "ø": out.append("o")
            case "ı": out.append("i")
            case "أ", "إ", "آ": out.append("ا")
            case "ة": out.append("ه")
            case "ى": out.append("ي")
            case "ـ": break
            default: out.append(u)
            }
        }
        return String(out)
    }

    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    /// Words of a text, folded, joined by single spaces: phrases are matched as " a b " inside " … ".
    static func words(_ s: String) -> String {
        var parts: [String] = []; var cur = String.UnicodeScalarView()
        for u in foldWords(s).unicodeScalars {
            if isWordScalar(u) { cur.append(u) } else if !cur.isEmpty { parts.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { parts.append(String(cur)) }
        return parts.joined(separator: " ")
    }

    private static func hasAny(_ w: String, _ list: [String]) -> String? {
        let p = " " + w + " "
        return list.first { p.contains(" " + $0 + " ") }
    }

    /// First match of a pattern: the whole match and its groups ("" for a group that took no part). nil when none.
    static func groups(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let rg = m.range(at: i)
            return rg.location == NSNotFound ? "" : ns.substring(with: rg)
        }
    }

    // ---------- sports channels ----------

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
    static var sportsRule: String {
        "الاسم أو المجموعة يحتوي كلمة رياضية أو اسم شبكة رياضية (\(sportWords.count) كلمة، مثل sport / رياض / beIN / SSC / Al Kass / DAZN / ESPN)، بعد توحيد الحروف المزخرفة (SP⚽RTS = SPORTS)"
    }

    static func isSportsChannel(name: String, group: String) -> Bool {
        let s = foldName(name + " | " + group).lowercased()
        return sportWords.contains { s.contains($0) }
    }

    // ---------- networks and the provider's prefix ----------

    private static let networks: [(String, String)] = [
        ("bein", "beIN"), ("ssc", "SSC"), ("al kass", "الكأس"), ("alkass", "الكأس"), ("الكاس", "الكأس"),
        ("ad sport", "أبوظبي الرياضية"), ("ad sports", "أبوظبي الرياضية"), ("abu dhabi sport", "أبوظبي الرياضية"), ("abu dhabi sports", "أبوظبي الرياضية"),
        ("ابوظبي الرياضيه", "أبوظبي الرياضية"), ("dubai sport", "دبي الرياضية"), ("dubai sports", "دبي الرياضية"), ("sharjah sport", "الشارقة الرياضية"),
        ("sharjah sports", "الشارقة الرياضية"), ("ksa sport", "السعودية الرياضية"), ("ksa sports", "السعودية الرياضية"), ("kss", "السعودية الرياضية"),
        ("thmanyah", "ثمانية"), ("ثمانيه", "ثمانية"), ("on time sports", "أون تايم سبورتس"), ("on time sport", "أون تايم سبورتس"),
        ("shahid", "شاهد (منصة)"), ("mbc", "MBC"), ("oman sport", "عُمان الرياضية"), ("bahrain sport", "البحرين الرياضية"),
        ("kuwait sport", "الكويت الرياضية"), ("iraq sport", "العراق الرياضية"),
        ("sky", "Sky"), ("tnt", "TNT"), ("canal", "Canal+"), ("dazn", "DAZN"), ("espn", "ESPN"), ("fox sports", "Fox Sports"),
        ("fox sport", "Fox Sports"), ("eurosport", "Eurosport"), ("arena sport", "Arena Sport"), ("arena premium", "Arena Sport"),
        ("sport klub", "Sport Klub"), ("sportklub", "Sport Klub"), ("supersport", "SuperSport"), ("polsat", "Polsat"),
        ("eleven", "Eleven"), ("tvp sport", "TVP Sport"), ("cosmote", "Cosmote"), ("nova sport", "Nova Sport"), ("nova sports", "Nova Sport"),
        ("digi sport", "Digi Sport"), ("rmc sport", "RMC Sport"), ("movistar", "Movistar"), ("laliga", "LaLiga TV"), ("viaplay", "Viaplay"),
        ("ziggo", "Ziggo Sport"), ("setanta", "Setanta"), ("star sports", "Star Sports"), ("sony", "Sony"), ("tudn", "TUDN"), ("tyc", "TyC"),
        ("premier sports", "Premier Sports"), ("cytavision", "Cytavision"), ("v sport", "V Sport"), ("sportdigital", "Sportdigital"),
        ("sport tv", "Sport TV"), ("sportv", "SporTV"), ("premiere", "Premiere"), ("bt sport", "BT Sport"), ("voo", "VOO"),
        ("hub", "Hub"), ("fightklub", "Fightklub"), ("nbc", "NBC"), ("cbs", "CBS"), ("paramount", "Paramount+"),
        ("peacock", "Peacock"), ("prime video", "Prime Video"), ("amazon", "Prime Video"), ("nba tv", "NBA TV"), ("nfl", "NFL"),
        ("mutv", "MUTV"), ("ssport", "S Sport"), ("s sport", "S Sport"), ("tivibu", "Tivibu"), ("trt spor", "TRT Spor"),
        ("a spor", "A Spor"), ("exxen", "Exxen"), ("magenta", "Magenta Sport"), ("match", "Match!"), ("sportitalia", "Sportitalia"),
        ("win sports", "Win Sports"), ("directv", "DirecTV"), ("fanatiz", "Fanatiz"), ("ten sports", "Ten Sports"),
    ]

    /// Network (or platform) named in a channel name, or "أخرى".
    static func network(_ name: String) -> String {
        let raw = foldName(name).lowercased()
        if raw.contains("canal+") || raw.contains("canal plus") { return "Canal+" }
        let w = " " + words(name) + " "
        return networks.first { $0.1 != "Canal+" && w.contains(" " + $0.0 + " ") }?.1 ?? "أخرى"
    }

    private static let countries: [String: String] = [
        "ar": "عربي", "ksa": "السعودية", "sa": "السعودية", "qa": "قطر", "ae": "الإمارات", "uae": "الإمارات", "kw": "الكويت",
        "bh": "البحرين", "om": "عُمان", "eg": "مصر", "ma": "المغرب", "dz": "الجزائر", "tn": "تونس", "iq": "العراق",
        "jo": "الأردن", "lb": "لبنان", "uk": "بريطانيا", "gb": "بريطانيا", "ie": "إيرلندا", "fr": "فرنسا", "es": "إسبانيا",
        "de": "ألمانيا", "at": "النمسا", "ch": "سويسرا", "it": "إيطاليا", "pt": "البرتغال", "nl": "هولندا", "be": "بلجيكا",
        "pl": "بولندا", "tr": "تركيا", "gr": "اليونان", "cy": "قبرص", "sr": "صربيا", "rs": "صربيا", "hr": "كرواتيا",
        "ba": "البوسنة", "si": "سلوفينيا", "mk": "مقدونيا الشمالية", "al": "ألبانيا", "ro": "رومانيا", "bg": "بلغاريا",
        "hu": "المجر", "cz": "التشيك", "sk": "سلوفاكيا", "se": "السويد", "no": "النرويج", "dk": "الدنمارك", "fi": "فنلندا",
        "ru": "روسيا", "ua": "أوكرانيا", "us": "أمريكا", "usa": "أمريكا", "ca": "كندا", "mx": "المكسيك", "br": "البرازيل",
        "arg": "الأرجنتين", "cl": "تشيلي", "co": "كولومبيا", "pe": "بيرو", "in": "الهند", "pk": "باكستان", "sg": "سنغافورة",
        "au": "أستراليا", "nz": "نيوزيلندا", "za": "جنوب أفريقيا", "my": "ماليزيا", "id": "إندونيسيا",
    ]

    /// The provider's leading label ("UK: …", "AR| …", "8K: …"), as written; nil when the name has none.
    static func leadPrefix(_ name: String) -> String? {
        guard let g = groups(#"^\s*([^:|]{1,10}?)\s*[:|]"#, foldName(name)) else { return nil }
        let p = g[1].trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    /// A country code («NL», «fr») → its label, or nil.
    static func countryOfCode(_ code: String) -> String? { countries[code.lowercased().trimmingCharacters(in: .whitespaces)] }

    /// The prefix as a country when it is a known country code, else the label itself (a tier like GOLD / VIP / 8K).
    static func country(_ name: String) -> String {
        guard let p = leadPrefix(name) else { return "بدون بادئة" }
        return countries[p.lowercased()] ?? "تسمية: \(p)"
    }

    // ---------- versions (from the name) ----------

    enum Res: Int, Comparable, CaseIterable {
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

    private static func tokens(_ s: String) -> Set<String> {
        Set(foldName(s).uppercased().split(whereSeparator: { c in
            guard let a = c.asciiValue else { return true }
            return !((65...90).contains(a) || (48...57).contains(a) || a == 43)
        }).map(String.init))
    }
    private static func resOf(_ t: Set<String>) -> Res {
        if !t.isDisjoint(with: ["4K", "8K", "UHD", "2160P", "2160", "3840P", "3840"]) { return .uhd }
        // 1.10.3: «Full HD» is 1080p — «HD» alone in it is not 720p
        if !t.isDisjoint(with: ["FHD", "1080P", "1080", "1080I", "FULLHD"]) || (t.contains("FULL") && t.contains("HD")) { return .fhd }
        if !t.isDisjoint(with: ["HD", "720P", "720"]) { return .hd }
        if !t.isDisjoint(with: ["SD", "LQ", "576P", "480P"]) { return .sd }
        return .unknown
    }
    /// The name after the provider's prefix (the whole name when it has none).
    private static func body(_ folded: String) -> String {
        guard let i = folded.firstIndex(where: { $0 == ":" || $0 == "|" }) else { return folded }
        return String(folded[folded.index(after: i)...])
    }

    /// Resolution from the name: the part after the prefix decides when it names one; the prefix counts only when the
    /// rest says nothing, and never when `labelPrefixes` (checked for this source) says it's a group label.
    static func version(_ name: String, labelPrefixes: Set<String> = []) -> Version {
        let folded = foldName(name)
        let prefix = leadPrefix(name)
        let bodyRes = resOf(tokens(prefix != nil ? body(folded) : folded))
        let res: Res
        if bodyRes != .unknown || prefix == nil { res = bodyRes }
        else if labelPrefixes.contains(prefix!.uppercased()) { res = .unknown }
        else { res = resOf(tokens(prefix!)) }
        let t = tokens(folded)
        return Version(res: res, hevc: t.contains("HEVC") || t.contains("H265") || t.contains("X265") || folded.uppercased().contains("H.265"), raw: t.contains("RAW"))
    }

    /// Prefixes that are group labels in THIS source, from its own names: a prefix naming a resolution whose channels
    /// (≥ 3) name, after it, a different resolution in at least 30 % of the cases that name one. Same as the TV.
    static func prefixLabels<C: Collection>(_ names: C) -> Set<String> where C.Element == String {
        var st: [String: (n: Int, named: Int, other: Int)] = [:]
        for name in names {
            guard let p = leadPrefix(name)?.uppercased() else { continue }
            let pr = resOf(tokens(p)); if pr == .unknown { continue }
            let br = resOf(tokens(body(foldName(name))))
            var s = st[p] ?? (0, 0, 0)
            s.n += 1
            if br != .unknown { s.named += 1; if br != pr { s.other += 1 } }
            st[p] = s
        }
        return Set(st.filter { $0.value.n >= 3 && $0.value.named > 0 && $0.value.other * 10 >= $0.value.named * 3 }.keys)
    }

    /// The channel's own words after the provider prefix, without the version.
    static func bodyWords(_ name: String) -> Set<String> {
        let folded = foldName(name)
        let b = leadPrefix(name) != nil ? body(folded) : folded
        return Set(channelKey(b).split(separator: " ").map(String.init))
    }
    private static let channelNoise: Set<String> = ["sport", "sports", "spor", "tv", "channel", "the", "+", "plus", "uk", "ar"]

    /// The words that tell a channel apart inside its network ("event", "1", "f1").
    static func ownWords(_ name: String, net: String? = nil) -> Set<String> {
        let n = net ?? network(name)
        let netWords = words(n).split(separator: " ").map(String.init)
        return bodyWords(name).subtracting(channelNoise).subtracting(netWords).subtracting(netWords.map { $0 + "+" })   // "Canal+" is the network itself
    }

    /// A sports channel WITHOUT a guide that may carry a card (shown apart, unconfirmed): same network, and its own
    /// words all inside a carrying channel's name ("SKY SPORTS UHD (EVENT)" ↔ "SKY SPORTS MAIN EVENT ᴴᴰ"). Same as the TV.
    static func mayCarry(_ unguided: String, _ guided: String) -> Bool {
        let net = network(unguided)
        guard net != "أخرى", net == network(guided) else { return false }
        let own = ownWords(unguided, net: net)
        return !own.isEmpty && own.isSubset(of: bodyWords(guided))
    }

    /// Channels without a guide, read once.
    final class ExtraPool {
        struct Item: Hashable { let id: String; let name: String; let source: String }
        private var byNet: [String: [(Item, Set<String>)]] = [:]
        init(_ pool: [Item]) {
            for t in pool {
                let net = MatchGuideRule.network(t.name)
                guard net != "أخرى" else { continue }
                let own = MatchGuideRule.ownWords(t.name, net: net)
                if !own.isEmpty { byNet[net, default: []].append((t, own)) }
            }
        }
        func forNames(_ guided: [String]) -> [Item] {
            var out: [Item] = []; var seen = Set<Item>()
            for g in guided {
                guard let list = byNet[MatchGuideRule.network(g)] else { continue }
                let bw = MatchGuideRule.bodyWords(g)
                for (t, own) in list where own.isSubset(of: bw) && !seen.contains(t) { seen.insert(t); out.append(t) }
            }
            return out
        }
    }

    private static let versionTokens: Set<String> = ["hd", "fhd", "uhd", "sd", "lq", "4k", "8k", "hevc", "h265", "x265", "raw", "1080p", "720p",
        "1080", "720", "2160p", "2160", "3840p", "3840", "fullhd", "50fps", "60fps", "hdr", "hdr10", "dv", "backup", "multi", "low", "high"]

    /// The channel without its version (same as the TV's channelKey).
    static func channelKey(_ name: String) -> String {
        let n = foldName(name).lowercased().decomposedStringWithCanonicalMapping
        var parts: [String] = []; var cur = String.UnicodeScalarView()
        for u in n.unicodeScalars {
            if u.properties.generalCategory == .nonspacingMark { continue }
            if isWordScalar(u) || u == "+" { cur.append(u) } else if !cur.isEmpty { parts.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { parts.append(String(cur)) }
        return parts.filter { !versionTokens.contains($0) }.joined(separator: " ")
    }

    // ---------- matches in titles ----------

    struct Teams: Equatable { let home: String; let away: String; var lead: String? = nil }
    private static let separators = [" vs. ", " vs ", " v ", " v. ", " x ", " × ", " ضد ", " – ", " — ", " - "]
    private static let leadPattern = #"^\s*(?:\[[^\]]*\]|\([^)]*\)|(?:live|en vivo|en direct|en directo|ao vivo|direct|مباشر|مباشرة|canlı|dal vivo)\s*[:\-–|]?)\s*"#
    private static let slashMarkers: Set<String> = ["bant", "banttan", "canli", "live", "tekrar", "r", "l", "hd", "ozet"]
    private static let roundWords = "hafta|week|wk|round|rd|jornada|giornata|spieltag|matchday|md|kolejka|kolo|runde|journee|rodada|fecha|tur|speeldag|الجولة|الاسبوع"
    private static let nonTeamWords: Set<String> = ["news", "edition", "episode", "ep", "part", "season", "show", "live", "highlights",
        "magazine", "weekly", "daily", "special", "documentary", "نشرة", "حلقة", "برنامج", "الجزء", "موسم", "أخبار", "اخبار"]
    private static let womenWords: Set<String> = ["women", "womens", "w", "ladies", "femenino", "feminine", "feminin", "feminino", "femminile",
        "frauen", "damen", "dames", "kobiet", "kadin", "kadinlar", "zene", "zeny", "γυναικων", "سيدات", "للسيدات", "نساء", "wfc"]
    private static func ageNumber(_ w: String) -> String? { groups(#"^(?:u|sub|under)-?(\d{2})$"#, w)?[1] }

    private static func isMarkerOnly(_ inner: String) -> Bool {
        let w = words(inner).split(separator: " ").map(String.init)
        return !w.isEmpty && w.allSatisfy { womenWords.contains($0) || ageNumber($0) != nil }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// Removes a trailing "(…)" / "[…]" / "| …" that is not a women / age marker ("Arsenal (W)" keeps its "(W)").
    private static func dropTail(_ x: String) -> String {
        var s = x
        if let r = s.range(of: #"\s*\|.*$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = trim(s)
        while let r = s.range(of: #"\s*(\([^)]*\)|\[[^\]]*\])$"#, options: .regularExpression) {
            let piece = trim(String(s[r]))
            if isMarkerOnly(String(piece.dropFirst().dropLast())) { break }
            s.removeSubrange(r); s = trim(s)
        }
        return s
    }

    static func teams(_ title: String) -> Teams? {
        var s = trim(title)
        for _ in 0..<3 { if let r = s.range(of: leadPattern, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) } }
        let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "：" }).map(String.init)
        guard let seg = parts.last(where: { p in separators.contains { p.range(of: $0, options: .caseInsensitive) != nil } }) else { return nil }
        s = trim(seg)
        guard let sep = separators.first(where: { s.range(of: $0, options: .caseInsensitive) != nil }),
              let r = s.range(of: sep, options: .caseInsensitive) else { return nil }
        var a = trim(String(s[..<r.lowerBound]))
        var b = trim(String(s[r.upperBound...]))
        if sep != " - " {
            for d in [" - ", " – ", " — "] { if let x = b.range(of: d) { b = String(b[..<x.lowerBound]) } }
            b = trim(b)
        }
        if let g = groups(#"^(.*\S)\s*/\s*(\S+)$"#, b), slashMarkers.contains(words(g[2])) { b = trim(g[1]) }
        b = dropTail(b); a = dropTail(a)
        // 1.9.4 (owner's photo: «Serie A - Monza × Fiorentina», «Monza × Fiorentina Serie A», «Serie A × Resumos Da Jornada»):
        // a competition before the home team or after the away team is not part of the name; a side that is only a
        // competition (or a recap programme) means the title is not a match. Same as the TV's 0.9.49.
        if !["-", "–", "—"].contains(trim(sep)),
           let d = [" - ", " – ", " — "].compactMap({ a.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }),
           !trim(String(a[d.upperBound...])).isEmpty { a = trim(String(a[d.upperBound...])) }
        a = stripCompetition(a, lead: true); b = stripCompetition(b, lead: false)
        if isCompetition(a) || isCompetition(b) || isRecap(a) || isRecap(b) { return nil }
        var lead: String?
        let roundLead = "^(.*?)(?:\\b\\d{1,2}\\s*\\.?\\s*(?:\(roundWords))\\b|\\b(?:\(roundWords))\\s*\\d{1,2}\\b)\\s*[:\\-–.]?\\s*(\\S.*)$"
        if let g = groups(roundLead, a, caseInsensitive: true) {
            let rest = trim(g[2])
            if rest.count >= 2 && rest.contains(where: { $0.isLetter }) {
                let l = trim(String(g[0].dropLast(g[2].count)))
                lead = l.isEmpty ? nil : l
                a = rest
            }
        }
        func ok(_ x: String) -> Bool {
            guard let f = x.first, let l = x.last else { return false }
            return (2...40).contains(x.count) && (f.isLetter || f.isNumber) && (l.isLetter || l.isNumber || l == ")" || l == ".")
                && x.contains { $0.isLetter } && x.split(separator: " ").count <= 6
        }
        let weak = ["-", "–", "—"].contains(trim(sep))
        func showLike(_ x: String) -> Bool {
            x.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil ||
            x.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { nonTeamWords.contains(String($0)) }
        }
        if weak && (showLike(a) || showLike(b)) { return nil }
        return ok(a) && ok(b) && a.lowercased() != b.lowercased() ? Teams(home: a, away: b, lead: lead) : nil
    }

    // ---------- sport ----------

    enum Sport: String { case football, other, unknown
        var label: String { switch self { case .football: return "كرة القدم"; case .other: return "رياضة أخرى"; case .unknown: return "غير محدد" } }
    }
    struct SportGuess: Equatable { let sport: Sport; var name: String? = nil; var evidence: String? = nil }

    private static let otherSports: [(String, [String])] = [
        ("كرة سلة", ["basketball", "basket", "baloncesto", "basquete", "basquetbol", "pallacanestro", "koszykowka", "kosarka", "kosarka",
            "basketbol", "μπασκετ", "баскетбол", "كره السله", "nba", "wnba", "euroleague", "eurocup", "acb", "bsl", "lnb", "bbl", "aba liga", "ncaab"]),
        ("كرة طائرة", ["volleyball", "volley", "voleibol", "pallavolo", "siatkowka", "voleybol", "odbojka", "βολει", "волейбол",
            "كره الطائره", "superlega", "vnl", "sultanlar ligi", "plusliga", "tauron liga"]),
        ("كرة يد", ["handball", "balonmano", "pallamano", "pilka reczna", "rukomet", "hentbol", "χαντμπολ", "гандбол", "كره اليد", "ehf"]),
        ("تنس", ["tennis", "tenis", "atp", "wta", "wimbledon", "roland garros", "australian open", "billie jean king cup", "davis cup", "تنس"]),
        ("قتال", ["boxing", "boxe", "boks", "boxeo", "boxen", "ufc", "mma", "bkfc", "kickboxing", "wrestling", "wwe", "aew", "pfl",
            "fight night", "ملاكمه", "مصارعه", "zuffa boxing"]),
        ("سيارات ودراجات نارية", ["formula 1", "formel 1", "formula one", "f1", "f2", "f3", "formula", "motogp", "moto gp", "moto2",
            "moto3", "nascar", "indycar", "rally", "wrc", "gp", "grand prix", "gran premio", "dakar", "superbike", "wec", "فورمولا", "mundial f1"]),
        ("دراجات", ["cycling", "ciclismo", "cyclisme", "vuelta", "la vuelta", "giro", "tour de france", "kolarstwo", "biciklizam", "radsport"]),
        ("كرة قدم أمريكية", ["nfl", "american football", "futbol americano", "football americain", "ncaaf", "college football", "super bowl"]),
        ("هوكي", ["hockey", "nhl", "khl", "hokej", "eishockey", "hokey", "хоккей"]),
        ("رجبي", ["rugby", "six nations", "super rugby"]),
        ("كريكيت", ["cricket", "ipl", "indian premier league", "test match", "t20", "odi"]),
        ("غولف", ["golf", "pga", "lpga", "ryder cup", "dp world tour", "liv golf"]),
        ("سهام", ["darts", "pdc"]), ("سنوكر", ["snooker", "billiards"]),
        ("بيسبول", ["baseball", "mlb"]), ("كرة صالات", ["futsal", "كره الصالات"]), ("كرة شاطئية", ["beach soccer"]),
        ("بادل", ["padel"]), ("رياضات إلكترونية", ["esports", "e sports"]),
        ("ألعاب قوى وسباحة", ["athletics", "atletismo", "swimming", "natacion"]), ("تزلج", ["biathlon", "ski", "skiing", "ski jumping"]),
    ].map { ($0.0, $0.1.map(words)) }

    private static let footballWords: [String] = [
        "football", "soccer", "futbol", "futebol", "calcio", "fussball", "voetbal", "pilka nozna", "nogomet", "fudbal", "fotbal",
        "fotboll", "fodbold", "fotball", "jalkapallo", "labdarugas", "ποδοσφαιρο", "футбол", "كره القدم", "كره قدم",
        "premier league", "laliga", "la liga", "serie a", "bundesliga", "2 bundesliga", "ligue 1", "ligue 2", "eredivisie",
        "champions league", "europa league", "conference league", "copa del rey", "fa cup", "carabao cup", "efl", "coppa italia",
        "dfb pokal", "super lig", "trendyol super lig", "saudi pro league", "roshn", "دوري روشن", "دوري ابطال", "uefa", "fifa",
        "afc cup", "afc asian cup", "afc champions league two",
        "caf", "concacaf", "conmebol", "libertadores", "sudamericana", "liga mx", "brasileirao", "primeira liga", "liga portugal",
        "scottish premiership", "mls", "eliteserien", "allsvenskan", "superliga", "ekstraklasa", "stoiximan super league",
        "spanish laliga", "french ligue 1", "italian serie a", "german bundesliga", "english premier league", "afc champions league",
        "دوري نجوم قطر", "دوري ادنوك", "دوري الدرجه الاولي", "كاس العالم",
    ].map(words)

    private static func notBoxingDay(_ w: String) -> String { trim((" " + w + " ").replacingOccurrences(of: " boxing day ", with: " ")) }

    private static let footballChannels = ["laliga tv", "premier league tv", "mutv", "barca tv", "real madrid tv", "football", "calcio",
        "futbol", "futebol", "kora", "كوره", "soccer"].map(words)
    private static let otherChannels: [(String, String)] = [("nba tv", "كرة سلة"), ("golf", "غولف"), ("tennis", "تنس"), ("f1", "سيارات ودراجات نارية"),
        ("fightklub", "قتال"), ("fight", "قتال"), ("nfl", "كرة قدم أمريكية"), ("nhl", "هوكي"), ("cricket", "كريكيت"), ("motor", "سيارات ودراجات نارية")]
        .map { (words($0.0), $0.1) }

    /// Sport of one guide entry: another sport named in the category / title / description wins; then football words
    /// or a football-only competition; then the channel's own name; else unknown. Teams alone never decide.
    static func sport(title: String, description: String? = nil, category: String? = nil, channel: String? = nil) -> SportGuess {
        let fields: [(String, String?)] = [("التصنيف", category), ("العنوان", title), ("الوصف", description)]
        for (label, text) in fields {
            guard let text else { continue }
            let w = notBoxingDay(words(text))
            for (name, list) in otherSports { if let hit = hasAny(w, list) { return SportGuess(sport: .other, name: name, evidence: "\(label): \(hit)") } }
        }
        for (label, text) in fields {
            guard let text else { continue }
            if let hit = hasAny(words(text), footballWords) { return SportGuess(sport: .football, evidence: "\(label): \(hit)") }
        }
        if let channel {
            let w = words(channel)
            if let o = otherChannels.first(where: { (" " + w + " ").contains(" " + $0.0 + " ") }) {
                return SportGuess(sport: .other, name: o.1, evidence: "اسم القناة: \(o.0)")
            }
            if let hit = hasAny(w, footballChannels) { return SportGuess(sport: .football, evidence: "اسم القناة: \(hit)") }
        }
        return SportGuess(sport: .unknown)
    }

    // ---------- live / replay / studio ----------

    /// live = the guide entry itself says live. unknown = it says nothing (never shown as live).
    enum Kind: Int, CaseIterable {
        case live, replay, studio, unknown
        var label: String { ["موسوم مباشر في الدليل", "إعادة/ملخص", "استوديو", "نوع العرض غير محدد"][rawValue] }
        var name: String { ["LIVE", "REPLAY", "STUDIO", "UNKNOWN"][rawValue] }
    }
    private static let liveWords = ["live", "en vivo", "en direct", "en directo", "directo", "ao vivo", "مباشر", "مباشره", "canli", "dal vivo",
        "na zywo", "uzivo", "ζωντανα", "live coverage"].map(words)
    private static let liveMarks = ["(l)", "[l]", "(live)", "[live]"]
    private static let replayWords = ["replay", "rerun", "re run", "repeat", "re air", "delayed", "highlights", "اعاده", "ملخص", "اهداف",
        "rediffusion", "repeticion", "reprise", "tekrar", "classic", "best of", "bant", "banttan", "differe", "en differe", "powtorka",
        "skrot", "snimka", "wiederholung", "replica", "retransmision", "επαναληψη", "ozet"].map(words)
    private static let replayMarks = ["(r)", "[r]", "(rpt)", "(rep)"]
    private static let studioWords = ["studio", "استوديو", "ستوديو", "preview", "pre match", "prematch", "post match", "build up", "buildup",
        "magazine", "countdown", "تحليل", "قبل المباراه", "بعد المباراه", "review", "debate", "talk show"].map(words)

    /// Words, not letters: "Liverpool" is not "live", "Clasico" is not "classic".
    static func kind(title: String, description: String?, minutes: Int64) -> Kind {
        let raw = title.lowercased()
        let t = words(title), d = words(description ?? "")
        if replayMarks.contains(where: { raw.contains($0) }) || hasAny(t, replayWords) != nil { return .replay }
        if hasAny(t, studioWords) != nil { return .studio }
        if liveMarks.contains(where: { raw.contains($0) }) || hasAny(t, liveWords) != nil { return .live }
        if hasAny(d, replayWords) != nil { return .replay }
        if hasAny(d, liveWords) != nil && minutes >= 80 { return .live }
        return .unknown
    }

    // ---------- same match on several channels ----------

    private static let clubWords: Set<String> = ["fc", "cf", "sc", "afc", "ac", "acf", "ssc", "bc", "cd", "ud", "sd", "club", "sk", "fk", "nk", "bk", "if", "the"]

    /// 1.9.4: competitions that stick to a team in some titles («Serie A - Monza», «Fiorentina Serie A»).
    private static let competitions = ["serie a brasil", "serie a", "serie b", "la liga", "laliga", "premier league", "2 bundesliga", "bundesliga",
        "ligue 1", "ligue 2", "super lig", "eredivisie", "primeira liga", "liga portugal", "champions league", "europa league",
        "conference league", "saudi pro league", "roshn saudi league", "copa del rey", "coppa italia", "fa cup", "carabao cup", "efl cup",
        "brasileirao", "uefa champions league", "uefa europa league"]
    /// Compiled once (1.9.5: teams() runs for every programme of the guide).
    private static let recapRx = try! NSRegularExpression(pattern: recap)
    private static func isRecap(_ x: String) -> Bool { let f = foldWords(x); return recapRx.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil }
    private static let recap = #"\b(resumo|resumos|melhores momentos|skrot|podsumowanie|ozetler|ozeti|goller|resumen|resumenes|sintesi|highlights|recap)\b"#
    private static func isCompetition(_ x: String) -> Bool { let f = trim(foldWords(x)); return competitions.contains(f) }
    private static func stripCompetition(_ x: String, lead: Bool) -> String {
        let f = foldWords(x)
        let ws = trim(x).split(whereSeparator: { $0 == " " }).map(String.init)
        for c in competitions {
            let n = c.split(separator: " ").count
            if lead && f.hasPrefix(c + " ") && f.count > c.count + 2 && ws.count > n { return ws.dropFirst(n).joined(separator: " ") }
            if !lead && f.hasSuffix(" " + c) && f.count > c.count + 2 && ws.count > n { return ws.dropLast(n).joined(separator: " ") }
        }
        return x
    }
    /// 1.9.4: other-language names of the same club (Polish «Inter Mediolan»).
    private static let aliases = ["inter mediolan": "inter", "inter milan": "inter", "internazionale": "inter", "mediolan": "milan"]

    /// 1.9.5 (owner 10:12: the app closed after «قراءة الدليل»): a team's key is worked out once per name — the merge asks
    /// for the same few thousand names hundreds of thousands of times. Bounded, thread-safe.
    private static let keyLock = NSLock()
    private static var keyCache: [String: String] = [:]
    static func teamKey(_ name: String) -> String {
        keyLock.lock()
        if let k = keyCache[name] { keyLock.unlock(); return k }
        keyLock.unlock()
        let k = teamKeyRaw(name)
        keyLock.lock()
        if keyCache.count > 50_000 { keyCache.removeAll(keepingCapacity: true) }
        keyCache[name] = k
        keyLock.unlock()
        return k
    }
    private static func teamKeyRaw(_ name: String) -> String {
        var n = foldWords(name)
        n = n.replacingOccurrences(of: #"u-(\d{2})"#, with: "u$1", options: .regularExpression)
        n = n.replacingOccurrences(of: #"تحت\s*(\d{2})"#, with: "u$1", options: .regularExpression)
        var markers = Set<String>(); var core: [String] = []
        for w in words(n).split(separator: " ").map(String.init) {
            if womenWords.contains(w) { markers.insert("women") }
            else if let a = ageNumber(w) { markers.insert("u" + a) }
            else if clubWords.contains(w) { continue }
            else { core.append(w) }
        }
        let c = core.joined(separator: " ")
        return trim((aliases[c] ?? c) + markers.sorted().map { "#" + $0 }.joined())
    }

    /// Women / age group named anywhere in the title: both teams carry it.
    static func audience(_ title: String) -> Set<String> {
        var out = Set<String>()
        for w in words(title).split(separator: " ").map(String.init) {
            if womenWords.contains(w) && w != "w" { out.insert("women") }
            if let a = ageNumber(w) { out.insert("u" + a) }
        }
        return out
    }

    /// Competition named in the title ("Premier League: …", "… (Brasileirão)", "BSL (26-27) 09.Hafta …"), normalised; nil when none.
    static func competition(_ title: String) -> String? {
        let t = trim(title)
        var raw: String?
        if let c = t.firstIndex(where: { $0 == ":" || $0 == "：" }), c > t.startIndex,
           teams(String(t[t.index(after: c)...])) != nil, teams(String(t[..<c])) == nil {
            raw = String(t[..<c])
        } else if let l = teams(t)?.lead {
            raw = l.replacingOccurrences(of: #"\(\s*\d{2}\s*[-/]\s*\d{2}\s*\)"#, with: "", options: .regularExpression)
        } else if let g = groups(#"\(([^)]{3,40})\)\s*$"#, t), !isMarkerOnly(g[1]) {
            raw = g[1]
        }
        guard var x = raw else { return nil }
        if let r = x.range(of: leadPattern, options: [.regularExpression, .caseInsensitive]) { x.removeSubrange(r) }
        let k = teamKey(x)
        return k.count >= 3 && !["live", "r", "l"].contains(k) ? k : nil
    }

    /// One programme naming a match, on one channel version (each version stays its own entry: same name ≠ same stream).
    struct Entry: Equatable {
        let channel: String; let source: String; let start: Int64; let stop: Int64; let title: String; let teams: Teams; let kind: Kind
        let description: String?; let category: String?; let channelId: String; let general: Bool
        let competition: String?; let sport: SportGuess; let audience: Set<String>
        init(channel: String, source: String, start: Int64, stop: Int64, title: String, teams: Teams, kind: Kind,
             description: String? = nil, category: String? = nil, channelId: String = "", general: Bool = false) {
            self.init(channel: channel, source: source, start: start, stop: stop, title: title, teams: teams, kind: kind,
                      description: description, category: category, channelId: channelId, general: general,
                      competition: MatchGuideRule.competition(title),
                      sport: MatchGuideRule.sport(title: title, description: description, category: category, channel: general ? nil : channel),
                      audience: MatchGuideRule.audience(title))
        }
        init(channel: String, source: String, start: Int64, stop: Int64, title: String, teams: Teams, kind: Kind,
             description: String?, category: String?, channelId: String, general: Bool,
             competition: String?, sport: SportGuess, audience: Set<String>) {
            self.channel = channel; self.source = source; self.start = start; self.stop = stop; self.title = title
            self.teams = teams; self.kind = kind; self.description = description; self.category = category
            self.channelId = channelId; self.general = general; self.competition = competition; self.sport = sport; self.audience = audience
        }
    }

    /// Whether an entry on a general (non-sports) channel is strong enough: football named in the entry itself.
    static func generalOk(_ e: Entry) -> Bool { e.sport.sport == .football && !(e.sport.evidence ?? "").hasPrefix("اسم القناة") }

    struct Group {
        let key: String; let home: String; let away: String; let start: Int64; let entries: [Entry]
        var live: Bool { entries.contains { $0.kind == .live } }
        var replay: Bool { entries.allSatisfy { $0.kind == .replay } }
        var stop: Int64 { entries.map(\.stop).max() ?? start }
        var sport: SportGuess { entries.first { $0.sport.sport != .unknown }?.sport ?? SportGuess(sport: .unknown) }
        var competition: String? { entries.compactMap(\.competition).first }
        func airingAt(_ now: Int64) -> Bool { entries.contains { $0.start <= now && now < $0.stop } }
    }

    private static let compNoise: Set<String> = ["english", "spanish", "french", "italian", "german", "portuguese", "dutch", "turkish", "saudi", "the",
        "week", "md", "round", "j", "matchday", "live", "season"]

    /** Two named competitions are the same unless their words disagree (one's words inside the other's = same). */
    static func sameCompetition(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }
        func w(_ x: String) -> Set<String> {
            Set(x.split(whereSeparator: { $0 == " " || $0 == "#" }).map(String.init).filter { !compNoise.contains($0) && !$0.allSatisfy(\.isNumber) })
        }
        let wa = w(a), wb = w(b)
        return wa.isEmpty || wb.isEmpty || wa.isSubset(of: wb) || wb.isSubset(of: wa)
    }

    /// Same airing as the card's first entry: starts within the window, or overlaps at least half of the shorter one.
    private static func sameTime(_ e: Entry, _ anchor: Entry, _ windowMs: Int64) -> Bool {
        if abs(e.start - anchor.start) <= windowMs { return true }
        let overlap = min(e.stop, anchor.stop) - max(e.start, anchor.start)
        let shorter = min(e.stop - e.start, anchor.stop - anchor.start)
        return shorter > 0 && overlap * 2 >= shorter
    }

    private static func sportsAgree(_ a: SportGuess, _ b: SportGuess) -> Bool {
        a.sport == .unknown || b.sport == .unknown || (a.sport == b.sport && a.name == b.name)
    }

    /// One card = one airing: same teams with the same women / age markers, same kind (replays apart), start within the
    /// window of the card's FIRST entry (no chaining), no different competition named, no different sport named.
    /// Studio programmes are not cards. Same as the TV.
    static func group(_ entries: [Entry], windowMs: Int64 = 45 * 60_000) -> [Group] {
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for e in entries where e.kind != .studio {
            let k = [teamKey(e.teams.home), teamKey(e.teams.away)].sorted().joined(separator: " | ")
                + e.audience.sorted().map { "#" + $0 }.joined() + (e.kind == .replay ? " |R" : "")
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(e)
        }
        var out: [Group] = []
        for key in order {
            var open: [[Entry]] = []
            for e in buckets[key]!.sorted(by: { $0.start < $1.start }) {
                if let i = open.firstIndex(where: { g in
                    sameTime(e, g[0], windowMs) && g.allSatisfy { sameCompetition($0.competition, e.competition) && sportsAgree($0.sport, e.sport) }
                }) { open[i].append(e) } else { open.append([e]) }
            }
            for g in open { out.append(Group(key: key, home: g[0].teams.home, away: g[0].teams.away, start: g[0].start, entries: g)) }
        }
        return out.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }
}

/// What the matches screen lists (same rules as the TV's MatchScreenCore).
enum MatchScreenRule {
    enum SportFilter: Int, CaseIterable {
        case football, unknown, other
        var label: String { ["كرة القدم", "رياضة غير محددة", "رياضات أخرى"][rawValue] }
    }

    /// Cards of one day: day 0 = today (also what started yesterday and still airs), 1 = tomorrow. `nowOnly`: what airs
    /// now according to the guide (whatever the kind).
    static func cards(_ groups: [MatchGuideRule.Group], now: Int64, dayStart: Int64, tomorrow: Int64, end: Int64, day: Int, nowOnly: Bool,
                      sport: SportFilter) -> [MatchGuideRule.Group] {
        groups.filter { g in
            let s = g.sport.sport
            let sportOk: Bool
            switch sport { case .football: sportOk = s == .football; case .unknown: sportOk = s == .unknown; case .other: sportOk = s == .other }
            let dayOk = nowOnly ? g.airingAt(now) : day == 0 ? (g.stop > dayStart && g.start < tomorrow) : (g.start >= tomorrow && g.start < end)
            return sportOk && dayOk
        }.sorted { ($0.start, $0.home) < ($1.start, $1.home) }
    }

    /// What the guide says about this card, never more.
    static func state(_ g: MatchGuideRule.Group, now: Int64) -> String {
        if g.live { return MatchGuideRule.Kind.live.label }
        if g.replay { return MatchGuideRule.Kind.replay.label }
        if g.airingAt(now) { return "يُعرض الآن حسب الدليل · نوع العرض غير محدد" }
        return MatchGuideRule.Kind.unknown.label
    }

    struct Row: Equatable { let entry: MatchGuideRule.Entry; let version: MatchGuideRule.Version; let copy: Int }

    /// Versions best first (4K → 1080p → 720p/HD → SD → unknown, then tagged live → not stated → replay, then the
    /// name). hideHd / hideSd hide those resolutions (4K, 1080p and unknown always stay). Shown rows + hidden count.
    static func versions(_ g: MatchGuideRule.Group, versionOf: (MatchGuideRule.Entry) -> MatchGuideRule.Version, hideHd: Bool, hideSd: Bool) -> (rows: [Row], hidden: Int) {
        let kindRank: [MatchGuideRule.Kind: Int] = [.live: 0, .unknown: 1, .replay: 2, .studio: 3]
        let all = g.entries.map { ($0, versionOf($0)) }.sorted { a, b in
            (a.1.res.rawValue, kindRank[a.0.kind] ?? 9, a.0.channel, a.0.channelId) < (b.1.res.rawValue, kindRank[b.0.kind] ?? 9, b.0.channel, b.0.channelId)
        }
        var sameName: [String: Int] = [:]
        for (e, _) in all { sameName[e.channel, default: 0] += 1 }
        var seen: [String: Int] = [:]
        let rows: [Row] = all.map { e, v in
            var n = 0
            if (sameName[e.channel] ?? 0) > 1 { n = (seen[e.channel] ?? 0) + 1; seen[e.channel] = n }
            return Row(entry: e, version: v, copy: n)
        }
        let shown = rows.filter { r in !(hideHd && r.version.res == .hd) && !(hideSd && r.version.res == .sd) }
        return (shown, rows.count - shown.count)
    }

    struct Extra: Equatable { let id: String; let name: String; let source: String; let version: MatchGuideRule.Version }

    /// Channels without a guide that may carry the card, best quality first; the same quality filter applies.
    static func extras(_ g: MatchGuideRule.Group, pool: MatchGuideRule.ExtraPool, versionOf: (String, String) -> MatchGuideRule.Version,
                       hideHd: Bool, hideSd: Bool) -> [Extra] {
        var names: [String] = []
        for e in g.entries where !names.contains(e.channel) { names.append(e.channel) }
        return pool.forNames(names).map { Extra(id: $0.id, name: $0.name, source: $0.source, version: versionOf($0.name, $0.source)) }
            .filter { !(hideHd && $0.version.res == .hd) && !(hideSd && $0.version.res == .sd) }
            .sorted { ($0.version.res.rawValue, $0.name, $0.id) < ($1.version.res.rawValue, $1.name, $1.id) }
    }

    /// Short line under the teams: the guide's own wording before or after the teams, when there is one.
    static func subtitle(_ g: MatchGuideRule.Group) -> String? {
        guard let e = g.entries.first else { return nil }
        let t = e.title
        if let c = t.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let n = t.distance(from: t.startIndex, to: c)
            if (3...60).contains(n) { return String(t[..<c]).trimmingCharacters(in: .whitespaces) }
        }
        if let l = e.teams.lead { return l }
        guard let r = t.range(of: e.teams.away) else { return nil }
        let rest = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—/|"))
        return rest.isEmpty ? nil : String(rest.prefix(60))
    }
}

/// 1.8.6: matches and broadcasters from several sources, each fact with its source and time (owner 23:44).
/// The iPhone side of the TV's MatchSourcesCore — same rules and vectors (docs/MATCH-SOURCES.md).
enum MatchSourcesRule {
    enum Kind: Int, CaseIterable {
        case manual, broadcaster, guide, epg, candidate
        var label: String { ["أضفتها يدويًا", "مدرجة في جدول الناقل", "مدرجة في دليل نقل خارجي", "موجودة في EPG المزوّد", "نسخة محتملة بلا دليل"][rawValue] }
    }

    // ---------- the import file ----------

    /// `id`: the source's own channel id (optional); `type`: what the file says it is (optional, wins over the name).
    struct ExtChannel: Equatable { let name: String; let country: String?; let programmeStart: Int64?; var id: String? = nil; var type: ChType? = nil }
    /// `id`: the source's own match id (optional).
    struct ExtMatch: Equatable { let home: String; let away: String; let kickoff: Int64; let competition: String?; let sport: String?; let channels: [ExtChannel]
        var id: String? = nil
        /// When this match's channels were read, if not the source's time (a partial fetch keeps older ones).
        var fetchedAt: Int64? = nil }
    struct ExtSource { let name: String; let kind: Kind; let url: String?; let fetchedAt: Int64; let importedAt: Int64; var matches: [ExtMatch]
        /// How complete it is (an automatic fetch says «partial…» and its last complete fetch).
        var status: String? = nil
        /// 1.10.0 (TV 0.9.44/0.9.46/0.9.53): the times are programme starts from a channel listing (build-up included), not kickoffs.
        var programmeTimes = false
        /// A channel listing with no live marker: only adds channels to a match another source gives with its real kickoff.
        var confirmOnly = false
        /// Where the data first comes from when the source relays another (epgshare01 → bein.com): one witness, not two.
        var origin: String? = nil }
    struct BadFile: Error { let reason: String }

    private static func time(_ s: String?, _ what: String) throws -> Int64 {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { throw BadFile(reason: "\(what): الوقت ناقص") }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: s) ?? g.date(from: s) else {
            throw BadFile(reason: "\(what): الوقت «\(s)» ليس بصيغة ISO-8601 مع المنطقة (مثل 2026-11-23T20:00:00Z)")
        }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    private static func str(_ o: [String: Any], _ k: String) -> String { ((o[k] as? String) ?? "").trimmingCharacters(in: .whitespaces) }

    /// Reads a "shasha-matches" v1 file; refused whole, with the reason, when something required is missing.
    static func parse(_ data: Data, now: Int64) throws -> ExtSource {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw BadFile(reason: "ليس ملف JSON") }
        guard (root["format"] as? String) == "shasha-matches" else { throw BadFile(reason: "الحقل format يجب أن يكون shasha-matches") }
        guard (root["version"] as? Int) == 1 else { throw BadFile(reason: "الإصدار المدعوم 1") }
        guard let src = root["source"] as? [String: Any] else { throw BadFile(reason: "المصدر (source) ناقص") }
        let name = str(src, "name"); if name.isEmpty { throw BadFile(reason: "اسم المصدر ناقص") }
        let kind: Kind
        switch src["kind"] as? String { case "broadcaster": kind = .broadcaster; case "guide": kind = .guide
        default: throw BadFile(reason: "نوع المصدر يجب أن يكون broadcaster أو guide") }
        let fetched = try time(src["fetchedAt"] as? String, "وقت أخذ البيانات")
        guard let arr = root["matches"] as? [Any] else { throw BadFile(reason: "قائمة المباريات (matches) ناقصة") }
        if arr.count > 5000 { throw BadFile(reason: "أكثر من 5000 مباراة") }
        var out: [ExtMatch] = []
        for (i, x) in arr.enumerated() {
            guard let m = x as? [String: Any] else { throw BadFile(reason: "المباراة \(i + 1) ليست كائنًا") }
            let home = str(m, "home"), away = str(m, "away")
            if home.isEmpty || away.isEmpty { throw BadFile(reason: "المباراة \(i + 1): الفريقان مطلوبان") }
            let ko = try time(m["kickoff"] as? String, "المباراة \(i + 1)")
            var chs: [ExtChannel] = []
            for c in (m["channels"] as? [Any]) ?? [] {
                guard let c = c as? [String: Any] else { continue }
                let n = str(c, "name"); if n.isEmpty { continue }
                let ps = str(c, "programmeStart")
                let type: ChType?
                switch str(c, "type").lowercased() {
                case "": type = nil
                case "channel": type = .channel
                case "network": type = .network
                case "platform": type = .platform
                default: throw BadFile(reason: "المباراة \(i + 1) قناة \(n): النوع يجب أن يكون channel أو network أو platform")
                }
                chs.append(ExtChannel(name: n, country: str(c, "country").isEmpty ? nil : str(c, "country"),
                                      programmeStart: ps.isEmpty ? nil : try time(ps, "المباراة \(i + 1) قناة \(n)"),
                                      id: str(c, "id").isEmpty ? nil : str(c, "id"), type: type))
            }
            out.append(ExtMatch(home: home, away: away, kickoff: ko, competition: str(m, "competition").isEmpty ? nil : str(m, "competition"),
                                sport: str(m, "sport").isEmpty ? nil : str(m, "sport"), channels: chs, id: str(m, "id").isEmpty ? nil : str(m, "id"),
                                fetchedAt: str(m, "fetchedAt").isEmpty ? nil : try time(str(m, "fetchedAt"), "المباراة \(i + 1): وقت أخذ القنوات")))
        }
        return ExtSource(name: name, kind: kind, url: str(src, "url").isEmpty ? nil : str(src, "url"), fetchedAt: fetched, importedAt: now, matches: out,
                         status: str(src, "status").isEmpty ? nil : str(src, "status"),
                         programmeTimes: str(src, "times") == "programme", confirmOnly: str(src, "confirm") == "only",
                         origin: str(src, "origin").isEmpty ? nil : str(src, "origin"))
    }

    // ---------- kept schedules: one file per source, an update replaces it ----------

    /// The schedules after importing `new`: the same source (name) is replaced whole; a new source beyond `max` is refused. Same as the TV.
    static func planImport(_ existing: [ExtSource], _ new: ExtSource, max: Int = 6) throws -> [ExtSource] {
        let others = existing.filter { $0.name != new.name }
        if others.count >= max { throw BadFile(reason: "الحد \(max) جداول — احذف جدولًا أولًا") }
        return others + [new]
    }

    struct Coverage: Equatable {
        let from: Int64?; let to: Int64?; let fetchedAt: Int64; let ended: Bool; let old: Bool; var status: String? = nil
        func text(_ fmt: (Int64) -> String) -> String {
            var t = (from != nil && to != nil) ? "يغطي \(fmt(from!)) – \(fmt(to!))" : "بلا مباريات"
            t += " · أُخذت البيانات \(fmt(fetchedAt))"
            if let status { t += " · " + status }
            if ended { t += " · ⚠︎ انتهت تغطيته، استورد تحديثًا" } else if old { t += " · ⚠︎ عمره أكثر من يوم" }
            return t
        }
    }

    static func coverage(_ s: ExtSource, now: Int64) -> Coverage {
        let ks = s.matches.map(\.kickoff)
        let to = ks.max()
        return Coverage(from: ks.min(), to: to, fetchedAt: s.fetchedAt, ended: to.map { $0 + 3 * 3_600_000 < now } ?? true, old: now - s.fetchedAt > 24 * 3_600_000,
                        status: s.status)
    }

    /// Transmission entries (country × channel), distinct channels named, and distinct library channels they lead to.
    struct Counts: Equatable { let entries: Int; let unique: Int; let inLibrary: Int? }
    static func counts(_ s: ExtSource, idx: LibIndex?) -> Counts {
        let chs = s.matches.flatMap(\.channels)
        var seen = Set<String>(); let unique = chs.filter { seen.insert($0.id ?? MatchGuideRule.words($0.name)).inserted }
        let inLib = idx.map { i in Set(unique.flatMap { libraryHits($0, i).map(\.e.ch.id) }).count }
        return Counts(entries: chs.count, unique: unique.count, inLibrary: inLib)
    }

    // ---------- what a schedule names: a channel, a whole network, or a viewing platform ----------

    /// A listed name is a specific channel, a network as a whole, or a platform (app / service) — never guessed into a channel. Same as the TV.
    enum ChType: String { case channel = "قناة محددة", network = "شبكة عامة", platform = "منصة مشاهدة"; var label: String { rawValue } }

    private static let platformTokens: Set<String> = ["connect", "tod", "go", "now", "app", "player", "play", "online", "multiscreen", "katsomo", "viihde",
        "selekt", "stream", "streaming", "web", "com", "tv2play"]
    private static let platformPhrases: [String] = ["hbo max", "max", "paramount", "peacock", "fubotv", "fubo", "vix", "disney", "prime video", "amazon prime",
        "apple tv", "mycanal", "tabii", "sooka", "vidio", "jiotv", "sony liv", "fancode", "onefootball", "youtube", "stan sport", "pickx",
        "voyo", "oneplay", "rtl", "megogo", "okko", "iqiyi", "eltaott", "starhub", "dstv", "gotv", "arena cloud", "univision", "sling",
        "bluu", "inter", "nexgen", "viaplay", "dazn", "polsat box", "tvp sport app", "uefa tv", "city", "hibs tv",
        "nifl tv", "cymru football tv", "destination calcio", "moja tv", "artmotion", "tv vala", "medianet", "dialog tv", "tapmad",
        "wowow", "spotv now", "now player", "ais play", "nexgen", "tring", "fast tv", "tv net"].map { MatchGuideRule.words($0) }

    /// Country words inside listed names ("Arena Sport 3 Croatia"): the country, not the channel.
    private static let countryWords: Set<String> = ["croatia", "serbia", "slovenia", "bosnia", "thailand", "indonesia", "malaysia", "philippines", "singapore",
        "hong", "kong", "portugal", "spain", "espana", "italia", "italy", "germany", "deutschland", "france", "cz", "czech", "romania", "hungary",
        "mexico", "brazil", "brasil", "argentina", "chile", "colombia", "canada", "usa", "us", "africa", "roa", "nigeria", "myanmar", "estonia",
        "latvia", "lithuania", "norway", "sweden", "denmark", "iceland", "japan", "korea", "zealand", "new", "australia", "turkey", "greece",
        "cyprus", "malta", "kosova", "kosovo", "azerbaijan", "austria", "switzerland", "belgium", "netherlands", "poland", "ukraine", "russia",
        "england", "uk", "ireland", "mena", "sur", "norte", "caribbean", "international", "middle", "east"]
    /// Names that are a whole network or package when nothing else is said.
    private static let genericNetworks: Set<String> = ["canal", "canal plus", "movistar", "movistar plus", "bein", "bein sports", "bein sport", "sky sports",
        "sky sport", "tnt sports", "tnt sport", "espn", "dazn", "fox sports", "premiere", "eleven sports", "arena sport", "sport tv",
        "supersport", "polsat sport", "nova sport", "digi sport", "cosmote sport", "sport klub", "sportklub"]

    static func distinct(_ name: String, net: String? = nil) -> Set<String> {
        MatchGuideRule.ownWords(name, net: net ?? MatchGuideRule.network(name)).subtracting(countryWords).subtracting(editionWords.keys)
    }
    private static func bodyNoCountry(_ name: String) -> Set<String> { MatchGuideRule.bodyWords(name).subtracting(countryWords).subtracting(editionWords.keys) }

    /// 1.10.1 (owner 18:47: keep beIN French apart from the Arabic and Turkish ones; FRANCE vs French): the language / edition a
    /// name states after its prefix — read before the country words are dropped. Same rule as the TV's 0.9.54.
    private static let editionWords: [String: String] = ["french": "fr", "france": "fr", "francais": "fr", "english": "en", "eng": "en",
        "turkiye": "tr", "turkey": "tr", "turk": "tr", "arabic": "ar", "arab": "ar"]
    /// 1.10.2 (owner 19:06): only beIN states its edition in the name; for other networks these words are a language or a country.
    static func edition(_ name: String) -> Set<String> {
        MatchGuideRule.network(name) != "beIN" ? [] : Set(MatchGuideRule.bodyWords(name).compactMap { editionWords[$0] })
    }
    private static func toks(_ name: String) -> [String] { MatchGuideRule.words(name).split(separator: " ").map(String.init) }

    static func channelType(_ name: String) -> ChType {
        let w = MatchGuideRule.words(name)
        let t = Set(toks(name))
        let hasNumber = t.contains { $0.contains { $0.isNumber } }
        if t.contains(where: { platformTokens.contains($0) }) { return .platform }
        if !hasNumber && platformPhrases.contains(where: { " \(w) ".contains(" \($0) ") }) { return .platform }
        let net = MatchGuideRule.network(name)
        let bare = toks(name).filter { !countryWords.contains($0) }.joined(separator: " ")
        return net != "أخرى" && distinct(name, net: net).isEmpty && genericNetworks.contains(bare) ? .network : .channel
    }

    private static let langWords: [String: String] = ["english": "إنجليزي", "french": "فرنسي", "francais": "فرنسي", "arabic": "عربي", "spanish": "إسباني",
        "espanol": "إسباني", "turkish": "تركي", "portuguese": "برتغالي", "german": "ألماني", "deutsch": "ألماني", "italian": "إيطالي"]
    /// Commentary language when the name says it; nil otherwise (never guessed).
    static func language(_ name: String) -> String? { toks(name).lazy.compactMap { langWords[$0] }.first }

    private static let ultraWords: Set<String> = ["ultra", "ultimate", "uhd", "4k", "hdr"]
    /// Words that make another channel of the same network (beIN MAX 4 ≠ beIN SPORTS 4, beIN Cinema ≠ beIN Sports). Same as the TV.
    private static let otherChannelWords: Set<String> = ["max", "xtra", "extra", "cinema", "movies", "movie", "comedy", "drama", "action", "series", "kids", "junior",
        "jr", "news", "premium", "box", "office", "documentary", "docs", "family", "gourmet", "fatafeat", "jeem", "baraem", "nba", "golf", "f1", "tennis",
        "racing", "arena", "mix", "plus", "connect", "global", "events", "event", "mena", "afrique", "asia", "latino", "espanol", "deportes"]
    static func namesUhd(_ name: String) -> Bool {
        MatchGuideRule.version(name).res == .uhd || toks(name).contains { $0 == "ultra" || $0 == "ultimate" }
    }

    // ---------- the library ----------

    struct LibCh { let id: String; let name: String
        /// 1.10.2: the playlist group and the guide id — they say the country when the name doesn't.
        var group: String? = nil; var tvgId: String? = nil
        /// 1.10.3: the owner's own correction of this channel's country (kept by name, survives a refresh); "" = unknown.
        var manualCountry: String? = nil }

    /// How much a country source is trusted (owner 19:37): his correction, then the name, then the group; the guide id is a hint.
    enum Trust: Int, Comparable { case none = 0, hint, group, name, manual
        static func < (a: Trust, b: Trust) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["غير معروفة", "قرينة", "المجموعة", "الاسم", "تصحيحك اليدوي"][rawValue] }
    }

    /// A library channel's country, why, how far it is trusted, and any disagreement between the sources. Only `group`
    /// trust and above without a conflict (`firm`) can confirm a match or refuse one.
    struct Origin: Equatable {
        let country: String?; let why: String
        var trust: Trust = .name
        var conflict: String? = nil
        var firm: Bool { country != nil && trust >= .group && conflict == nil }
    }

    private static let groupCountryWords: [(String, String)] = [("netherlands", "هولندا"), ("nederland", "هولندا"), ("holland", "هولندا"), ("dutch", "هولندا"),
        ("france", "فرنسا"), ("french", "فرنسا"), ("francais", "فرنسا"), ("belgium", "بلجيكا"), ("belgique", "بلجيكا"),
        ("germany", "ألمانيا"), ("deutschland", "ألمانيا"), ("spain", "إسبانيا"), ("espana", "إسبانيا"), ("italy", "إيطاليا"), ("italia", "إيطاليا"),
        ("portugal", "البرتغال"), ("turkey", "تركيا"), ("turkiye", "تركيا"), ("england", "بريطانيا"), ("united kingdom", "بريطانيا"),
        ("arabic", "عربي"), ("arab", "عربي"), ("usa", "أمريكا"), ("canada", "كندا")]
    private static let leadCodes: Set<String> = ["nl", "fr", "be", "uk", "gb", "de", "es", "it", "pt", "tr", "us", "ca", "ie", "pl", "ch", "at"]

    /// 1.10.2 (owner 19:06; TV 0.9.55): the country from the prefix, a code right after a group label («8K:»), the playlist
    /// group, or the guide id suffix («ZiggoSport.nl») — with the reason kept.
    static func libCountry(_ name: String, group: String? = nil, tvgId: String? = nil, labels: Set<String> = [], manual: String? = nil) -> Origin {
        var fromName: (String, String)? = nil
        let p = MatchGuideRule.leadPrefix(name)
        if let p {
            if let c = MatchGuideRule.countryOfCode(p) { fromName = (c, "بادئة الاسم «\(p)»") }
            else {
                let folded = MatchGuideRule.foldName(name)
                if let r = folded.rangeOfCharacter(from: CharacterSet(charactersIn: ":|")) {
                    let body = String(folded[r.upperBound...])
                    if let q = MatchGuideRule.leadPrefix(body), let c = MatchGuideRule.countryOfCode(q) { fromName = (c, "بعد إزالة «\(p):» البادئة «\(q)»") }
                    else if let first = MatchGuideRule.words(body).split(separator: " ").first.map(String.init), leadCodes.contains(first),
                            let c = MatchGuideRule.countryOfCode(first) { fromName = (c, "بعد إزالة «\(p):» الاسم يبدأ بـ «\(first.uppercased())»") }
                }
            }
        }
        var fromGroup: (String, String)? = nil
        if let g = group, !g.trimmingCharacters(in: .whitespaces).isEmpty {
            let gw = " " + MatchGuideRule.words(g) + " "
            if let q = MatchGuideRule.leadPrefix(g), let c = MatchGuideRule.countryOfCode(q) { fromGroup = (c, "المجموعة «\(g)»") }
            else if let hit = groupCountryWords.first(where: { gw.contains(" \($0.0) ") }) { fromGroup = (hit.1, "المجموعة «\(g)»") }
        }
        var fromId: (String, String)? = nil
        if let t = tvgId?.trimmingCharacters(in: .whitespaces), let dot = t.lastIndex(of: ".") {
            let cc = String(t[t.index(after: dot)...])
            if cc.count == 2, cc.allSatisfy(\.isLetter), let c = MatchGuideRule.countryOfCode(cc) { fromId = (c, "معرّف الدليل «\(t)» (قرينة)") }
        }
        let said = [fromName, fromGroup, fromId].compactMap { $0 }
        func disagree(_ c: String?) -> String? {
            let d = said.filter { $0.0 != c }
            return d.isEmpty ? nil : d.map { "\($0.1) يقول \($0.0)" }.joined(separator: "؛ ")
        }
        if let manual {
            let c: String? = manual.isEmpty ? nil : manual
            return Origin(country: c, why: "تصحيحك اليدوي" + (disagree(c).map { " (بدلًا من: \($0))" } ?? ""), trust: c == nil ? .none : .manual)
        }
        let top: ((String, String), Trust)? = fromName.map { ($0, Trust.name) } ?? fromGroup.map { ($0, Trust.group) } ?? fromId.map { ($0, Trust.hint) }
        guard let top else {
            return Origin(country: nil, why: p != nil ? "«\(p!):» تسمية مجموعة لا دولة، ولا مجموعة أو معرّف دليل يدل على الدولة" : "لا بادئة دولة ولا مجموعة أو معرّف دليل يدل عليها", trust: .none)
        }
        let (c, why) = top.0
        var conflict: String? = nil
        if let n = fromName, let g = fromGroup, n.0 != g.0 { conflict = "\(n.1) يقول \(n.0) و\(g.1) تقول \(g.0)" }
        var note = ""
        if conflict == nil && top.1 != .hint, let i = fromId, i.0 != c { note = " · \(i.1) يقول \(i.0) (لا يغيّرها)" }
        return Origin(country: c, why: why + note, trust: top.1, conflict: conflict)
    }

    /// The countries offered for a manual correction (labels as `MatchGuideRule.country` writes them).
    static let countryChoices = ["هولندا", "فرنسا", "بلجيكا", "بريطانيا", "إسبانيا", "إيطاليا", "ألمانيا", "البرتغال", "تركيا", "عربي",
        "قطر", "السعودية", "الإمارات", "أمريكا", "كندا", "بولندا", "اليونان", "صربيا", "كرواتيا", "النمسا", "سويسرا", "السويد", "النرويج", "الدنمارك"]

    /// The schedule's country vs a library country: true / false, or nil when either is unknown.
    static func countryMatch(_ ext: String?, _ lib: String?) -> Bool? {
        guard let c = ext?.lowercased().trimmingCharacters(in: .whitespaces), let lib else { return nil }
        if arab.contains(c) { return lib == "عربي" || ["السعودية", "قطر", "الإمارات", "الكويت", "البحرين", "عُمان", "مصر"].contains(lib) }
        guard let want = countryNames[c] else { return nil }
        return lib == want
    }

    private static let countryNames: [String: String] = [
        "gb": "بريطانيا", "uk": "بريطانيا", "great britain": "بريطانيا", "england": "بريطانيا", "united kingdom": "بريطانيا",
        "ie": "إيرلندا", "ireland": "إيرلندا", "fr": "فرنسا", "france": "فرنسا", "es": "إسبانيا", "spain": "إسبانيا",
        "de": "ألمانيا", "germany": "ألمانيا", "it": "إيطاليا", "italy": "إيطاليا", "pt": "البرتغال", "portugal": "البرتغال",
        "nl": "هولندا", "netherlands": "هولندا", "be": "بلجيكا", "belgium": "بلجيكا", "pl": "بولندا", "poland": "بولندا",
        "tr": "تركيا", "turkey": "تركيا", "gr": "اليونان", "greece": "اليونان", "cy": "قبرص", "cyprus": "قبرص",
        "rs": "صربيا", "serbia": "صربيا", "hr": "كرواتيا", "croatia": "كرواتيا", "us": "أمريكا", "usa": "أمريكا",
        "ca": "كندا", "canada": "كندا", "mx": "المكسيك", "mexico": "المكسيك", "br": "البرازيل", "brazil": "البرازيل",
        "ar": "الأرجنتين", "argentina": "الأرجنتين", "se": "السويد", "sweden": "السويد", "no": "النرويج", "norway": "النرويج",
        "dk": "الدنمارك", "denmark": "الدنمارك", "at": "النمسا", "austria": "النمسا", "ch": "سويسرا", "switzerland": "سويسرا",
    ]
    private static let arab: Set<String> = ["bh", "bahrain", "sa", "saudi arabia", "ae", "united arab emirates", "qa", "qatar", "kw", "kuwait", "om", "oman",
        "eg", "egypt", "jo", "jordan", "lb", "lebanon", "iq", "iraq", "ma", "morocco", "dz", "algeria", "tn", "tunisia", "ly", "libya",
        "sy", "syria", "ye", "yemen", "ps", "palestine", "sd", "sudan", "mena"]

    static func countryFits(_ country: String?, _ libName: String) -> Bool {
        guard let c = country?.lowercased().trimmingCharacters(in: .whitespaces) else { return true }
        let lib = MatchGuideRule.country(libName)
        if lib == "بدون بادئة" || lib.hasPrefix("تسمية") { return true }
        if arab.contains(c) { return lib == "عربي" || ["السعودية", "قطر", "الإمارات", "الكويت", "البحرين", "عُمان", "مصر"].contains(lib) }
        guard let want = countryNames[c] else { return true }
        return lib == want
    }

    final class LibIndex {
        struct E { let ch: LibCh; let own: Set<String>; let body: Set<String>; let res: MatchGuideRule.Res; var ed: Set<String> = []
            var origin = Origin(country: nil, why: "") }
        let byNet: [String: [E]]
        /// 1.10.0 (TV 0.9.53): group labels of this library («8K:» before beIN SD / ᴴᴰ / ʰᵉᵛᶜ / ᴿᴬᵂ) — without them every
        /// version with no quality after the label (HEVC, RAW) was taken for a 4K channel and left out of the plain channel.
        let labels: Set<String>
        init(_ lib: [LibCh]) {
            var d: [String: [E]] = [:]
            let labels = MatchGuideRule.prefixLabels(lib.map(\.name))
            self.labels = labels
            for ch in lib {
                let net = MatchGuideRule.network(ch.name)
                d[net, default: []].append(E(ch: ch, own: distinct(ch.name, net: net), body: bodyNoCountry(ch.name),
                                             res: MatchGuideRule.version(ch.name, labelPrefixes: labels).res, ed: edition(ch.name),
                                             origin: libCountry(ch.name, group: ch.group, tvgId: ch.tvgId, labels: labels, manual: ch.manualCountry)))
            }
            byNet = d
        }
    }

    /// Library versions of a channel a schedule names: (version, exact). Same as the TV's libraryMatches.
    struct Hit { let e: LibIndex.E; let exact: Bool; let alt4k: Bool; var why: String? = nil }
    /// 1.10.2: a library version whose name fits but was refused (another country / beIN edition), with the reason.
    struct Reject { let e: LibIndex.E; let why: String }

    /// A library channel's country is known and is the one the schedule states.
    static func countrySame(_ country: String?, _ libName: String) -> Bool {
        guard let c = country?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        let lib = MatchGuideRule.country(libName)
        if lib == "بدون بادئة" || lib.hasPrefix("تسمية") { return false }
        return (arab.contains(c) || countryNames[c] != nil) && countryFits(country, libName)
    }

    /// The file's stated type first; else by the name; a platform-like name is a channel when the library has that very
    /// name in the same stated country. Same as the TV's typeOf.
    static func typeOf(_ c: ExtChannel, _ idx: LibIndex?) -> ChType {
        if let t = c.type { return t }
        let t = channelType(c.name)
        guard t != .channel, let idx else { return t }
        var none: [Reject] = []
        return rawHits(c, idx, [], &none).contains { $0.exact } ? .channel : t
    }

    static func libraryMatches(_ c: ExtChannel, _ idx: LibIndex, siblings: [String] = []) -> [(LibIndex.E, Bool)] {
        libraryHits(c, idx, siblings: siblings).map { ($0.e, $0.exact) }
    }

    static func libraryHits(_ c: ExtChannel, _ idx: LibIndex, siblings: [String] = []) -> [Hit] {
        var none: [Reject] = []
        return libraryHits(c, idx, siblings: siblings, rejects: &none)
    }
    static func libraryHits(_ c: ExtChannel, _ idx: LibIndex, siblings: [String] = [], rejects: inout [Reject]) -> [Hit] {
        typeOf(c, idx) == .channel ? rawHits(c, idx, siblings, &rejects) : []
    }

    private static func rawHits(_ c: ExtChannel, _ idx: LibIndex, _ siblings: [String], _ rejects: inout [Reject]) -> [Hit] {
        let net = MatchGuideRule.network(c.name)
        guard let list = idx.byNet[net] else { return [] }
        let own = distinct(c.name, net: net)
        let body = bodyNoCountry(c.name)
        let wantsUhd = namesUhd(c.name)
        if own.isEmpty && net == "أخرى" { return [] }
        // a named 4K channel: the library's 4K versions of the channels listed with it are possible, never confirmed by name alone
        let uhdOwn = own.subtracting(ultraWords)
        let sib = siblings.filter { MatchGuideRule.network($0) == net && !namesUhd($0) }.map { distinct($0, net: net) }
        var out: [Hit] = []
        let ed = edition(c.name)
        for e in list {
            if e.res == .uhd && !wantsUhd { continue }
            let exact = e.own == own && (!own.isEmpty || e.body == body)
            // 1.10.4 (owner's photo 20:28: «beIN SPORTS 4» offered «BEIN MAX 4», «BEIN CINEMA COMEDY 4»): a longer library name is a
            // near match only when its extra words don't name another channel, and a channel number alone is not enough
            let extra = e.own.subtracting(own)
            let possible = !exact && !own.isEmpty && own.isSubset(of: e.body) && extra.isDisjoint(with: otherChannelWords)
                && !(own.allSatisfy { $0.allSatisfy(\.isNumber) } && !extra.isEmpty)
            var alt = false
            if !exact && !possible && wantsUhd && e.res == .uhd {
                let eOwn = e.own.subtracting(ultraWords)
                alt = (!eOwn.isEmpty && (eOwn == uhdOwn || sib.contains { !$0.isEmpty && eOwn.isSubset(of: $0) }))
                    || (eOwn.isEmpty && !e.own.isDisjoint(with: ultraWords))
            }
            if !exact && !possible && !alt { continue }
            // a stated beIN edition must be the same on both sides (French ≠ Arabic beIN of the same number)
            if e.ed != ed {
                let a = ed.isEmpty ? "بلا نسخة" : ed.sorted().joined(separator: ","), b = e.ed.isEmpty ? "بلا نسخة" : e.ed.sorted().joined(separator: ",")
                rejects.append(Reject(e: e, why: "نسخة beIN مختلفة: «\(c.name)» \(a) ≠ \(b)")); continue
            }
            // a known country on both sides must be the same; an unknown one is possible at most (owner 19:06)
            let o = e.origin
            let cm = countryMatch(c.country, o.country)
            // a firm other country refuses (the owner can add it by hand or correct the country)
            if cm == false && o.firm { rejects.append(Reject(e: e, why: "دولة مختلفة: الجدول \(c.country ?? "") · مكتبتك \(o.country ?? "") (\(o.why))")); continue }
            // owner 19:06 / 19:37: unknown, conflicting or hinted country → possible at most, with the reason
            let why: String?
            if cm == true && o.firm { why = nil }
            else if c.country == nil { why = "الجدول لا يذكر الدولة" }
            else if o.country == nil { why = "دولة القناة في مكتبتك غير معروفة (\(o.why))" }
            else if let x = o.conflict { why = "تعارض في دولة القناة: \(x)" }
            else if cm == nil { why = "دولة الجدول «\(c.country ?? "")» غير معروفة لنا" }
            else { why = "الدولة من معرّف الدليل فقط — قرينة لا إثبات (\(o.why))" + (cm == false ? " وتخالف الجدول \(c.country ?? "")" : "") }
            out.append(Hit(e: e, exact: exact && why == nil, alt4k: alt, why: exact ? why : nil))
        }
        return out
    }

    // ---------- manual links ----------

    struct Manual: Codable, Equatable, Hashable {
        let matchKey: String; let channelId: String; let name: String; let add: Bool; let at: Int64
        /// The match's time when saved: finds the match again when a later schedule moves it to another day.
        var ko: Int64? = nil
    }

    static func matchKey(home: String, away: String, audience: Set<String>, at: Int64, tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return [canonTeam(MatchGuideRule.teamKey(home)), canonTeam(MatchGuideRule.teamKey(away))].sorted().joined(separator: " | ")
            + audience.sorted().map { "#" + $0 }.joined() + " @" + f.string(from: Date(timeIntervalSince1970: Double(at) / 1000))
    }
    private static func canonTeam(_ k: String) -> String {
        let w = k.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? k
        return (shortNames[w] ?? w) + k.dropFirst(w.count)
    }

    /// Noon of a key's local day (manual choices saved before 1.8.7 carry no time).
    static func keyNoon(_ key: String, tz: TimeZone = .current) -> Int64? {
        guard let r = key.range(of: " @", options: .backwards) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(key[r.upperBound...])).map { Int64($0.timeIntervalSince1970 * 1000) + 12 * 3_600_000 }
    }

    /// The teams of a key as a signature (short names read as full ones, markers kept).
    static func keyTeams(_ key: String) -> String {
        let t = key.range(of: " @", options: .backwards).map { String(key[..<$0.lowerBound]) } ?? key
        let parts = t.components(separatedBy: " | ")
        let cores = parts.map { p -> String in let w = p.split(separator: "#", omittingEmptySubsequences: false).first.map(String.init) ?? p; return shortNames[w] ?? w }.sorted()
        let marks = parts.flatMap { $0.split(separator: "#", omittingEmptySubsequences: false).dropFirst().map(String.init) }.sorted()
        return cores.joined(separator: " | ") + marks.map { "#" + $0 }.joined()
    }

    static func manualSetFor(_ list: [Manual], row: Row, channelId: String, name: String, add: Bool, at: Int64) -> [Manual] {
        let old = Set(row.manual.filter { $0.channelId == channelId })
        return list.filter { !old.contains($0) && !($0.matchKey == row.key && $0.channelId == channelId) }
            + [Manual(matchKey: row.key, channelId: channelId, name: name, add: add, at: at, ko: row.start)]
    }

    static func manualClearFor(_ list: [Manual], row: Row, channelId: String) -> [Manual] {
        let old = Set(row.manual.filter { $0.channelId == channelId })
        return list.filter { !old.contains($0) && !($0.matchKey == row.key && $0.channelId == channelId) }
    }

    static func manualSet(_ list: [Manual], _ m: Manual) -> [Manual] { list.filter { !($0.matchKey == m.matchKey && $0.channelId == m.channelId) } + [m] }
    static func manualClear(_ list: [Manual], key: String, channelId: String) -> [Manual] { list.filter { !($0.matchKey == key && $0.channelId == channelId) } }

    // ---------- merging ----------

    struct Proof: Equatable { let kind: Kind; let source: String; let at: Int64; var detail: String? = nil }

    struct Link: Equatable {
        let channelId: String; let name: String; var proofs: [Proof]; var possible = false
        /// Only a 4K alternative (the 4K feed of a channel listed with a named 4K one): never confirmed, never zapped.
        var alt4k = false
        /// 1.10.2 (owner §4): an airing that doesn't fit the kickoff — «تعارض توقيت / نوع العرض غير محدد»; never confirmed or zapped.
        var timing: String? = nil
        /// 1.10.4: what the competition's rights say of this channel (never a proof of the match).
        var rightsNote: String? = nil
        var best: Kind { Kind(rawValue: proofs.map(\.kind.rawValue).min() ?? Kind.candidate.rawValue) ?? .candidate }
        var confirmed: Bool {
            proofs.contains { $0.kind != .candidate } && (timing == nil || proofs.contains { $0.kind == .manual })
                && !((possible || alt4k) && !proofs.contains { $0.kind == .manual || $0.kind == .epg })
        }
    }

    struct Row {
        let key: String; let home: String; let away: String; let competition: String?; let audience: Set<String>
        let kickoff: Int64?; let kickoffFrom: String?
        let group: MatchGuideRule.Group?
        let timeConflict: Bool
        var links: [Link]
        let missing: [(String, String)]
        let removed: [Manual]
        let sources: [String]
        var sport: MatchGuideRule.SportGuess = MatchGuideRule.SportGuess(sport: .unknown)
        /// Platforms / whole networks a schedule names (TOD, beIN CONNECT, HBO Max, Canal+…): shown, never linked to a channel.
        var platforms: [(String, String)] = []
        /// The manual choices applied to this row (some may carry an older key: the match moved or was renamed).
        var manual: [Manual] = []
        /// 1.10.2: library versions refused (other country / beIN edition), with the reason.
        var rejected: [(LibCh, String)] = []
        /// 1.10.2 (owner §4): known only from a channel guide no schedule links — listed apart, never hidden.
        var unlinked: String? = nil
        /// 1.10.4 (owner 20:50): the competition's rights holders by territory — «صاحب حقوق البطولة», not broadcasters of the match.
        /// 1.10.6 (owner's report 22:33: 3.2 GB then closed): the rows share each rights file's facts (one array per file, the
        /// same buffer for every match) — 1.10.5 copied ~500 facts into each of 3484 matches.
        var rightsParts: [[RightsRule.Fact]] = []
        var rights: [RightsRule.Fact] {
            get { rightsParts.count == 1 ? rightsParts[0] : Array(rightsParts.joined()) }
            set { rightsParts = newValue.isEmpty ? [] : [newValue] }
        }
        var start: Int64 { kickoff ?? group!.start }
        var stop: Int64 { group?.stop ?? start + 2 * 3_600_000 }
        func airingAt(_ now: Int64) -> Bool { group?.airingAt(now) == true || (kickoff.map { now >= $0 && now < $0 + 2 * 3_600_000 } ?? false) }
        /// Only replays in the guide and no schedule's kickoff: never listed (live only).
        var replay: Bool { (group?.replay ?? false) && kickoff == nil }
    }

    /// Short names schedules use for the same club (Live-FootballOnTV «Wolves», «QPR»). Same as the TV.
    private static let shortNames: [String: String] = ["wolves": "wolverhampton wanderers", "qpr": "queens park rangers", "spurs": "tottenham hotspur",
        "psg": "paris saint germain", "man utd": "manchester united", "man united": "manchester united", "man city": "manchester city",
        "inter": "internazionale", "inter milan": "internazionale", "bayern munich": "bayern munchen", "west brom": "west bromwich albion",
        "sheff utd": "sheffield united", "sheff wed": "sheffield wednesday", "nottm forest": "nottingham forest", "brighton": "brighton hove albion",
        "brighton and hove albion": "brighton hove albion", "mk dons": "milton keynes dons", "atletico madrid": "atletico de madrid"]

    private static func teamsMatch(_ a: String, _ b: String) -> Bool {
        let ka = MatchGuideRule.teamKey(a), kb = MatchGuideRule.teamKey(b)
        if ka == kb { return true }
        func split(_ k: String) -> (String, String) {
            guard let i = k.firstIndex(of: "#") else { return (shortNames[k] ?? k, "") }
            let w = String(k[..<i])
            return (shortNames[w] ?? w, String(k[k.index(after: i)...]))
        }
        let (wa, ma) = split(ka), (wb, mb) = split(kb)
        if ma != mb { return false }
        let sa = Set(wa.split(separator: " ").map(String.init)), sb = Set(wb.split(separator: " ").map(String.init))
        return !sa.isEmpty && !sb.isEmpty && (sa.isSuperset(of: sb) || sb.isSuperset(of: sa))
    }

    static func sameMatch(_ g: MatchGuideRule.Group, _ m: ExtMatch) -> Bool {
        // 1.9.5: the cheap time check first — every schedule match was compared by name with every guide card
        if g.replay || m.kickoff < g.start - 3 * 3_600_000 || m.kickoff > g.stop + 3_600_000 { return false }
        let aud = Set(g.entries.flatMap(\.audience))
        if !aud.isEmpty && aud != MatchGuideRule.audience(m.home + " " + m.away) { return false }
        let teams = (teamsMatch(g.home, m.home) && teamsMatch(g.away, m.away)) || (teamsMatch(g.home, m.away) && teamsMatch(g.away, m.home))
        return teams && m.kickoff >= g.start - 3 * 3_600_000 && m.kickoff <= g.stop + 3_600_000
    }

    static func timesFit(_ g: MatchGuideRule.Group, _ kickoff: Int64) -> Bool {
        g.entries.contains { (-15 * 60_000...2 * 3_600_000).contains(kickoff - $0.start) && $0.stop > kickoff }
    }

    static func merge(_ groups: [MatchGuideRule.Group], sources: [ExtSource], idx: LibIndex, pool: MatchGuideRule.ExtraPool,
                      manual: [Manual], guideSource: String, guideAt: Int64, from: Int64, to: Int64, tz: TimeZone = .current) -> [Row] {
        let (deduped, laterOf) = dedupeWithLater(groups)
        var accs: [(group: MatchGuideRule.Group?, ext: [(ExtSource, ExtMatch)], later: [MatchGuideRule.Entry])] = deduped.enumerated().map { ($0.element, [], laterOf[$0.offset] ?? []) }
        for s in sources {
            for m in s.matches where m.kickoff >= from - 3 * 3_600_000 && m.kickoff < to { autoreleasepool {
                if let i = accs.firstIndex(where: { $0.group != nil && sameMatch($0.group!, m) }) ?? accs.firstIndex(where: { a in
                    a.group == nil && a.ext.contains { o in
                        abs(o.1.kickoff - m.kickoff) <= ((o.0.programmeTimes || s.programmeTimes) ? 2 * 3_600_000 : 20 * 60_000)
                            && teamsMatch(o.1.home, m.home) && teamsMatch(o.1.away, m.away) } }) {
                    accs[i].ext.append((s, m))
                } else { accs.append((nil, [(s, m)], [])) }
            } }
        }
        // 1.9.3 (owner: the same match listed more than once): schedule-only rows of the same match (same teams after
        // short names, same day, within 3 h) are one row. Same rule as the TV's 0.9.47.
        var seen: [String: Int] = [:]
        var merged: [(group: MatchGuideRule.Group?, ext: [(ExtSource, ExtMatch)], later: [MatchGuideRule.Entry])] = []
        for a in accs {
            guard a.group == nil, let m = a.ext.first?.1 else { merged.append(a); continue }
            let k = matchKey(home: m.home, away: m.away, audience: MatchGuideRule.audience(m.home + " " + m.away), at: m.kickoff, tz: tz)
            if let i = seen[k], a.ext.allSatisfy({ x in merged[i].ext.contains { abs($0.1.kickoff - x.1.kickoff) <= 3 * 3_600_000 } }) {
                merged[i].ext += a.ext
            } else {
                if seen[k] == nil { seen[k] = merged.count }
                merged.append(a)
            }
        }
        accs = merged
        // keys first, so a manual choice saved under an older key finds its match again (same teams, nearest row within 3 days)
        let keys: [(String, Int64)] = accs.map { a in
            let g = a.group, first = a.ext.first?.1
            let home = g?.home ?? first!.home, away = g?.away ?? first!.away
            let audience = g.map { Set($0.entries.flatMap(\.audience)) } ?? MatchGuideRule.audience(home + " " + away)
            let ko = a.ext.enumerated().sorted { ($0.element.0.programmeTimes ? 1 : 0, $0.element.0.kind.rawValue, $0.offset) < ($1.element.0.programmeTimes ? 1 : 0, $1.element.0.kind.rawValue, $1.offset) }.first?.element.1.kickoff
            let at = ko ?? g!.start
            return (matchKey(home: home, away: away, audience: audience, at: at, tz: tz), at)
        }
        var assigned: [Int: [Manual]] = [:]
        for mm in manual {
            var i = keys.firstIndex { $0.0 == mm.matchKey }
            if i == nil, let near = mm.ko ?? keyNoon(mm.matchKey, tz: tz) {
                let teams = keyTeams(mm.matchKey)
                i = keys.indices.filter { keyTeams(keys[$0].0) == teams && abs(keys[$0].1 - near) <= 3 * 86_400_000 }
                    .min { abs(keys[$0].1 - near) < abs(keys[$1].1 - near) }
            }
            if let i { assigned[i, default: []].append(mm) }
        }
        var rows: [Row] = []
        for (ai, a) in accs.enumerated() {
            let g = a.group
            // nothing confirms it is a live match: listed apart («من الدليل — غير مرتبطة بجدول مباريات»), not dropped
            var srcNames: [String] = []; for (s, _) in a.ext where !srcNames.contains(s.name) { srcNames.append(s.name) }
            let unlinked: String? = g == nil && a.ext.allSatisfy({ $0.0.confirmOnly })
                ? "دليل قناة (\(srcNames.joined(separator: "، "))) لا يربطه جدول مباريات بمباراة — قد تكون إعادة أو مباشرة" : nil
            let first = a.ext.first?.1
            let home = g?.home ?? first!.home, away = g?.away ?? first!.away
            let audience = g.map { Set($0.entries.flatMap(\.audience)) } ?? MatchGuideRule.audience(home + " " + away)
            let sched = a.ext.enumerated().sorted { ($0.element.0.programmeTimes ? 1 : 0, $0.element.0.kind.rawValue, $0.offset) < ($1.element.0.programmeTimes ? 1 : 0, $1.element.0.kind.rawValue, $1.offset) }.map(\.element)
            let kickoff = sched.first?.1.kickoff
            let trueKickoffs = Set(sched.filter { !$0.0.programmeTimes }.map(\.1.kickoff))
            let conflict = (kickoff != nil && g != nil && !(sched.first?.0.programmeTimes ?? false) && !timesFit(g!, kickoff!)) || trueKickoffs.count > 1
            let key = keys[ai].0
            var links: [String: Link] = [:]; var order: [String] = []
            func add(_ id: String, _ name: String, _ p: Proof, possible: Bool = false, alt: Bool = false, timing: String? = nil) {
                if var l = links[id] {
                    l.proofs.append(p); l.possible = l.possible && possible; l.alt4k = l.alt4k && alt
                    l.timing = (l.timing != nil && timing != nil) ? l.timing : nil; links[id] = l
                } else { links[id] = Link(channelId: id, name: name, proofs: [p], possible: possible, alt4k: alt, timing: timing); order.append(id) }
            }
            // owner 07:38 — live only: a guide entry the guide marks as a replay is left out; 1.10.2 (§4): one starting well
            // after the kickoff is not proof of a replay — kept as a timing conflict
            for e in g?.entries ?? [] where e.kind != .replay {
                add(e.channelId, e.channel, Proof(kind: .epg, source: guideSource, at: guideAt, detail: "«\(e.title)» · \(e.kind.label)"), timing: lateBy(e.start, kickoff: kickoff))
            }
            for e in a.later where e.kind != .replay {
                add(e.channelId, e.channel, Proof(kind: .epg, source: guideSource, at: guideAt, detail: "«\(e.title)» · \(e.kind.label) · \(hm(e.start))"),
                    timing: lateBy(e.start, kickoff: kickoff ?? g!.start) ?? "عرض لاحق للمباراة نفسها في الدليل — نوع العرض غير محدد")
            }
            var rejected: [(LibCh, String)] = []
            var missing: [(String, String)] = []
            var platforms: [(String, String)] = []
            for (s, m) in a.ext {
                for c in m.channels {
                    // a channel listing's airing well after the real kickoff: a timing conflict, not proof of a replay (§4)
                    let late: String? = s.programmeTimes ? trueKickoffs.min().flatMap { lateBy(m.kickoff, kickoff: $0) } : nil
                    if delayedName(c.name) { continue }          // «(Delayed)», highlights, replay: the name says it
                    if typeOf(c, idx) != .channel {
                        if !platforms.contains(where: { $0.0 == c.name && $0.1 == s.name }) { platforms.append((c.name, s.name)) }
                        continue
                    }
                    var rej: [Reject] = []
                    let hits = libraryHits(c, idx, siblings: m.channels.map(\.name), rejects: &rej)
                    for r in rej where !rejected.contains(where: { $0.0.id == r.e.ch.id }) { rejected.append((r.e.ch, "\(r.why) (\(s.name))")) }
                    if hits.isEmpty { if !missing.contains(where: { $0.0 == c.name && $0.1 == s.name }) { missing.append((c.name, s.name)) }; continue }
                    for h in hits {
                        add(h.e.ch.id, h.e.ch.name, Proof(kind: s.kind, source: s.name, at: m.fetchedAt ?? s.fetchedAt,
                                                          detail: c.name + (c.country.map { " · " + $0 } ?? "") + (h.alt4k ? " · بديل 4K محتمل" : "")
                                                            + (h.why.map { " · " + $0 } ?? "") + (s.programmeTimes ? (m.id.map { " · " + $0 } ?? "") : "")),
                            possible: !h.exact && !h.alt4k, alt: h.alt4k, timing: late)
                    }
                }
            }
            // the latest choice per channel stands
            let mine = Dictionary(grouping: assigned[ai] ?? [], by: \.channelId).values.compactMap { $0.max { $0.at < $1.at } }.sorted { $0.at < $1.at }
            for mm in mine where mm.add { add(mm.channelId, mm.name, Proof(kind: .manual, source: "أنت", at: mm.at)) }
            let removed = mine.filter { !$0.add }
            for r in removed { links[r.channelId] = nil; order.removeAll { $0 == r.channelId } }
            var named: [String] = []
            for id in order { if let l = links[id], !named.contains(l.name) { named.append(l.name) } }
            for (_, m) in a.ext { for c in m.channels where !named.contains(c.name) { named.append(c.name) } }
            for it in pool.forNames(named) where links[it.id] == nil && !removed.contains(where: { $0.channelId == it.id }) {
                add(it.id, it.name, Proof(kind: .candidate, source: "اقتراح", at: guideAt, detail: "نفس الشبكة واسم قريب، بلا دليل"))
            }
            let comp = g?.competition ?? sched.compactMap(\.1.competition).first
            var sport = g?.sport ?? MatchGuideRule.SportGuess(sport: .unknown)
            if sport.sport == .unknown {
                let said = sched.compactMap(\.1.sport).first
                if let said, ["football", "soccer", "كره القدم"].contains(MatchGuideRule.words(said)) {
                    sport = MatchGuideRule.SportGuess(sport: .football, evidence: "الجدول: \(said)")
                } else {
                    let s2 = MatchGuideRule.sport(title: sched.compactMap(\.1.competition).first ?? "", description: said)
                    if s2.sport != .unknown { sport = s2 }
                }
            }
            var srcs: [String] = g != nil ? [guideSource] : []
            for (s, _) in a.ext where !srcs.contains(s.name) { srcs.append(s.name) }
            var row = Row(key: key, home: home, away: away, competition: comp, audience: audience, kickoff: kickoff, kickoffFrom: sched.first?.0.name,
                          group: g, timeConflict: conflict, links: order.compactMap { links[$0] }, missing: missing, removed: removed, sources: srcs)
            row.sport = sport
            row.platforms = platforms
            row.manual = assigned[ai] ?? []
            row.rejected = rejected.filter { links[$0.0.id] == nil }
            row.unlinked = unlinked
            rows.append(row)
        }
        return rows.sorted { ($0.start, $0.home) < ($1.start, $1.home) }
    }

    static func compare(_ rows: [Row], fmt: (Int64) -> String) -> String {
        var s = ""
        func line(_ x: String) { s += x + "\n" }
        let withExt = rows.filter { $0.sources.count > ($0.group != nil ? 1 : 0) }
        let added = rows.filter { $0.group == nil }
        line("— مقارنة المصادر (كاملة)")
        line("مباريات من الجداول المستوردة: \(withExt.count) · منها موجودة في EPG: \(withExt.filter { $0.group != nil }.count) · أضافتها الجداول (غير موجودة في EPG): \(added.count)")
        line("تعارض في الموعد بين الجدول وEPG أو بين جدولين: \(rows.filter(\.timeConflict).count)")
        line("")
        line("— مباريات أضافتها الجداول")
        for r in added {
            line("   \(fmt(r.start)) · \(r.home) × \(r.away)\(r.competition.map { " · " + $0 } ?? "") · من \(r.kickoffFrom ?? "") · قنوات في مكتبتك: \(r.links.filter(\.confirmed).count) (محتملة \(r.links.filter(\.possible).count))")
        }
        line("")
        line("— قنوات طابقت مكتبتك (لكل مباراة)")
        for r in withExt {
            let ext = r.links.filter { $0.proofs.contains { $0.kind == .broadcaster || $0.kind == .guide } }
            if ext.isEmpty && r.missing.isEmpty { continue }
            line("\(fmt(r.start)) · \(r.home) × \(r.away)")
            for l in ext {
                let ps = l.proofs.filter { $0.kind == .broadcaster || $0.kind == .guide }.map { "\($0.detail ?? "") (\($0.source))" }.joined(separator: " / ")
                line("   \(l.possible ? "محتملة" : "مطابقة"): \(l.name) ← \(ps)" + (l.proofs.contains { $0.kind == .epg } ? " · وفي EPG أيضًا" : " · ليست في EPG"))
            }
            for (n, src) in r.missing { line("   غير موجودة في مكتبتك: \(n) (\(src))") }
        }
        line("")
        line("— قنوات 4K في الجداول وما يقابلها في مكتبتك")
        for r in withExt {
            let uhd = r.links.filter { l in l.proofs.contains { ($0.kind == .broadcaster || $0.kind == .guide) && namesUhd($0.detail ?? "") } }
            if uhd.isEmpty { continue }
            line("   \(r.home) × \(r.away): " + uhd.map { l in
                "\(l.name) (\(l.alt4k ? "بديل محتمل — قد لا يكون نفس البث" : l.possible ? "محتملة" : "مطابقة مباشرة للاسم") ← \(l.proofs.first { namesUhd($0.detail ?? "") }?.detail ?? ""))" }.joined(separator: " · "))
        }
        line("")
        line("— منصات وشبكات عامة ذكرتها الجداول (لا تُربط بقناة)")
        for r in withExt where !r.platforms.isEmpty {
            line("   \(r.home) × \(r.away): " + r.platforms.map { "\($0.0) (\(channelType($0.0).label))" }.joined(separator: "، "))
        }
        line("   (قناة اسمها يشبه منصة تُعدّ قناة إذا كان في مكتبتك نفس الاسم بنفس الدولة، أو إذا قال الملف type=channel)")
        line("")
        line("— تعارضات الموعد")
        for r in rows where r.timeConflict {
            let epg = r.group?.entries.map { "\($0.channel) \(fmt($0.start))" }.joined(separator: " / ") ?? "-"
            line("   \(r.home) × \(r.away): الجدول \(r.kickoff.map(fmt) ?? "-") (\(r.kickoffFrom ?? "")) · برامج EPG: \(epg)")
        }
        line("")
        // 1.10.2 (owner §4 / §9): every link counted by what it rests on, with the timing and identity reasons
        let all = rows.flatMap(\.links)
        line("— الروابط: مؤكدة \(all.filter(\.confirmed).count) · محتملة \(all.filter { !$0.confirmed && $0.timing == nil && $0.proofs.contains { $0.kind != .candidate } }.count)"
             + " · تعارض توقيت \(all.filter { !$0.confirmed && $0.timing != nil }.count) · اقتراحات \(all.filter { $0.proofs.allSatisfy { $0.kind == .candidate } }.count)")
        line("— تعارض توقيت / نوع العرض غير محدد (لا يُشغَّل تلقائيًا ولا يُحسب تغطية)")
        for r in rows { for l in r.links where !l.confirmed && l.timing != nil { line("   \(r.home) × \(r.away) (\(r.kickoff.map(fmt) ?? "-")) · \(l.name) · \(l.timing!)") } }
        line("— نسخ رُفضت رغم تشابه الاسم (دولة أو نسخة beIN مختلفة) — تقدر تضيفها يدويًا من شاشة المباراة")
        for r in rows { for (ch, why) in r.rejected { line("   \(r.home) × \(r.away) · \(ch.name) · \(why)") } }
        line("— مطابقات محتملة لأن الدولة غير معروفة")
        for r in rows {
            for l in r.links where l.possible && l.timing == nil {
                guard let why = l.proofs.compactMap(\.detail).first(where: { $0.contains("غير معروفة") || $0.contains("لا يذكر الدولة") }) else { continue }
                line("   \(r.home) × \(r.away) · \(l.name) · \(why)")
            }
        }
        line("— من الدليل — غير مرتبطة بجدول مباريات (معروضة في قسم منفصل)")
        let covers = scheduleCovers(rows)
        for r in rows { if let w = unlinkedWhy(r, covers: covers) { line("   \(fmt(r.start)) · \(r.home) × \(r.away) · \(w)") } }
        return s
    }

    /// 1.10.2 (owner 19:06): the kept channel guides' channels vs the library, both ways (same as the TV's guideVsLibrary).
    static func guideVsLibrary(_ sources: [ExtSource], idx: LibIndex, focus: [LibCh]) -> String {
        var s = ""; func line(_ x: String) { s += x + "\n" }
        var reached = Set<String>()
        line("— قنوات أدلة القنوات الخارجية غير المربوطة بمكتبتك")
        for src in sources where src.programmeTimes {
            var seen = Set<String>(); var chans: [ExtChannel] = []
            for c in src.matches.flatMap(\.channels) where seen.insert(c.name + "|" + (c.country ?? "")).inserted { chans.append(c) }
            var out: [String] = []
            for c in chans {
                var rej: [Reject] = []
                let hits = libraryHits(c, idx, siblings: [], rejects: &rej)
                hits.forEach { reached.insert($0.e.ch.id) }
                if hits.isEmpty { out.append(c.name + (rej.isEmpty ? " (لا نسخة بهذا الاسم في مكتبتك)" : " (رُفض: " + rej.prefix(3).map { "\($0.e.ch.name) — \($0.why)" }.joined(separator: "؛ ") + ")")) }
            }
            line("   \(src.name): \(chans.count) قناة · غير مربوطة \(out.count)")
            for o in out { line("      \(o)") }
        }
        line("— قنواتك الهولندية والفرنسية التي لا تصلها أي قناة من الأدلة الخارجية")
        let miss = focus.filter { !reached.contains($0.id) }
        line("   \(miss.count) من \(focus.count)")
        for f in miss { line("      \(f.name)") }
        return s
    }

    /// A link for a report: host and path only — a query or user info (tokens, accounts) never shown.
    static func maskUrl(_ u: String) -> String { RedactRule.link(u) }

    private static func hm(_ t: Int64) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
    }

    // ---------- the screen ----------

    static func liveAiring(_ e: MatchGuideRule.Entry, kickoff: Int64?) -> Bool {
        e.kind != .replay && lateBy(e.start, kickoff: kickoff) == nil
    }

    /// 1.10.2 (owner §4): over 90 min after the kickoff is not proof of a replay — «تعارض توقيت / نوع العرض غير محدد».
    static func lateBy(_ start: Int64, kickoff: Int64?) -> String? {
        guard let k = kickoff else { return nil }
        let min = (start - k) / 60_000
        return min > 90 ? "تعارض توقيت: يبدأ بعد الانطلاق بـ \(min) دقيقة — نوع العرض غير محدد (لا علامة إعادة)" : nil
    }

    private static let delayedRe = try! NSRegularExpression(pattern: "\\b(delayed|deferred|highlights|replay|re-?air|repeat|catch ?up)\\b|\\((d|r|rpt|delayed)\\)|اعادة|إعادة|ملخص|مؤجل", options: [.caseInsensitive])
    static func delayedName(_ n: String) -> Bool { delayedRe.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil }

    // ---------- owner 07:51–07:52: the competitions that matter, Italy → Spain → England first (same as the TV) ----------
    private static let importantParts: [String] = [// FIFA
        "\\bfifa\\b", "world cup", "club world cup", "arab cup", "كأس العالم", "مونديال", "كأس العرب", "كأس القارات",
        // UEFA clubs + national
        "champions league", "europa league", "conference league", "uefa super cup", "\\buefa\\b", "nations league", "\\beuro 20", "european championship",
        "دوري أبطال أوروبا", "دوري ابطال اوروبا", "الدوري الأوروبي", "الدوري الاوروبي", "دوري المؤتمر", "كأس السوبر الأوروبي", "كأس الأمم الأوروبية", "دوري الأمم",
        // England
        "premier league", "\\bepl\\b", "fa cup", "efl cup", "carabao", "league cup", "community shield", "الدوري الإنجليزي", "الدوري الانجليزي", "كأس الاتحاد الإنجليزي", "كأس الرابطة الإنجليزية", "كأس إنجلترا",
        // Spain
        "la ?liga", "primera divisi[oó]n", "copa del rey", "supercopa", "الدوري الإسباني", "الدوري الاسباني", "كأس ملك إسبانيا", "كأس الملك الإسباني", "السوبر الإسباني",
        // Italy
        "serie a", "coppa italia", "supercoppa", "الدوري الإيطالي", "الدوري الايطالي", "كأس إيطاليا", "السوبر الإيطالي",
        // Germany
        "bundesliga", "dfb[ -]?pokal", "supercup", "الدوري الألماني", "الدوري الالماني", "كأس ألمانيا", "السوبر الألماني",
        // France
        "ligue 1", "coupe de france", "troph[ée]e des champions", "الدوري الفرنسي", "كأس فرنسا", "السوبر الفرنسي",
        // Turkey
        "s[üu]per lig", "turkish super league", "t[üu]rkiye kupas[ıi]", "turkish cup", "الدوري التركي", "كأس تركيا",
        // Saudi Arabia
        "saudi pro league", "roshn", "saudi professional league", "king'?s cup", "king cup", "saudi super cup", "الدوري السعودي", "دوري روشن", "كأس الملك", "كأس خادم الحرمين", "السوبر السعودي"]
    private static let importantRe = try! NSRegularExpression(pattern: importantParts.map { "(?:\($0))" }.joined(separator: "|"), options: [.caseInsensitive])
    private static let notImportantRe = try! NSRegularExpression(pattern: "\\b(egypt|egyptian|scottish|scotland|welsh|wales|northern ireland|irish|russian|russia|ukrain|kazakh|armenian|israeli|maltese|malta|bangladesh|kenyan|kuwait|bahrain|qatar|oman|iraq|jordan|lebanon|syria|ghana|nigeria|south africa|zambia|uganda|tanzania|ethiopia|hong kong|singapore|malaysia|indonesia|vietnam|thai|indian|pakistan|nepal|myanmar|cambodia|belarus|azerbaijan|georgia|moldova|estonia|latvia|lithuania|austria|austrian|swiss|switzerland|belgian|dutch|portuguese|greek|cypriot|romanian|bulgarian|serbian|croatian|slovenian|slovak|czech|polish|hungarian|danish|swedish|norwegian|finnish|icelandic|faroe|brazil|argentin|chile|colombia|peru|ecuador|uruguay|paraguay|bolivia|venezuela|mexic|usa|mls|canadian|australia|a-league|japan|j1|korea|k league|china|chinese|2\\. bundesliga|bundesliga 2|serie b|ligue 2|segunda|la liga 2|hypermotion|1\\. lig|primeira|youth|women|u-?\\d\\d)\\b|المصري|الكويتي|البحريني|القطري|الإماراتي|العماني|العراقي|الأردني|المغربي|التونسي|الجزائري|الليبي|السوداني|المصرية|الدرجة الثانية|الدرجة الأولى|للسيدات|للشباب|للناشئين", options: [.caseInsensitive])
    private static let italyRe = try! NSRegularExpression(pattern: "serie a|coppa italia|supercoppa|\\bital|الإيطالي|الايطالي|إيطاليا", options: [.caseInsensitive])
    private static let spainRe = try! NSRegularExpression(pattern: "la ?liga|primera divisi|copa del rey|supercopa|\\bspain|\\bspanish|الإسباني|الاسباني|إسبانيا", options: [.caseInsensitive])
    private static let englandRe = try! NSRegularExpression(pattern: "premier league|\\bepl\\b|fa cup|efl cup|carabao|league cup|community shield|\\bengland|\\benglish|الإنجليزي|الانجليزي|إنجلترا", options: [.caseInsensitive])
    private static func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

    static func important(_ competition: String?) -> Bool {
        guard let c = competition else { return false }
        return has(importantRe, c) && !has(notImportantRe, c)
    }
    static func important(_ r: Row) -> Bool {
        important(r.competition) || (r.group?.entries.contains { important($0.competition) || important($0.title) } ?? false)
    }
    static func rank(_ competition: String?) -> Int {
        guard important(competition), let c = competition else { return 4 }
        return has(italyRe, c) ? 0 : has(spainRe, c) ? 1 : has(englandRe, c) ? 2 : 3
    }
    static func rank(_ r: Row) -> Int {
        ([r.competition] + (r.group?.entries ?? []).flatMap { [$0.competition, $0.title] }).map { rank($0) }.min() ?? 4
    }

    private static let youthWomenRe = try! NSRegularExpression(pattern: "\\b(youth|junior|juniors|juvenil|primavera|reserves?|women'?s?|womens|feminine|f[ée]minin[e]?|femenin[oa]|frauen|damen|wsl|nwsl|liga f|u-?(1[5-9]|2[0-3]))\\b|سيدات|نسائي|للناشئين|ناشئين|للشباب|تحت ?(17|19|20|21|23)", options: [.caseInsensitive])
    /// Owner 07:45: youth and women's matches are not wanted (team markers, or such a competition). Same as the TV.
    static func youthOrWomen(_ r: Row) -> Bool {
        if !r.audience.isEmpty || !MatchGuideRule.audience(r.home + " " + r.away).isEmpty { return true }
        guard let c = r.competition else { return false }
        return youthWomenRe.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) != nil
    }

    /// Live men's senior football only (owner 07:38–07:45): replays, youth and women's matches, other sports and unclassified cards are not listed.
    /// 1.9.4 (owner's photo: «Monza × Fiorentina» four times — 22:39, 22:40, 22:40, 02:00): guide cards of the same match
    /// within 12 h are one: within 90 min of the first they are versions of the same airing, later ones are later showings
    /// (not live) and are dropped. Same as the TV's 0.9.49.
    static func dedupeGroups(_ groups: [MatchGuideRule.Group]) -> [MatchGuideRule.Group] { dedupeWithLater(groups).0 }

    /// 1.10.2 (§4): the later showings are kept with the card they repeat (timing conflicts, not dropped).
    static func dedupeWithLater(_ groups: [MatchGuideRule.Group]) -> ([MatchGuideRule.Group], [Int: [MatchGuideRule.Entry]]) {
        func pair(_ g: MatchGuideRule.Group) -> String {
            [canonTeam(MatchGuideRule.teamKey(g.home)), canonTeam(MatchGuideRule.teamKey(g.away))].sorted().joined(separator: "|")
                + Set(g.entries.flatMap(\.audience)).sorted().map { "#" + $0 }.joined()
        }
        // 1.9.5 (owner 10:12: «قراءة الدليل» then the app closed): the pair key is worked out once per card and the earlier
        // cards of the same pair are found by key — 1.9.4 compared every card with every kept one, working out both
        // keys again each time (thousands of cards → millions of name foldings).
        var kept: [MatchGuideRule.Group] = []
        var later: [Int: [MatchGuideRule.Entry]] = [:]
        var byPair: [String: [Int]] = [:]
        for g in groups.sorted(by: { $0.start < $1.start }) {
            let k = autoreleasepool { pair(g) }
            if let i = byPair[k]?.first(where: { g.start - kept[$0].start <= 12 * 3_600_000 }) {
                if g.start - kept[i].start <= 90 * 60_000 {
                    let o = kept[i]
                    kept[i] = MatchGuideRule.Group(key: o.key, home: o.home, away: o.away, start: o.start, entries: o.entries + g.entries)
                } else { later[i, default: []] += g.entries }            // a later showing of the same match
            } else { byPair[k, default: []].append(kept.count); kept.append(g) }
        }
        return (kept, later)
    }

    /// 1.9.4: LiveSoccerTV lists every televised match of its days; a guide-only card inside the hours it covers is a
    /// replay the guide didn't mark (owner's photo: Monza × Fiorentina, Atalanta × Inter the day after), so it is not listed.
    static func scheduleCovers(_ rows: [Row]) -> (Int64) -> Bool {
        let ks = rows.filter { $0.kickoff != nil && $0.sources.contains(MatchFetchRule.lstv) }.compactMap(\.kickoff)
        guard ks.count >= 5, let mn = ks.min(), let mx = ks.max() else { return { _ in false } }
        let lo = mn - 6 * 3_600_000, hi = mx + 3 * 3_600_000
        return { $0 >= lo && $0 <= hi }
    }

    /// 1.10.2: why a row is listed apart («من الدليل — غير مرتبطة بجدول مباريات»), or nil for the main list.
    static func unlinkedWhy(_ r: Row, covers: (Int64) -> Bool) -> String? {
        r.unlinked ?? (r.kickoff == nil && covers(r.start) ? "من دليل المزوّد في ساعات يغطيها LiveSoccerTV ولا يذكرها — قد تكون إعادة غير معلَّمة" : nil)
    }

    static func rowsFor(_ rows: [Row], now: Int64, dayStart: Int64, tomorrow: Int64, end: Int64, day: Int, nowOnly: Bool, sport: MatchScreenRule.SportFilter,
                        importantOnly: Bool = false, unlinkedOnly: Bool = false) -> [Row] {
        let covers = scheduleCovers(rows)
        return rows.filter { r in
            if r.replay || youthOrWomen(r) || (r.links.isEmpty && r.missing.isEmpty && r.platforms.isEmpty) { return false }
            if (unlinkedWhy(r, covers: covers) != nil) != unlinkedOnly { return false }
            if importantOnly && !important(r) { return false }
            let sportOk = r.sport.sport == .football
            // 1.9.7 (owner 13:44: yesterday's matches still listed, not in time order): today = not ended yet (a match
            // that started yesterday shows only while it still airs); in kickoff order, the league order only for ties.
            let dayOk = nowOnly ? r.airingAt(now) : day == 0 ? (r.stop > max(now, dayStart) && r.start < tomorrow) : (r.start >= tomorrow && r.start < end)
            return sportOk && dayOk
        }.sorted { ($0.start, rank($0)) < ($1.start, rank($1)) }
    }

    struct Sections { let confirmed: [Link]; let possible: [Link]; let suggested: [Link]; let hidden: Int; var alternatives: [Link] = []
        /// 1.10.2: airings that don't fit the kickoff (timing conflict / showing type unknown).
        var timing: [Link] = [] }

    /// The sources a link rests on (for the source filter).
    static func linkSources(_ l: Link) -> Set<String> { Set(l.proofs.filter { $0.kind != .candidate }.map { $0.kind == .manual ? "أنت" : $0.source }) }

    static let unknownCountry = "دولة غير معروفة"
    static let unknownLang = "لغة غير معروفة"

    static func linkCountry(_ l: Link) -> String {
        let c = MatchGuideRule.country(l.name)
        return c == "بدون بادئة" || c.hasPrefix("تسمية") ? unknownCountry : c
    }
    static func linkLanguage(_ l: Link) -> String {
        language(l.name) ?? l.proofs.lazy.compactMap { language($0.detail ?? "") }.first ?? unknownLang
    }

    /// Countries / languages present in a row, most first.
    static func filterOptions(_ r: Row) -> (countries: [String], languages: [String]) {
        func rank(_ xs: [String]) -> [String] {
            Dictionary(grouping: xs, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { ($1.1, $0.0) < ($0.1, $1.0) }.map(\.0)
        }
        return (rank(r.links.map(linkCountry)), rank(r.links.map(linkLanguage)))
    }

    /// A chosen country keeps the unknown-country channels too, a chosen language keeps unknown language too.
    static func passes(_ l: Link, country: String?, lang: String?) -> Bool {
        let c = linkCountry(l), g = linkLanguage(l)
        let cOk = country == nil || c == country || (country != unknownCountry && c == unknownCountry)
        let gOk = lang == nil || g == lang || (lang != unknownLang && g == unknownLang)
        return cOk && gOk
    }

    /// 1.10.2 (owner §5): 4K → 1080p → 720p → SD → unknown, by the resolution the name states; HEVC and RAW are not a
    /// resolution — they only order versions of one resolution (RAW first). Same as the TV's 0.9.55.
    static func quality(_ v: MatchGuideRule.Version) -> Int {
        let r: Int
        switch v.res { case .uhd: r = 0; case .fhd: r = 1; case .hd: r = 2; case .sd: r = 3; default: r = 4 }
        return r * 2 + (v.raw ? 0 : 1)
    }

    static func sections(_ r: Row, versionOf: (String) -> MatchGuideRule.Version, hideHd: Bool, hideSd: Bool,
                         country: String? = nil, lang: String? = nil, hideUnknown: Bool = false, source: String? = nil) -> Sections {
        func ok(_ l: Link) -> Bool {
            let x = versionOf(l.name).res
            return !(hideHd && x == .hd) && !(hideSd && x == .sd) && !(hideUnknown && x == .unknown) && passes(l, country: country, lang: lang)
                && (source == nil || linkSources(l).contains(source!))
        }
        func sorted(_ l: [Link]) -> [Link] {
            let q = Dictionary(l.map { ($0.channelId, quality(versionOf($0.name))) }, uniquingKeysWith: { a, _ in a })
            return l.sorted { (q[$0.channelId] ?? 9, $0.best.rawValue, $0.name, $0.channelId) < (q[$1.channelId] ?? 9, $1.best.rawValue, $1.name, $1.channelId) }
        }
        let confirmed = r.links.filter(\.confirmed)
        let timing = r.links.filter { !$0.confirmed && $0.timing != nil }
        let alternatives = r.links.filter { !$0.confirmed && $0.timing == nil && $0.alt4k }
        let possible = r.links.filter { !$0.confirmed && $0.timing == nil && !$0.alt4k && $0.proofs.contains { $0.kind != .candidate } }
        let suggested = r.links.filter { !$0.alt4k && $0.timing == nil && $0.proofs.allSatisfy { $0.kind == .candidate } }
        let all = confirmed + alternatives + possible + suggested + timing
        return Sections(confirmed: sorted(confirmed.filter(ok)), possible: sorted(possible.filter(ok)), suggested: sorted(suggested.filter(ok)),
                        hidden: all.filter { !ok($0) }.count, alternatives: sorted(alternatives.filter(ok)), timing: sorted(timing.filter(ok)))
    }

    static func proofText(_ l: Link, fmt: (Int64) -> String) -> String {
        var parts: [String] = []
        for k in Kind.allCases {
            let ps = l.proofs.filter { $0.kind == k }
            if ps.isEmpty { continue }
            switch k {
            case .epg, .candidate: parts.append(k.label)
            case .manual: parts.append(k.label + " (\(fmt(ps.map(\.at).max() ?? 0)))")
            default:
                var seen: [String] = []
                for p in ps { let x = "\(p.source)، \(fmt(p.at))"; if !seen.contains(x) { seen.append(x) } }
                parts.append(k.label + " (" + seen.joined(separator: " / ") + ")")
            }
        }
        return parts.joined(separator: " · ") + (l.possible && !l.proofs.contains { $0.kind == .manual || $0.kind == .epg } ? " · مطابقة محتملة بالاسم" : "")
            + (l.timing.map { " · " + $0 } ?? "") + (l.rightsNote.map { " · " + $0 } ?? "")
    }
}

/// 1.8.0: downloads for watching offline — the rules, apart from URLSession, files and screens.
///
/// A file is downloaded in pieces with "Range: bytes=<have>-": the bytes already kept are never asked for again and
/// never written twice. Each answer is checked before its bytes are added:
/// - 206 whose Content-Range starts exactly at <have> (and, when the total is known, has the same total) → append;
/// - 200 (the server ignored the range): from 0 it is the whole file; with bytes already kept it would repeat them,
///   so the kept part is dropped and the answer is taken as the whole file (the viewer is told: not resumable);
/// - a different start or total (the file changed on the server) → nothing appended, the download stops with a reason;
/// - 416 when everything is already kept → complete; other codes → stop with the code.
/// A file is "ready" only when the bytes kept equal the total the server announced.
enum DownloadRule {
    struct ContentRange: Equatable { let start: Int64; let end: Int64; let total: Int64? }

    /// "bytes 100-199/1000" or "bytes 100-199/*".
    static func parseContentRange(_ s: String?) -> ContentRange? {
        guard var t = s?.trimmingCharacters(in: .whitespaces).lowercased(), t.hasPrefix("bytes") else { return nil }
        t = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let slash = t.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard slash.count == 2 else { return nil }
        let r = slash[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard r.count == 2, let a = Int64(r[0]), let b = Int64(r[1]), a >= 0, b >= a else { return nil }
        let total: Int64?
        if slash[1] == "*" { total = nil } else { guard let n = Int64(slash[1]), n > b else { return nil }; total = n }
        return ContentRange(start: a, end: b, total: total)
    }

    enum Reply: Equatable {
        /// Append these bytes after the kept ones; total of the file (nil = unknown yet).
        case append(total: Int64?)
        /// Drop what is kept; this answer is the file from its first byte. `ignoredRange`: the server didn't resume.
        case restart(total: Int64?, ignoredRange: Bool)
        /// Everything is already kept.
        case complete
        /// Nothing written; stop with this reason.
        case stop(Stop)
    }
    enum Stop: Equatable { case changed, wrongStart, http(Int), noTotal }

    static func reply(status: Int, contentRange: String?, contentLength: Int64?, have: Int64, knownTotal: Int64?) -> Reply {
        switch status {
        case 206:
            guard let cr = parseContentRange(contentRange) else { return .stop(.wrongStart) }
            if cr.start != have { return .stop(.wrongStart) }
            if let k = knownTotal, let t = cr.total, k != t { return .stop(.changed) }
            return .append(total: cr.total ?? knownTotal)
        case 200:
            let len = (contentLength ?? -1) > 0 ? contentLength : nil
            if let k = knownTotal, let l = len, k != l { return .stop(.changed) }
            return .restart(total: len ?? knownTotal, ignoredRange: have > 0)
        case 416:
            if let k = knownTotal, have == k { return .complete }
            return .stop(.changed)
        default:
            return .stop(.http(status))
        }
    }

    /// Ready only when every byte of a known total is kept (nothing missing, nothing extra).
    static func isComplete(have: Int64, total: Int64?) -> Bool { total != nil && total! > 0 && have == total! }

    /// Bytes of an interrupted piece that may be kept: what was received, cut at the total (never past it).
    static func salvage(received: Int64, have: Int64, total: Int64?) -> Int64 {
        guard received > 0 else { return 0 }
        if let t = total { return max(0, min(received, t - have)) }
        return received
    }

    /// Free space needed to go on: what is left to download plus a margin, so the phone isn't filled up.
    static let spareBytes: Int64 = 1_000_000_000
    static func enoughSpace(free: Int64, have: Int64, total: Int64?) -> Bool {
        guard let t = total else { return free > spareBytes }
        return free - (t - have) >= spareBytes
    }

    /// The resume check: a 1 MiB piece from the middle must come back as 206 with exactly that Content-Range.
    enum Probe: Equatable { case resumable(total: Int64), notResumable(String) }
    static func probe(status: Int, contentRange: String?, start: Int64, end: Int64, receivedBytes: Int64) -> Probe {
        guard status == 206 else { return .notResumable("ردّ \(status) بدل 206") }
        guard let cr = parseContentRange(contentRange) else { return .notResumable("بدون Content-Range صحيح") }
        guard cr.start == start, cr.end == end else { return .notResumable("Content-Range لموضع مختلف (\(cr.start)-\(cr.end))") }
        guard let t = cr.total else { return .notResumable("الحجم الكلي غير معروف") }
        guard receivedBytes == end - start + 1 else { return .notResumable("وصل \(receivedBytes) بايت بدل \(end - start + 1)") }
        return .resumable(total: t)
    }

    /// Name of the kept file: per source + item (the same film id on two sources is two files), no names in it.
    static func fileName(source: String, key: String, ext: String, sha256: (String) -> String) -> String {
        let e = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return "dl-" + String(sha256(source + "|" + key).prefix(24)) + "." + (e.isEmpty || e.count > 5 ? "mkv" : e)
    }

    /// 1.8.2: in the background the rest is fetched as pieces of `size` bytes (queued together, one connection), so a
    /// stop loses at most the piece in flight. Inclusive byte ranges, in order, covering have…total-1 exactly.
    static let pieceBytes: Int64 = 100 * 1_048_576
    static func pieces(have: Int64, total: Int64, size: Int64 = pieceBytes) -> [(start: Int64, end: Int64)] {
        guard size > 0, have < total else { return [] }
        var out: [(Int64, Int64)] = []
        var a = have
        while a < total { let b = min(a + size, total) - 1; out.append((a, b)); a = b + 1 }
        return out
    }

    /// Tag of a background piece task: "<item>|<start>|<end>" (no names, no links).
    static func pieceTag(_ id: String, _ start: Int64, _ end: Int64) -> String { "\(id)|\(start)|\(end)" }
    static func parsePieceTag(_ s: String?) -> (id: String, start: Int64, end: Int64)? {
        guard let p = s?.split(separator: "|"), p.count == 3, let a = Int64(p[1]), let b = Int64(p[2]), b >= a else { return nil }
        return (String(p[0]), a, b)
    }

    /// A finished piece is accepted only if the server answered 206 for exactly that range and all its bytes arrived.
    static func pieceOK(status: Int, contentRange: String?, start: Int64, end: Int64, size: Int64, knownTotal: Int64?) -> Bool {
        guard status == 206, let cr = parseContentRange(contentRange), cr.start == start, cr.end == end else { return false }
        if let k = knownTotal, let t = cr.total, k != t { return false }
        return size == end - start + 1
    }

    /// Finished pieces (start → size) that can be added now, in order, from the kept size: only an unbroken run.
    static func mergeOrder(have: Int64, pieces: [Int64: Int64]) -> [Int64] {
        var out: [Int64] = []
        var at = have
        while let n = pieces[at], n > 0 { out.append(at); at += n }
        return out
    }

    /// The part of an interrupted URLSession piece that URLSession kept, from its resume data (a property list):
    /// temporary file name and bytes received. nil when the format isn't the expected one.
    static func resumeInfo(_ data: Data) -> (file: String, bytes: Int64)? {
        guard let p = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let name = (p["NSURLSessionResumeInfoTempFileName"] as? String)
            ?? (p["NSURLSessionResumeInfoLocalPath"] as? String).map { ($0 as NSString).lastPathComponent }
        let bytes = (p["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
        guard let n = name, !n.isEmpty, !n.contains("/"), let b = bytes, b >= 0 else { return nil }
        return (n, b)
    }
}

/// 1.8.8: Live-FootballOnTV and LiveSoccerTV read automatically (owner: personal use). Same parsing as the TV's MatchFetchCore.
enum MatchFetchRule {
    static let lstv = "LiveSoccerTV (تلقائي)"
    static let lfotv = "Live-FootballOnTV (تلقائي)"
    static let lfotvURL = "https://www.live-footballontv.com/"
    static let lstvBase = "https://www.livesoccertv.com"

    private static func re(_ p: String, dot: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: dot ? [.dotMatchesLineSeparators] : [])
    }
    private static func groups(_ r: NSRegularExpression, _ s: String) -> [[String?]] {
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        }
    }
    private static func first(_ p: String, _ s: String) -> [String?]? { groups(re(p), s).first }

    static func decode(_ s: String) -> String {
        var t = re("<[^>]+>").stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        for g in groups(re("&#(\\d+);"), t) {
            if let n = g[1].flatMap({ UInt32($0) }), let u = Unicode.Scalar(n) { t = t.replacingOccurrences(of: g[0]!, with: String(Character(u))) }
        }
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static func lfotvDate(_ s: String) -> DateComponents? {
        guard let m = first("(\\d{1,2})(?:st|nd|rd|th)?\\s+([A-Za-z]+)\\s+(\\d{4})", s),
              let d = Int(m[1] ?? ""), let y = Int(m[3] ?? ""), let mon = months.firstIndex(of: (m[2] ?? "").lowercased()) else { return nil }
        return DateComponents(year: y, month: mon + 1, day: d)
    }

    static func parseLfotv(_ html: String, fetchedAt: Int64, from: Int64, to: Int64) -> MatchSourcesRule.ExtSource {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        var out: [MatchSourcesRule.ExtMatch] = []
        var day: DateComponents?
        for g in groups(re("<div class=\"fixture-date\">(.*?)</div>|<div class=\"fixture\">(.*?)</div></div></div>"), html) {
            if let h = g[1] { day = lfotvDate(decode(h)); continue }
            guard var d = day, let f = g[2] else { continue }
            func cls(_ c: String) -> String? { first("<div class=\"\(c)\">(.*?)</div>", f)?[1].map(decode) }
            guard let tm = cls("fixture__time").flatMap({ first("(\\d{1,2}):(\\d{2})", $0) }), let hh = Int(tm[1] ?? ""), let mm = Int(tm[2] ?? ""),
                  let teams = cls("fixture__teams") else { continue }
            let parts = teams.components(separatedBy: " v ")
            guard parts.count >= 2 else { continue }
            let home = parts[0].trimmingCharacters(in: .whitespaces), away = parts[1...].joined(separator: " v ").trimmingCharacters(in: .whitespaces)
            if home.isEmpty || away.isEmpty { continue }
            d.hour = hh; d.minute = mm
            guard let date = cal.date(from: d) else { continue }
            let ko = Int64(date.timeIntervalSince1970 * 1000)
            if ko < from || ko >= to { continue }
            var names: [String] = []
            for c in groups(re("<span class=\"channel-pill\"[^>]*>(.*?)</span>"), f) { let n = decode(c[1] ?? ""); if !n.isEmpty && !names.contains(n) { names.append(n) } }
            out.append(MatchSourcesRule.ExtMatch(home: home, away: away, kickoff: ko, competition: cls("fixture__competition"), sport: "football",
                                                 channels: names.map { MatchSourcesRule.ExtChannel(name: $0, country: "GB", programmeStart: nil) }))
        }
        return MatchSourcesRule.ExtSource(name: lfotv, kind: .guide, url: lfotvURL, fetchedAt: fetchedAt, importedAt: fetchedAt, matches: out)
    }

    struct DayMatch: Equatable { let id: String; let url: String; let home: String; let away: String; let kickoff: Int64; let competition: String?; let channels: [String] }

    static func parseLstvDay(_ html: String) -> [DayMatch] {
        var out: [DayMatch] = []
        var comp: String?
        for g in groups(re("class=\"r_complink\"><span class=\"[^\"]*\">(.*?)</span>|<tr id=\"(\\d+)\" class=\"matchrow\"(.*?)</tr>"), html) {
            if let c = g[1] {
                let t = decode(c)
                comp = t.isEmpty ? nil : t          // the country stays («England - Premier League»)
                continue
            }
            guard let id = g[2], let row = g[3],
                  let ko = first("id=\"ko\(id)\" class=\"ts\" dv=\"(\\d+)\"", row)?[1].flatMap({ Int64($0) }),
                  let a = first("<a href=\"(https://www\\.livesoccertv\\.com/match/[^\"#]+)[^\"]*\" title=\"([^\"]*)\"", row),
                  let url = a[1] else { continue }
            let title = decode(a[2] ?? "").components(separatedBy: " vs ")
            guard title.count >= 2 else { continue }
            let chs = groups(re("<a href=\"https://www\\.livesoccertv\\.com/channels/[^\"]+\" title=\"[^\"]*\" class=\"[^\"]*\">(.*?)</a>"), row).compactMap { $0[1].map(decode) }.filter { !$0.isEmpty }
            out.append(DayMatch(id: id, url: url, home: title[0].trimmingCharacters(in: .whitespaces),
                                away: title[1...].joined(separator: " vs ").trimmingCharacters(in: .whitespaces), kickoff: ko, competition: comp, channels: chs))
        }
        return out
    }

    struct Coverage: Equatable { let country: String; let name: String; let slug: String }
    struct MatchPage: Equatable { var home: String?; var away: String?; var start: Int64?; var coverage: [Coverage] }

    static func parseLstvMatch(_ html: String) -> MatchPage {
        var p = MatchPage(home: nil, away: nil, start: nil, coverage: [])
        let iso = ISO8601DateFormatter()
        for b in groups(re("<script type=\"application/ld\\+json\">(.*?)</script>"), html) {
            guard let txt = b[1], let obj = try? JSONSerialization.jsonObject(with: Data(txt.utf8)) as? [String: Any] else { continue }
            let graph = (obj["@graph"] as? [[String: Any]]) ?? [obj]
            for o in graph where (o["@type"] as? String) == "SportsEvent" {
                if let n = (o["homeTeam"] as? [String: Any])?["name"] as? String, !n.isEmpty { p.home = n }
                if let n = (o["awayTeam"] as? [String: Any])?["name"] as? String, !n.isEmpty { p.away = n }
                if let s = o["startDate"] as? String, let d = iso.date(from: s) { p.start = Int64(d.timeIntervalSince1970 * 1000) }
            }
        }
        if let r = html.range(of: "class=\"data aleft ichannels\"") {
            let rest = html[r.lowerBound...]
            let table = String(rest[..<(rest.range(of: "</table>")?.lowerBound ?? rest.endIndex)])
            for row in groups(re("<tr>(.*?)</tr>"), table) {
                guard let cells = row[1], let country = first("<span class=\"flag[^\"]*\">(.*?)</span>", cells)?[1].map(decode) else { continue }
                for a in groups(re("<a href=\"https://www\\.livesoccertv\\.com/channels/([^/\"]+)/?\"[^>]*>(.*?)</a>"), cells) {
                    let n = decode(a[2] ?? ""); if !n.isEmpty, let slug = a[1] { p.coverage.append(Coverage(country: country, name: n, slug: slug)) }
                }
            }
        }
        return p
    }

    static func lstvSource(_ days: [DayMatch], pages: [String: MatchPage], fetchedAt: Int64, from: Int64, to: Int64) -> MatchSourcesRule.ExtSource {
        var seen = Set<String>(); var out: [MatchSourcesRule.ExtMatch] = []
        for d in days where seen.insert(d.id).inserted {
            let p = pages[d.url]
            let ko = p?.start ?? d.kickoff
            if ko < from || ko >= to { continue }
            var chs: [MatchSourcesRule.ExtChannel] = []
            if let p, !p.coverage.isEmpty {
                var k = Set<String>()
                for c in p.coverage where k.insert(c.slug + "|" + c.country).inserted { chs.append(.init(name: c.name, country: c.country, programmeStart: nil, id: c.slug)) }
            } else {
                var k = Set<String>()
                for n in d.channels where k.insert(n).inserted { chs.append(.init(name: n, country: nil, programmeStart: nil)) }
            }
            out.append(.init(home: p?.home ?? d.home, away: p?.away ?? d.away, kickoff: ko, competition: d.competition, sport: "football", channels: chs, id: d.id))
        }
        return MatchSourcesRule.ExtSource(name: lstv, kind: .guide, url: lstvBase + "/schedules/", fetchedAt: fetchedAt, importedAt: fetchedAt, matches: out)
    }

    /// Day pages around the window (the site's day is not ours): yesterday … today + days − 1, as yyyy-MM-dd.
    static func lstvDayURLs(today: Date, days: Int, tz: TimeZone = .current) -> [String] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return (-1..<days).compactMap { cal.date(byAdding: .day, value: $0, to: today) }.map { lstvBase + "/schedules/" + f.string(from: $0) + "/" }
    }

    // ---------- protecting what is kept (owner 05:55) — same as the TV ----------

    static func looksLikeLfotv(_ h: String) -> Bool { h.contains("class=\"fixture-date\"") && h.contains("class=\"fixture\"") }
    static func looksLikeLstvDay(_ h: String) -> Bool { h.contains("class=\"schedules\"") && (h.contains("r_comprow") || h.contains("matchrow")) }
    static func looksLikeLstvMatch(_ h: String) -> Bool { h.contains("SportsEvent") || h.contains("ichannels") }

    static func priority(_ days: [DayMatch]) -> [DayMatch] {
        days.sorted { (MatchSourcesRule.rank($0.competition), $0.kickoff, $0.id) < (MatchSourcesRule.rank($1.competition), $1.kickoff, $1.id) }
    }

    static func mergeLstv(previous: MatchSourcesRule.ExtSource?, days: [DayMatch], dayPagesFailed: Int, pages: [String: MatchPage],
                          notRead: [DayMatch], fetchedAt: Int64, from: Int64, to: Int64, lastFull: String?) -> MatchSourcesRule.ExtSource {
        var fresh = lstvSource(days, pages: pages, fetchedAt: fetchedAt, from: from, to: to)
        var prevById: [String: MatchSourcesRule.ExtMatch] = [:]
        for m in previous?.matches ?? [] { if let id = m.id { prevById[id] = m } }
        var out: [MatchSourcesRule.ExtMatch] = fresh.matches.map { m in
            var x = m
            let read = days.first { $0.id == m.id }.flatMap { pages[$0.url] }.map { !$0.coverage.isEmpty } ?? false
            if !read, let id = m.id, let p = prevById[id], !p.channels.isEmpty {
                x = MatchSourcesRule.ExtMatch(home: m.home, away: m.away, kickoff: m.kickoff, competition: m.competition, sport: m.sport,
                                              channels: p.channels, id: m.id, fetchedAt: p.fetchedAt ?? previous!.fetchedAt)
            } else { x.fetchedAt = fetchedAt }
            return x
        }
        if dayPagesFailed > 0, let previous {
            let have = Set(out.compactMap(\.id))
            for m in previous.matches where !(m.id.map(have.contains) ?? false) && m.kickoff >= from && m.kickoff < to {
                var k = m; k.fetchedAt = m.fetchedAt ?? previous.fetchedAt; out.append(k)
            }
        }
        let complete = dayPagesFailed == 0 && notRead.isEmpty
        var parts: [String] = []
        if dayPagesFailed > 0 { parts.append("\(dayPagesFailed) صفحة يوم لم تُقرأ (بقيت مبارياتها السابقة)") }
        if !notRead.isEmpty { parts.append("\(notRead.count) مباراة بلا صفحة تغطية (بقيت قنواتها السابقة أو قنوات صفحة اليوم)") }
        fresh.status = complete ? "جلب كامل لما في صفحات اليوم (البطولات المطوية في الموقع لا تُجلب)"
            : "جلب جزئي: " + parts.joined(separator: "، ") + (lastFull.map { " · آخر جلب كامل " + $0 } ?? " · لا جلب كامل بعد") + " · البطولات المطوية في الموقع لا تُجلب"
        fresh.matches = out.sorted { $0.kickoff < $1.kickoff }
        return fresh
    }

    /// Never while the site asked to wait; at most every 15 min (also forced); every 6 h, or at once on a new local day.
    static func due(now: Int64, lastAttempt: Int64, lastSuccess: Int64, blockedUntil: Int64, force: Bool, tz: TimeZone = .current) -> Bool {
        if now < blockedUntil { return false }
        if now - lastAttempt < 15 * 60_000 { return false }
        if force || lastSuccess == 0 { return true }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let d = { (t: Int64) in cal.startOfDay(for: Date(timeIntervalSince1970: Double(t) / 1000)) }
        return d(lastSuccess) != d(now) || now - lastSuccess >= 6 * 3_600_000
    }

    /// Retry-After (seconds or an HTTP date), else 6 h for 429/403, else none.
    static func waitAfter(code: Int, retryAfter: String?, now: Int64) -> Int64 {
        let ra = retryAfter?.trimmingCharacters(in: .whitespaces)
        if let ra, let s = Int64(ra) { return now + s * 1000 }
        if let ra {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let d = f.date(from: ra) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return code == 429 || code == 403 ? now + 6 * 3_600_000 : now
    }

    /// The "shasha-matches" v1 file, so a fetched schedule goes through the same checks and merge as an import.
    static func toJSON(_ s: MatchSourcesRule.ExtSource) -> Data {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // milliseconds kept, as on the TV
        func iso(_ ms: Int64) -> String { f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        let ms: [[String: Any]] = s.matches.map { m in
            var o: [String: Any] = ["home": m.home, "away": m.away, "kickoff": iso(m.kickoff)]
            if let c = m.competition { o["competition"] = c }; if let sp = m.sport { o["sport"] = sp }; if let id = m.id { o["id"] = id }
            if let t = m.fetchedAt { o["fetchedAt"] = iso(t) }
            o["channels"] = m.channels.map { c -> [String: Any] in
                var x: [String: Any] = ["name": c.name]
                if let v = c.country { x["country"] = v }; if let v = c.id { x["id"] = v }
                if let v = c.programmeStart { x["programmeStart"] = iso(v) }; if let v = c.type { x["type"] = "\(v)" }
                return x
            }
            return o
        }
        var src: [String: Any] = ["name": s.name, "kind": s.kind == .broadcaster ? "broadcaster" : "guide", "fetchedAt": iso(s.fetchedAt)]
        if let u = s.url { src["url"] = u }; if let st = s.status { src["status"] = st }
        if s.programmeTimes { src["times"] = "programme" }; if s.confirmOnly { src["confirm"] = "only" }; if let o = s.origin { src["origin"] = o }
        let root: [String: Any] = ["format": "shasha-matches", "version": 1, "source": src, "matches": ms,
                                   "note": "Read automatically by Shasha for the owner's personal use; source: \(s.name)."]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

// MARK: - 1.10.0: published XMLTV guides as match schedules (TV 0.9.44 / 0.9.53)

/// Reads a published XMLTV guide for match schedules: channel names, and only the programmes that name two sides.
/// Same rules as the TV's GuideXmltv + GuideScheduleCore.
enum GuideFeedRule {
    struct Prog { let channel: String; let start: Int64; let stop: Int64; let title: String; let subTitle: String?; let category: String?
        /// The UTC offset the file states for `start`, in minutes (some feeds state a wrong one).
        let offsetMin: Int? }

    final class Reader: NSObject, XMLParserDelegate {
        var channels: [String: String] = [:]
        var progs: [Prog] = []
        let from: Int64, to: Int64
        private var ch = "", start: Int64?, stop: Int64?, off: Int?, title: String?, sub: String?, cat: String?
        private var text = "", inProg = false, chanId: String?
        init(from: Int64, to: Int64) { self.from = from; self.to = to }
        static let twoSides = try! NSRegularExpression(pattern: "(?i)\\s(v|vs\\.?)\\s")
        static func time(_ s: String?) -> (Int64, Int?)? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), s.count >= 14 else { return nil }
            let d = String(s.prefix(14))
            var c = DateComponents(); c.timeZone = TimeZone(identifier: "UTC")
            guard let y = Int(d.prefix(4)), let mo = Int(d.dropFirst(4).prefix(2)), let da = Int(d.dropFirst(6).prefix(2)),
                  let h = Int(d.dropFirst(8).prefix(2)), let mi = Int(d.dropFirst(10).prefix(2)), let se = Int(d.dropFirst(12).prefix(2)) else { return nil }
            c.year = y; c.month = mo; c.day = da; c.hour = h; c.minute = mi; c.second = se
            guard let date = Calendar(identifier: .gregorian).date(from: c) else { return nil }
            var off: Int? = nil
            let rest = s.dropFirst(14).trimmingCharacters(in: .whitespaces)
            if rest.count == 5, let sign = rest.first, let hh = Int(rest.dropFirst().prefix(2)), let mm = Int(rest.suffix(2)) {
                off = (hh * 60 + mm) * (sign == "-" ? -1 : 1)
            }
            return (Int64(date.timeIntervalSince1970 * 1000) - Int64((off ?? 0) * 60_000), off)
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            switch e {
            case "channel": chanId = a["id"]
            case "programme":
                inProg = true; ch = a["channel"] ?? ""
                let t = Self.time(a["start"]); start = t?.0; off = t?.1; stop = Self.time(a["stop"])?.0
                title = nil; sub = nil; cat = nil
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch e {
            case "display-name": if let id = chanId, !t.isEmpty, channels[id] == nil { channels[id] = t }
            case "channel": chanId = nil
            case "title" where inProg: if title == nil { title = t }
            case "sub-title" where inProg: if sub == nil { sub = t }
            case "category" where inProg: if !t.isEmpty { cat = cat.map { $0 + " / " + t } ?? t }
            case "programme":
                inProg = false
                // a ±1 day margin: a feed whose stated offset is wrong is corrected after this window check
                if let st = start, !ch.isEmpty, st >= from - 27 * 3_600_000, st < to + 24 * 3_600_000 {
                    let both = " \(title ?? "") ", sb = " \(sub ?? "") "
                    if Self.twoSides.firstMatch(in: both, range: NSRange(both.startIndex..., in: both)) != nil
                        || Self.twoSides.firstMatch(in: sb, range: NSRange(sb.startIndex..., in: sb)) != nil {
                        progs.append(Prog(channel: ch, start: st, stop: stop ?? st + 2 * 3_600_000, title: title ?? "", subTitle: sub, category: cat, offsetMin: off))
                    }
                }
            default: break
            }
            text = ""
        }
    }

    static func read(_ data: Data, from: Int64, to: Int64) -> Reader {
        let r = Reader(from: from, to: to)
        let p = XMLParser(data: data); p.delegate = r; p.parse()
        return r
    }

    // ---------- beIN MENA guide relayed by epgshare01 (origin: bein.com) ----------

    static let beinFeed = "https://epgshare01.online/epgshare01/epg_ripper_BEIN1.xml.gz"
    static let beinZone = TimeZone(identifier: "Asia/Qatar")!

    private static func m(_ pattern: String, _ s: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let r = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<r.numberOfRanges).map { r.range(at: $0).location == NSNotFound ? "" : String(s[Range(r.range(at: $0), in: s)!]) }
    }

    /// The feed's channel ids → channel names (both the _AR and _EN ids: their lists are not always the same).
    static func beinName(_ id: String) -> String? {
        guard let g = m("^(.*)_(EN|AR)\\.bein$", id) else { return nil }
        let s = g[1]
        if m("^4k_DIGITAL", s) != nil { return "beIN SPORTS 4K" }
        if m("^4K-HDR", s) != nil { return "beIN SPORTS 4K HDR" }
        if let x = m("^beIN_SPORTS(\\d)_(ENGLISH|FRENCH)", s) { return "beIN SPORTS \(x[1]) \(x[2].lowercased().capitalized)" }
        if let x = m("^beIN_SPORTS([1-9])_DIGITAL", s) { return "beIN SPORTS \(x[1])" }
        if let x = m("^beIN_SPORTS_MAX(\\d)", s) { return "beIN SPORTS MAX \(x[1])" }
        if let x = m("^beIN_SPORTS_XTRA_?(?:Digital_)?0?(\\d)", s) { return "beIN SPORTS XTRA \(x[1])" }
        if let x = m("^logos-_beINSPORTSXTRA(\\d)", s) { return "beIN SPORTS XTRA \(x[1])" }
        if let x = m("^logos-_beINSPORTS(\\d)", s) { return "beIN SPORTS \(x[1])" }
        if let x = m("^Alkass_(\\d)", s) { return "Alkass \(x[1])" }
        return nil
    }

    /// [ms] was read with the file's stated offset; the same wall-clock time in [zone] instead.
    static func wallClock(_ ms: Int64, statedOffsetMin: Int?, zone: TimeZone) -> Int64 {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: Date(timeIntervalSince1970: Double(ms + Int64((statedOffsetMin ?? 0) * 60_000)) / 1000))
        var z = Calendar(identifier: .gregorian); z.timeZone = zone
        return Int64((z.date(from: c)?.timeIntervalSince1970 ?? Double(ms) / 1000) * 1000)
    }

    private static let notMatch = try! NSRegularExpression(pattern: "(?i)\\b(magazine|preview|review|highlights|goals|ملخص|أهداف|استوديو|studio|countdown|road to)\\b")

    /// 1.10.2 / 1.10.3 (owner 18:47 §4, 19:37; TV 0.9.56): Qatar time is not forced. Per independent match (not per channel)
    /// and in both readings, a programme counts as the live airing when it starts `fitBefore` min before to `fitAfter` min after
    /// the kickoff AND runs at least `fitCover` min after it (it covers the match; a studio ending at the kickoff does not).
    /// Programmes the guide marks as replay / studio / preview / highlights are not used. A match fitting both readings
    /// proves nothing; Qatar time is applied only with ≥ `minMatches` Qatar-only matches, more than twice the stated-only ones.
    static let fitBefore = 120, fitAfter = 10, fitCover = 95, minMatches = 3

    struct ZoneCheck: Equatable {
        let qatarOnly: Int, statedOnly: Int, both: Int, neither: Int, apply: Bool
        var compared: Int { qatarOnly + statedOnly + both + neither }
        var qatar: Int { qatarOnly + both }
        var stated: Int { statedOnly + both }
        var confirmedStated: Bool { !apply && statedOnly >= GuideFeedRule.minMatches && statedOnly > 2 * qatarOnly }
        var text: String {
            let counts = "من \(compared) مباراة مستقلة مشتركة مع جدول فيه موعد انطلاق: \(qatarOnly) تطابق بتوقيت قطر فقط، \(statedOnly) بتوقيت الملف فقط، "
                + "\(both) بالاثنين (لا تحسم)، \(neither) بلا تطابق · المطابقة: برنامج يبدأ بين \(GuideFeedRule.fitBefore) دقيقة قبل الانطلاق و\(GuideFeedRule.fitAfter) بعده ويستمر \(GuideFeedRule.fitCover) دقيقة بعده على الأقل، بدون برامج الإعادة والاستوديو"
            if compared == 0 { return "تصحيح التوقيت: غير مؤكد — لا مباريات مشتركة مع جدول فيه موعد انطلاق؛ بقي توقيت الملف كما هو" }
            if apply { return "تصحيح التوقيت: طُبّق توقيت قطر بدل المذكور في الملف · " + counts }
            if confirmedStated { return "تصحيح التوقيت: لم يُطبّق — توقيت الملف يطابق · " + counts }
            return "تصحيح التوقيت: غير مؤكد — الدليل غير كافٍ، بقي توقيت الملف كما هو (قد يكون خاطئًا) · " + counts
        }
    }

    static func checkZone(_ progs: [Prog], schedule: [MatchSourcesRule.ExtMatch], zone: TimeZone = beinZone) -> ZoneCheck {
        var ko: [String: Int64] = [:]
        for m in schedule { let k = MatchGuideRule.teamKey(m.home) + "|" + MatchGuideRule.teamKey(m.away); if ko[k] == nil { ko[k] = m.kickoff } }
        func fits(_ a: Int64, _ b: Int64, _ k: Int64) -> Bool { (Int64(-fitBefore) * 60_000...Int64(fitAfter) * 60_000).contains(a - k) && b - k >= Int64(fitCover) * 60_000 }
        var q: [String: Bool] = [:], st: [String: Bool] = [:]
        for p in progs {
            guard beinName(p.channel) != nil else { continue }
            let title = p.title.trimmingCharacters(in: .whitespaces)
            if notMatch.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil { continue }
            let kind = MatchGuideRule.kind(title: title, description: nil, minutes: (p.stop - p.start) / 60_000)
            if kind == .replay || kind == .studio { continue }
            guard let t = MatchGuideRule.teams(title) else { continue }
            let key = MatchGuideRule.teamKey(t.home) + "|" + MatchGuideRule.teamKey(t.away)
            guard let k = ko[key], abs(p.start - k) <= 8 * 3_600_000 else { continue }
            let shift = wallClock(p.start, statedOffsetMin: p.offsetMin, zone: zone) - p.start
            // the file already states Qatar's offset: both readings are the same instant — that is the file's time
            q[key] = (q[key] ?? false) || (shift != 0 && fits(p.start + shift, p.stop + shift, k))
            st[key] = (st[key] ?? false) || fits(p.start, p.stop, k)
        }
        var qo = 0, so = 0, both = 0, none = 0
        for key in q.keys {
            switch (q[key] == true, st[key] == true) { case (true, true): both += 1; case (true, false): qo += 1; case (false, true): so += 1; default: none += 1 }
        }
        return ZoneCheck(qatarOnly: qo, statedOnly: so, both: both, neither: none, apply: qo >= minMatches && qo > 2 * so)
    }

    /// The beIN feed → confirm-only matches (no live marker). `zoneFix`: read the wall-clock time as Qatar time (decided by
    /// `checkZone`, or off). The file's own start and offset are kept with each match.
    static func fromBeinFeed(name: String, url: String?, progs: [Prog], fetchedAt: Int64, from: Int64, to: Int64, zoneFix: ZoneCheck? = nil) -> MatchSourcesRule.ExtSource {
        let fix = zoneFix?.apply == true
        var orig: [String: String] = [:]
        var order: [String] = []
        var acc: [String: (home: String, away: String, start: Int64, comp: String?, chs: [String])] = [:]
        for p in progs {
            guard let ch = beinName(p.channel) else { continue }
            let title = p.title.trimmingCharacters(in: .whitespaces), sub = (p.subTitle ?? "").trimmingCharacters(in: .whitespaces)
            if notMatch.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil { continue }
            guard let teams = MatchGuideRule.teams(title) else { continue }
            if MatchGuideRule.sport(title: "\(title) \(sub)", description: nil, category: p.category, channel: ch).sport != .football { continue }
            let start = fix ? wallClock(p.start, statedOffsetMin: p.offsetMin, zone: beinZone) : p.start
            if start < from - 3 * 3_600_000 || start >= to { continue }
            let key = MatchGuideRule.teamKey(teams.home) + "|" + MatchGuideRule.teamKey(teams.away) + "@\(start)"
            if acc[key] == nil {
                acc[key] = (teams.home, teams.away, start, sub.isEmpty ? p.category : sub, []); order.append(key)
                let off = p.offsetMin ?? 0
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: off * 60); f.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
                orig[key] = f.string(from: Date(timeIntervalSince1970: Double(p.start) / 1000))
            }
            if !acc[key]!.chs.contains(ch) { acc[key]!.chs.append(ch) }
        }
        let matches = order.compactMap { k -> MatchSourcesRule.ExtMatch? in
            guard let a = acc[k] else { return nil }
            return MatchSourcesRule.ExtMatch(home: a.home, away: a.away, kickoff: a.start, competition: a.comp, sport: "football",
                                      channels: a.chs.map { MatchSourcesRule.ExtChannel(name: $0, country: "QA", programmeStart: a.start) },
                                      id: "بداية البرنامج في الملف: \(orig[k] ?? "")")
        }.sorted { $0.kickoff < $1.kickoff }
        return MatchSourcesRule.ExtSource(name: name, kind: .broadcaster, url: url, fetchedAt: fetchedAt, importedAt: fetchedAt, matches: matches,
            status: "\(matches.count) مباراة كرة قدم في الدليل · \(zoneFix?.text ?? "تصحيح التوقيت: موقوف") · يضيف قنوات beIN لمباراة معروفة من جدول آخر فقط · المصدر الأصلي bein.com عبر epgshare01",
            programmeTimes: true, confirmOnly: true, origin: "bein.com")
    }
}

// MARK: - 1.10.1: Dutch / French channel diagnosis (owner 18:47 §1) — same rules as the TV's 0.9.54
extension MatchGuideRule {
    /// 1.10.2 (owner 19:06; TV 0.9.55): a Dutch or French channel, and why — the country from the prefix (also after a group
    /// label such as «8K:»), the playlist group or the guide id; else a brand of that country only (Ziggo, RMC, L'Équipe,
    /// Eurosport 360, Ligue 1+) or the French beIN edition. A network name alone (Canal+, ESPN, beIN) is not enough.
    static func focusWhy(_ name: String, group: String? = nil, tvgId: String? = nil, labels: Set<String> = [], manual: String? = nil) -> (country: String, why: String)? {
        let o = MatchSourcesRule.libCountry(name, group: group, tvgId: tvgId, labels: labels, manual: manual)
        if o.country == "هولندا" || o.country == "فرنسا" { return (o.country!, o.why + " · الثقة: \(o.trust.label)" + (o.conflict.map { " · ⚠︎ تعارض: " + $0 } ?? "")) }
        if o.country != nil { return nil }
        let w = " " + words(name) + " "
        if w.contains(" ziggo ") { return ("هولندا", "الاسم «Ziggo» (شبكة هولندية فقط)") }
        for (k, v) in [(" rmc ", "RMC"), (" l equipe ", "L'Équipe"), (" eurosport 360 ", "Eurosport 360"), (" ligue 1 ", "Ligue 1+")] where w.contains(k) {
            return ("فرنسا", "الاسم «\(v)» (قناة فرنسية فقط)")
        }
        if MatchSourcesRule.edition(name).contains("fr") { return ("فرنسا", "نسخة beIN الفرنسية في الاسم (French/FRANCE)") }
        return nil
    }
    static func isFocus(_ name: String) -> Bool { focusWhy(name) != nil }

    /// One library channel in the diagnosis. `how`: 1 guide id (tvg-id), 2 name, 0 none.
    struct Focus {
        let channelId: String, name: String, list: String, tvgId: String?, how: Int, guideId: String?
        var why = "", country = ""
        var upcoming = 0, withSep = 0, matches = 0
        var first: Int64 = 0, last: Int64 = 0
        var samples: [String] = []

        /// The kind of reason, for the counts (the owner's list, in his order).
        func reasonKind(now: Int64) -> String {
            if guideId == nil { return (tvgId ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "غير مربوطة: ما عندها معرّف EPG" : "المعرّف غير موجود في الدليل المحمّل" }
            if last == 0 { return "مربوطة لكن لا برامج لها" }
            if last < now { return "الدليل قديم" }
            if upcoming == 0 { return "لا برامج قادمة في النطاق" }
            if matches == 0 && withSep == 0 { return "البرامج بلا عناوين مباريات" }
            if matches == 0 { return "قواعد الاكتشاف استبعدتها" }
            return "تعمل"
        }
        func reason(now: Int64, fmt: (Int64) -> String) -> String {
            switch reasonKind(now: now) {
            case "غير مربوطة: ما عندها معرّف EPG": return "غير مربوطة: ما عندها معرّف EPG (tvg-id فاضي) ولا اسم يطابق قناة في الدليل"
            case "المعرّف غير موجود في الدليل المحمّل": return "المعرّف «\(tvgId ?? "")» غير موجود في الدليل المحمّل ولا اسم يطابق — الدليل لا يغطيها (مصدر الدليل غير مضاف) أو المعرّف مختلف"
            case "مربوطة لكن لا برامج لها": return "مربوطة بالدليل («\(guideId ?? "")»\(how == 2 ? " بالاسم" : "")) لكن لا برامج لها فيه"
            case "الدليل قديم": return "الدليل قديم: آخر برنامج لها ينتهي \(fmt(last))"
            case "لا برامج قادمة في النطاق": return "لا برامج قادمة في نطاق اليوم وبكرة"
            case "البرامج بلا عناوين مباريات": return "البرامج موجودة (\(upcoming)) لكن لا عنوان فيه فريقان (الدليل يكتب أسماء برامج عامة)"
            case "قواعد الاكتشاف استبعدتها": return "البرامج موجودة وفيها \(withSep) عنوان بفاصل، لكن قواعد اكتشاف المباريات استبعدتها"
            default: return "تعمل: \(matches) مباراة"
            }
        }
    }
}
