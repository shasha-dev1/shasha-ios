import Foundation

/// 1.8.8: reads Live-FootballOnTV and LiveSoccerTV automatically (owner: personal use, his responsibility). Same limits
/// as the TV's MatchFetch: at most every 6 h (Refresh: every 15 min), one request at a time with a pause, never the paths
/// the sites' robots.txt disallow, a refusal stops that site until next time. Each result is kept as a normal schedule
/// file (same checks and merge as an import; manual links stay). Plain page requests: nothing of the user is sent.
@MainActor
final class MatchFetch {
    static let shared = MatchFetch()
    private let every: TimeInterval = 6 * 3600, minForced: TimeInterval = 15 * 60
    private let maxMatchPages = 80
    private(set) var running = false
    var lastRun: Date? {
        get { UserDefaults.standard.object(forKey: "matchFetch.last") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "matchFetch.last") }
    }
    var lastResult: String {
        get { UserDefaults.standard.string(forKey: "matchFetch.result") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "matchFetch.result") }
    }

    func due(force: Bool = false) -> Bool {
        guard !running else { return false }
        guard let l = lastRun else { return true }
        return Date().timeIntervalSince(l) >= (force ? minForced : every)
    }

    private struct Refused: Error { let code: Int }

    private nonisolated static func get(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        r.setValue("text/html", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Refused(code: code) }
        guard data.count <= 8 * 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads both sites when due (or `force`). Returns true when a schedule was updated.
    func run(force: Bool = false, step: @escaping (String) -> Void = { _ in }) async -> Bool {
        guard due(force: force) else { return false }
        running = true; lastRun = Date()
        defer { running = false }
        var lines: [String] = []
        var changed = false
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = Int64(today.timeIntervalSince1970 * 1000)
        let to = Int64((cal.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(172_800)).timeIntervalSince1970 * 1000)
        func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
        func keep(_ s: MatchSourcesRule.ExtSource) -> String? {
            switch MatchSourceFiles.store(MatchFetchRule.toJSON(s)) {
            case .success: changed = true; return nil
            case .failure(let f): return f.text
            }
        }
        // Live-FootballOnTV
        do {
            step("أجلب Live-FootballOnTV…")
            let t0 = Date()
            let html = try await Self.get(MatchFetchRule.lfotvURL)
            let s = await Task.detached { MatchFetchRule.parseLfotv(html, fetchedAt: Int64(Date().timeIntervalSince1970 * 1000), from: from, to: to) }.value
            if s.matches.isEmpty { lines.append("Live-FootballOnTV: الصفحة وصلت بلا مباريات لليوم وبكرة (تغيّر شكلها؟) — بقي الجدول السابق") }
            else if let e = keep(s) { lines.append("Live-FootballOnTV: لم يُحفظ: " + e) }
            else { lines.append("Live-FootballOnTV: \(s.matches.count) مباراة · \(s.matches.reduce(0) { $0 + $1.channels.count }) قناة · \(Int(Date().timeIntervalSince(t0))) ث") }
        } catch let e as Refused { lines.append("Live-FootballOnTV: رفض الموقع (HTTP \(e.code)) — نحاول في الموعد التالي فقط") }
        catch { lines.append("Live-FootballOnTV: تعذّر (\(error.localizedDescription))") }
        // LiveSoccerTV
        do {
            let t0 = Date()
            var days: [MatchFetchRule.DayMatch] = []
            for u in MatchFetchRule.lstvDayURLs(today: Date(), days: 2) {
                step("أجلب جدول LiveSoccerTV…")
                let html = try await Self.get(u)
                days += await Task.detached { MatchFetchRule.parseLstvDay(html) }.value
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            var seen = Set<String>()
            let inWindow = days.filter { seen.insert($0.id).inserted && $0.kickoff >= from - 3 * 3_600_000 && $0.kickoff < to }.sorted { $0.kickoff < $1.kickoff }
            var pages: [String: MatchFetchRule.MatchPage] = [:]
            var refused: Int?
            for (i, d) in inWindow.prefix(maxMatchPages).enumerated() {
                step("أجلب قنوات المباريات من LiveSoccerTV… \(i + 1)/\(min(inWindow.count, maxMatchPages))")
                do {
                    let html = try await Self.get(d.url)
                    pages[d.url] = await Task.detached { MatchFetchRule.parseLstvMatch(html) }.value
                } catch let e as Refused { refused = e.code; break } catch { }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            let s = MatchFetchRule.lstvSource(inWindow, pages: pages, fetchedAt: now(), from: from, to: to)
            if s.matches.isEmpty { lines.append("LiveSoccerTV: ما وجدنا مباريات في صفحات اليوم (تغيّر شكلها؟) — بقي الجدول السابق") }
            else if let e = keep(s) { lines.append("LiveSoccerTV: لم يُحفظ: " + e) }
            else {
                lines.append("LiveSoccerTV: \(s.matches.count) مباراة · صفحات التغطية الدولية \(pages.count)/\(inWindow.count)"
                             + (inWindow.count > maxMatchPages ? " (أول \(maxMatchPages) بالموعد)" : "")
                             + " · \(s.matches.reduce(0) { $0 + $1.channels.count }) قناة · \(Int(Date().timeIntervalSince(t0))) ث"
                             + (refused.map { " · رفض الموقع (HTTP \($0)) فتوقفنا" } ?? ""))
            }
        } catch let e as Refused { lines.append("LiveSoccerTV: رفض الموقع (HTTP \(e.code)) — نحاول في الموعد التالي فقط") }
        catch { lines.append("LiveSoccerTV: تعذّر (\(error.localizedDescription))") }
        lastResult = MatchIndexBuilder.fmt(now()) + "\n" + lines.joined(separator: "\n")
        return changed
    }
}
