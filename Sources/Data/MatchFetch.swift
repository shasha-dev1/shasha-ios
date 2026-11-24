import Foundation

/// 1.8.8–1.8.9: reads Live-FootballOnTV and LiveSoccerTV automatically (owner: personal use). Same rules as the TV's
/// MatchFetch (owner 05:55): one run at a time whatever starts it; per site the last attempt / success / complete fetch;
/// 429/403 and Retry-After honoured; a failed or unexpected page never replaces a good schedule; a partial LiveSoccerTV
/// run keeps the older coverage of what it could not read and says so; progress published for the screen.
///
/// What actually happens on the iPhone: there is no start timer — a run starts when the matches screen opens (if due)
/// or on Refresh / «fetch now». It runs only while the app is in the foreground: if the app goes to the background iOS
/// suspends it; when the app comes back it continues, and requests that failed meanwhile count as not read (the partial
/// rules above keep the older data). Nothing is fetched while the app is closed.
@MainActor
final class MatchFetch: ObservableObject {
    static let shared = MatchFetch()
    static let maxMatchPages = 80
    @Published private(set) var progress: String?
    private var job: Task<Bool, Never>?
    var running: Bool { job != nil }

    private let d = UserDefaults.standard
    private func k(_ site: String, _ x: String) -> String { "matchFetch." + (site.split(separator: " ").first.map(String.init) ?? site) + "." + x }
    func lastAttempt(_ s: String) -> Int64 { Int64(d.double(forKey: k(s, "attempt"))) }
    func lastSuccess(_ s: String) -> Int64 { Int64(d.double(forKey: k(s, "success"))) }
    func lastFull(_ s: String) -> Int64 { Int64(d.double(forKey: k(s, "full"))) }
    func blockedUntil(_ s: String) -> Int64 { Int64(d.double(forKey: k(s, "blocked"))) }
    func lastLine(_ s: String) -> String { d.string(forKey: k(s, "line")) ?? "" }
    private func set(_ s: String, _ x: String, _ v: Int64) { d.set(Double(v), forKey: k(s, x)) }

    let sites = [MatchFetchRule.lfotv, MatchFetchRule.lstv]
    /// 1.10.0: the beIN MENA guide (bein.com via epgshare01), only after the owner approves it; every 12 h (6 when asked).
    static let beinKey = "matchFetch.beinApproved"
    /// 1.10.2 (owner §4): the beIN time check (Qatar time only when the schedules prove it); off = the file's own offset kept.
    static let beinZoneKey = "matchFetch.beinZoneCheck"
    var beinZoneCheck: Bool { d.object(forKey: Self.beinZoneKey) as? Bool ?? true }
    static let bein = "beIN الشرق الأوسط (bein.com عبر epgshare01)"
    var beinApproved: Bool { d.bool(forKey: Self.beinKey) }
    func beinDue(force: Bool) -> Bool {
        beinApproved && Self.now() >= blockedUntil(Self.bein) && Self.now() - lastAttempt(Self.bein) >= (force ? 6 : 12) * 3_600_000
    }
    nonisolated private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func due(_ s: String, force: Bool) -> Bool {
        MatchFetchRule.due(now: Self.now(), lastAttempt: lastAttempt(s), lastSuccess: lastSuccess(s), blockedUntil: blockedUntil(s), force: force)
    }
    func anyDue(force: Bool) -> Bool { !running && (sites.contains { due($0, force: force) } || beinDue(force: force)) }

    func summary() -> String {
        (sites + (beinApproved ? [Self.bein] : [])).map { s in
            let f = { (t: Int64) in t == 0 ? "—" : MatchIndexBuilder.fmt(t) }
            var l = "\(s): آخر محاولة \(f(lastAttempt(s))) · آخر نجاح \(f(lastSuccess(s)))"
            if blockedUntil(s) > Self.now() { l += " · ينتظر طلب الموقع لين \(f(blockedUntil(s)))" }
            if !lastLine(s).isEmpty { l += "\n   " + lastLine(s) }
            return l
        }.joined(separator: "\n")
    }

    private struct Refused: Error { let code: Int; let retryAfter: String? }
    private struct Unexpected: Error {}

    private nonisolated static func get(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        r.setValue("text/html", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Refused(code: code, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")) }
        guard data.count <= 8 * 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A published guide file (.xml or .xml.gz), at most 64 MB.
    private nonisolated static func getData(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u, timeoutInterval: 60)
        r.setValue("Shasha (personal player; guide approved by the user)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Refused(code: code, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")) }
        guard data.count <= 64 * 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    /// gzip → bytes (the deflate stream inside, via Foundation's raw-deflate decoder); plain data is returned as is.
    nonisolated static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return d }
        let flg = b[3]; var i = 10
        if flg & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flg & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flg & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flg & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }

    private func refused(_ s: String, _ e: Refused) -> String {
        let until = MatchFetchRule.waitAfter(code: e.code, retryAfter: e.retryAfter, now: Self.now())
        if until > Self.now() { set(s, "blocked", until) }
        return "رفض الموقع (HTTP \(e.code))" + (until > Self.now() ? " — لن نطلبه قبل \(MatchIndexBuilder.fmt(until))" : "") + " · بقي الجدول السابق كما هو"
    }

    /// Starts a run if one is due and none is going on; a second call joins the running one. True when a schedule changed.
    func run(force: Bool, idx: MatchSourcesRule.LibIndex?) async -> Bool {
        if let job { return await job.value }
        guard anyDue(force: force) else { return false }
        let t = Task { await self.work(force: force, idx: idx) }
        job = t
        let r = await t.value
        job = nil; progress = nil
        return r
    }

    private func work(force: Bool, idx: MatchSourcesRule.LibIndex?) async -> Bool {
        var changed = false
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = Int64(today.timeIntervalSince1970 * 1000)
        let to = Int64((cal.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(172_800)).timeIntervalSince1970 * 1000)
        let kept = Dictionary(MatchSourceFiles.list().map { ($0.source.name, $0.source) }, uniquingKeysWith: { a, _ in a })
        func counts(_ s: MatchSourcesRule.ExtSource) -> String {
            let c = MatchSourcesRule.counts(s, idx: idx)
            return "\(c.entries) إدخال نقل · \(c.unique) قناة فريدة" + (c.inLibrary.map { " · \($0) منها في مكتبتك" } ?? "")
        }
        func keep(_ s: MatchSourcesRule.ExtSource) -> String? {
            switch MatchSourceFiles.store(MatchFetchRule.toJSON(s)) { case .success: changed = true; return nil; case .failure(let f): return f.text }
        }
        // Live-FootballOnTV
        let lf = MatchFetchRule.lfotv
        if due(lf, force: force) {
            set(lf, "attempt", Self.now()); progress = "Live-FootballOnTV: نجلب الصفحة…"
            var line: String
            do {
                let t0 = Date()
                let html = try await Self.get(MatchFetchRule.lfotvURL)
                guard MatchFetchRule.looksLikeLfotv(html) else { throw Unexpected() }
                let at = Self.now()
                var s = await Task.detached { MatchFetchRule.parseLfotv(html, fetchedAt: at, from: from, to: to) }.value
                s.status = "جلب كامل للصفحة"
                if s.matches.isEmpty { line = "الصفحة بلا مباريات لليوم وبكرة — بقي الجدول السابق" }
                else if let e = keep(s) { line = "لم يُحفظ: " + e }
                else {
                    set(lf, "success", Self.now()); set(lf, "full", Self.now())
                    line = "\(s.matches.count) مباراة · \(counts(s)) · \(Int(Date().timeIntervalSince(t0))) ث"
                }
            } catch let e as Refused { line = refused(lf, e) }
            catch is Unexpected { line = "وصلت صفحة غير متوقعة (حماية من الروبوتات أو تغيّر شكلها) — بقي الجدول السابق" }
            catch { line = "تعذّر (\(error.localizedDescription)) — بقي الجدول السابق" }
            d.set(MatchIndexBuilder.fmt(Self.now()) + " · " + line, forKey: k(lf, "line"))
        }
        // LiveSoccerTV
        let ls = MatchFetchRule.lstv
        if due(ls, force: force) {
            set(ls, "attempt", Self.now())
            var line: String
            do {
                let t0 = Date()
                var days: [MatchFetchRule.DayMatch] = []
                var dayFailed = 0
                let urls = MatchFetchRule.lstvDayURLs(today: Date(), days: 2)
                for (i, u) in urls.enumerated() {
                    progress = "LiveSoccerTV: صفحة اليوم \(i + 1)/\(urls.count)…"
                    do {
                        let html = try await Self.get(u)
                        guard MatchFetchRule.looksLikeLstvDay(html) else { throw Unexpected() }
                        days += await Task.detached { MatchFetchRule.parseLstvDay(html) }.value
                    } catch let e as Refused { throw e } catch { dayFailed += 1 }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                guard !days.isEmpty else { throw Unexpected() }
                var seen = Set<String>()
                let inWindow = MatchFetchRule.priority(days.filter { seen.insert($0.id).inserted && $0.kickoff >= from - 3 * 3_600_000 && $0.kickoff < to })
                let toRead = Array(inWindow.prefix(Self.maxMatchPages))
                var pages: [String: MatchFetchRule.MatchPage] = [:]
                var refusal: Refused?
                for (i, m) in toRead.enumerated() {
                    progress = "LiveSoccerTV: قنوات المباريات \(i + 1)/\(toRead.count)" + (inWindow.count > toRead.count ? " (من \(inWindow.count))" : "")
                    do {
                        let html = try await Self.get(m.url)
                        if MatchFetchRule.looksLikeLstvMatch(html) { pages[m.url] = await Task.detached { MatchFetchRule.parseLstvMatch(html) }.value }
                    } catch let e as Refused { refusal = e; break } catch { }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                let notRead = inWindow.filter { pages[$0.url]?.coverage.isEmpty ?? true }
                let lastFull = lastFull(ls) > 0 ? MatchIndexBuilder.fmt(lastFull(ls)) : nil
                let s = MatchFetchRule.mergeLstv(previous: kept[ls], days: inWindow, dayPagesFailed: dayFailed, pages: pages, notRead: notRead,
                                                 fetchedAt: Self.now(), from: from, to: to, lastFull: lastFull)
                if s.matches.isEmpty { line = "بلا مباريات — بقي الجدول السابق" }
                else if let e = keep(s) { line = "لم يُحفظ: " + e }
                else {
                    set(ls, "success", Self.now())
                    if dayFailed == 0 && notRead.isEmpty { set(ls, "full", Self.now()) }
                    let excluded = inWindow.dropFirst(Self.maxMatchPages)
                    line = "\(s.matches.count) مباراة · صفحات التغطية \(pages.count)/\(inWindow.count) · \(counts(s)) · \(Int(Date().timeIntervalSince(t0))) ث"
                    if !excluded.isEmpty {
                        line += " · بعد حد \(Self.maxMatchPages) (الأولوية بالموعد ثم رقم المباراة) بقيت بلا تغطية دولية: "
                            + excluded.map { "\($0.home) × \($0.away) \(MatchIndexBuilder.fmt($0.kickoff))" }.joined(separator: "، ")
                    }
                    line += " · " + (s.status ?? "")
                    if let refusal { line += " · " + refused(ls, refusal) }
                }
            } catch let e as Refused { line = refused(ls, e) }
            catch is Unexpected { line = "وصلت صفحات غير متوقعة (حماية من الروبوتات أو تغيّر شكلها) — بقي الجدول السابق" }
            catch { line = "تعذّر (\(error.localizedDescription)) — بقي الجدول السابق" }
            d.set(MatchIndexBuilder.fmt(Self.now()) + " · " + line, forKey: k(ls, "line"))
        }
        // beIN MENA guide (approved by the owner): one .gz file, its football matches confirm-only
        if beinDue(force: force) {
            let b = Self.bein
            set(b, "attempt", Self.now()); progress = "beIN: نجلب الدليل…"
            var line: String
            do {
                let t0 = Date()
                let raw = try await Self.getData(GuideFeedRule.beinFeed)
                progress = "beIN: نقرأ الدليل…"
                // real kickoffs from the schedules kept now (not other channel guides, not confirm-only pages)
                let sched = MatchSourceFiles.list().map(\.source).filter { !$0.programmeTimes && !$0.confirmOnly }.flatMap(\.matches)
                let zoneOn = beinZoneCheck
                let s = try await Task.detached(priority: .utility) { () throws -> MatchSourcesRule.ExtSource in
                    guard let xml = Self.gunzip(raw) else { throw Unexpected() }
                    let r = GuideFeedRule.read(xml, from: from, to: to)
                    if r.channels.isEmpty { throw Unexpected() }
                    let check = zoneOn ? GuideFeedRule.checkZone(r.progs, schedule: sched) : nil
                    return GuideFeedRule.fromBeinFeed(name: b, url: GuideFeedRule.beinFeed, progs: r.progs, fetchedAt: Self.now(), from: from, to: to, zoneFix: check)
                }.value
                if s.matches.isEmpty { line = "لا مباريات كرة قدم لليوم وبكرة في الدليل · بقي السابق" }
                else if let err = keep(s) { line = "لم يُحفظ: \(err)" }
                else { set(b, "success", Self.now()); line = "\(s.matches.count) مباراة · \(counts(s)) · \(Int(Date().timeIntervalSince(t0))) ث" }
            } catch let e as Refused { line = refused(b, e) }
            catch is Unexpected { line = "ليس دليل XMLTV — بقي السابق" }
            catch { line = "تعذّر (\(error.localizedDescription)) — بقي السابق" }
            d.set(MatchIndexBuilder.fmt(Self.now()) + " · " + line, forKey: k(b, "line"))
        }
        return changed
    }
}
