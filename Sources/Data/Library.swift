import Foundation
import SwiftUI

/// Everything the screens show for the active playlist, plus the saved playlists.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var sources: [Source] = []
    @Published var activeId: UUID?
    @Published private(set) var liveCats: [Category] = []
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var vodCats: [Category] = []
    @Published private(set) var movies: [Movie] = []
    @Published private(set) var seriesCats: [Category] = []
    @Published private(set) var shows: [Show] = []
    @Published private(set) var loading = false
    @Published var error: String?
    /// Bumped when group order / hidden / locked change, so screens refresh.
    @Published private(set) var groupsTick = 0
    /// Locked groups stay open until this time after Face ID / passcode.
    @Published private(set) var unlockedUntil: Date?

    private let key = "sources.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([Source].self, from: d) { sources = s }
        activeId = UUID(uuidString: UserDefaults.standard.string(forKey: "active.v1") ?? "") ?? sources.first?.id
    }

    var active: Source? { sources.first { $0.id == activeId } ?? sources.first }

    var xtream: Xtream? {
        guard let s = active, s.kind == .xtream else { return nil }
        return Xtream(server: s.server, user: s.username, pass: Keychain.get(s.id.uuidString) ?? "")
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: key) }
        UserDefaults.standard.set(activeId?.uuidString, forKey: "active.v1")
    }

    func addXtream(name: String, server: String, user: String, pass: String) async throws {
        let base = Xtream.normalize(server)
        guard URL(string: base) != nil else { throw LoadError.badAddress }
        try await Xtream(server: base, user: user, pass: pass).verify()
        let s = Source(name: name.isEmpty ? (URL(string: base)?.host ?? "Xtream") : name, kind: .xtream, server: base, username: user)
        Keychain.set(pass, for: s.id.uuidString)
        sources.append(s); activeId = s.id; save()
        await reload()
    }

    func addM3U(name: String, url: String) async throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: u)?.scheme?.hasPrefix("http") == true else { throw LoadError.badAddress }
        let s = Source(name: name.isEmpty ? "M3U" : name, kind: .m3u, server: u)
        sources.append(s); activeId = s.id; save()
        await reload()
    }

    func remove(_ s: Source) {
        Keychain.set(nil, for: s.id.uuidString)
        sources.removeAll { $0.id == s.id }
        if activeId == s.id { activeId = sources.first?.id }
        save()
        Task { await reload() }
    }

    func select(_ s: Source) { activeId = s.id; save(); Task { await reload() } }

    /// Reads the whole playlist (lists only; details are read when a title is opened).
    func reload() async {
        guard let s = active else { clear(); return }
        loading = true; error = nil
        let t0 = Perf.now()
        defer {
            loading = false
            let d = sizeText
            Perf.shared.record("تحميل المكتبة كاملة", since: t0, d + (error == nil ? "" : " | فشل"))
            if error == nil { Perf.shared.libraryReadyAfterLaunch(d) }
        }
        do {
            if let x = xtream {
                async let lc = x.categories("get_live_categories")
                async let ch = x.channels()
                async let vc = x.categories("get_vod_categories")
                async let mv = x.movies()
                async let sc = x.categories("get_series_categories")
                async let sh = x.shows()
                liveCats = try await lc; channels = try await ch
                vodCats = (try? await vc) ?? []; movies = (try? await mv) ?? []
                seriesCats = (try? await sc) ?? []; shows = (try? await sh) ?? []
            } else {
                guard let url = URL(string: s.server) else { throw LoadError.badAddress }
                let tn = Perf.now()
                let (data, _) = try await URLSession.shared.data(from: url)
                Perf.shared.record("شبكة M3U", since: tn, ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                let text = String(decoding: data, as: UTF8.self)
                let r = await Task.detached { () -> (cats: [Category], channels: [Channel], movies: [Movie]) in
                    let tp = Perf.now(); let r = M3U.parse(text); Perf.shared.record("تحليل M3U", since: tp); return r
                }.value
                liveCats = r.cats; channels = r.channels; movies = r.movies
                vodCats = r.cats.filter { c in r.movies.contains { $0.categoryId == c.id } }
                seriesCats = []; shows = []
            }
            if channels.isEmpty && movies.isEmpty && shows.isEmpty { throw LoadError.empty }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Library size for the measurements (counts only).
    var sizeText: String {
        "قنوات \(channels.count) · أفلام \(movies.count) · مسلسلات \(shows.count) · مجموعات \(liveCats.count)/\(vodCats.count)/\(seriesCats.count)"
    }

    private func clear() { liveCats = []; channels = []; vodCats = []; movies = []; seriesCats = []; shows = [] }

    // MARK: Groups: order, hide, lock (per playlist, on this phone)

    func providerCats(_ s: GroupSection) -> [Category] {
        switch s { case .live: return liveCats; case .movies: return vodCats; case .series: return seriesCats }
    }

    private func gkey(_ s: GroupSection, _ what: String) -> String { "grp.\(active?.id.uuidString ?? "-").\(s.rawValue).\(what)" }
    private func set(_ s: GroupSection, _ what: String) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: gkey(s, what)) ?? []) }

    func isHidden(_ id: String, _ s: GroupSection) -> Bool { set(s, "hidden").contains(id) }
    func isLocked(_ id: String, _ s: GroupSection) -> Bool { set(s, "locked").contains(id) }
    var hasLocks: Bool { GroupSection.allCases.contains { !set($0, "locked").isEmpty } }
    var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    /// All groups in the viewer's order (hidden ones included) — for the manager.
    func orderedCats(_ s: GroupSection) -> [Category] {
        GroupOrder.arrange(providerCats(s), order: UserDefaults.standard.stringArray(forKey: gkey(s, "order")) ?? [])
    }

    /// Groups shown on the screens: viewer's order, hidden removed.
    func cats(_ s: GroupSection) -> [Category] {
        let h = set(s, "hidden")
        return orderedCats(s).filter { !h.contains($0.id) }
    }

    /// Items of this group may be listed (not hidden; locked only while unlocked).
    func allowed(_ categoryId: String, _ s: GroupSection) -> Bool {
        if set(s, "hidden").contains(categoryId) { return false }
        return isUnlocked || !set(s, "locked").contains(categoryId)
    }

    /// Fast filter for big lists (one read of the settings per call).
    func allowedFilter(_ s: GroupSection) -> (String) -> Bool {
        let blocked = set(s, "hidden").union(isUnlocked ? [] : set(s, "locked"))
        return { !blocked.contains($0) }
    }

    func moveGroups(_ s: GroupSection, from: IndexSet, to: Int) {
        var ids = orderedCats(s).map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        UserDefaults.standard.set(ids, forKey: gkey(s, "order")); groupsTick += 1
    }

    func toggle(_ what: String, _ id: String, _ s: GroupSection) {
        var v = set(s, what)
        if v.contains(id) { v.remove(id) } else { v.insert(id) }
        UserDefaults.standard.set(Array(v), forKey: gkey(s, what)); groupsTick += 1
    }

    func resetGroups(_ s: GroupSection) {
        for w in ["order", "hidden", "locked"] { UserDefaults.standard.removeObject(forKey: gkey(s, w)) }
        groupsTick += 1
    }

    /// Face ID / Touch ID / device passcode — the phone's own lock, no separate PIN to remember.
    func unlock(reason: String = "فتح المجموعات المقفلة") async -> Bool {
        if isUnlocked { return true }
        let ok = await DeviceAuth.check(reason)
        if ok { unlockedUntil = Date().addingTimeInterval(15 * 60); groupsTick += 1 }
        return ok
    }

    func lockNow() { unlockedUntil = nil; groupsTick += 1 }
}

enum GroupSection: String, CaseIterable, Identifiable {
    case live, movies, series
    var id: String { rawValue }
    var title: String {
        switch self { case .live: return "القنوات"; case .movies: return "الأفلام"; case .series: return "المسلسلات" }
    }
}

enum GroupOrder {
    static func arrange(_ cats: [Category], order: [String]) -> [Category] {
        let byId = Dictionary(cats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return GroupOrderRule.arrange(provider: cats.map(\.id), saved: order).compactMap { byId[$0] }
    }
}

/// Now-playing programme per channel, fetched lazily for the rows on screen (Xtream only).
@MainActor
final class EPG: ObservableObject {
    @Published private(set) var now: [String: EPGNow] = [:]
    private var asked: [String: Date] = [:]

    func load(_ ch: Channel, from x: Xtream?) {
        guard let x else { return }
        if let n = now[ch.id], n.end > Date() { return }
        if let a = asked[ch.id], Date().timeIntervalSince(a) < 120 { return }
        asked[ch.id] = Date()
        Task {
            if let r = await x.shortEPG(ch.id) { now[ch.id] = r }
        }
    }

    func clear() { now = [:]; asked = [:] }
}

/// Resume points and favourites (on this phone).
enum Store {
    private static var d: UserDefaults { .standard }

    static func position(_ key: String) -> (pos: Double, dur: Double)? {
        guard let a = d.array(forKey: "pos." + key) as? [Double], a.count == 2, a[0] > 5 else { return nil }
        return (a[0], a[1])
    }

    /// Saved until 95 % watched, then cleared (watched).
    static func setPosition(_ key: String, _ pos: Double, _ dur: Double) {
        if dur > 0 && pos / dur > 0.95 { d.removeObject(forKey: "pos." + key) } else { d.set([pos, dur], forKey: "pos." + key) }
        var recent = d.stringArray(forKey: "recent") ?? []
        recent.removeAll { $0 == key }; recent.insert(key, at: 0)
        d.set(Array(recent.prefix(60)), forKey: "recent")
    }

    static var recent: [String] { d.stringArray(forKey: "recent") ?? [] }

    static func isFavorite(_ id: String) -> Bool { (d.stringArray(forKey: "fav") ?? []).contains(id) }

    static func toggleFavorite(_ id: String) {
        var f = d.stringArray(forKey: "fav") ?? []
        if let i = f.firstIndex(of: id) { f.remove(at: i) } else { f.insert(id, at: 0) }
        d.set(f, forKey: "fav")
    }

    static var favorites: [String] { d.stringArray(forKey: "fav") ?? [] }

    /// Episode key → series id, so "Continue watching" can open the right series.
    static func remember(episodes keys: [String], show: String) {
        var m = d.dictionary(forKey: "epshow") as? [String: String] ?? [:]
        for k in keys { m[k] = show }
        if m.count > 5000 { m = m.filter { Store.recent.contains($0.key) } }
        d.set(m, forKey: "epshow")
    }
    static func show(forEpisode key: String) -> String? { (d.dictionary(forKey: "epshow") as? [String: String])?[key] }
}
