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
        sources.append(s); activeId = s.id; save(); clear()
        await reload()
    }

    func addM3U(name: String, url: String) async throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: u)?.scheme?.hasPrefix("http") == true else { throw LoadError.badAddress }
        let s = Source(name: name.isEmpty ? "M3U" : name, kind: .m3u, server: u)
        sources.append(s); activeId = s.id; save(); clear()
        await reload()
    }

    func remove(_ s: Source) {
        Keychain.set(nil, for: s.id.uuidString)
        LibraryCache.remove(s.id)
        sources.removeAll { $0.id == s.id }
        if activeId == s.id { activeId = sources.first?.id; clear() }
        save()
        Task { await start() }
    }

    func select(_ s: Source) {
        guard s.id != dataSource || activeId != s.id else { return }
        activeId = s.id; save(); clear()
        Task { await start() }
    }

    /// 1.0.3: lists, search and copies are read from this index (built off the main thread after each load).
    @Published private(set) var index = LibraryIndex()
    /// Bumped when the lists or the index change, so screens recompute their lists once.
    @Published private(set) var version = 0
    private var reloadTask: Task<Void, Never>?
    private var reloadSource: UUID?
    private var reloadGen = 0

    // MARK: 1.0.4 — saved copy first, refresh in the background

    /// Playlist whose lists are on screen.
    @Published private(set) var dataSource: UUID?
    /// The lists on screen come from the saved copy (the refresh hasn't finished or has failed).
    @Published private(set) var fromCache = false
    /// Time of the last successful download of the active playlist.
    @Published private(set) var lastSuccess: Date?
    /// The background refresh failed while lists are shown (they stay; the full-screen error is only for "nothing at all").
    @Published private(set) var refreshError: String?
    /// Per section: was the list really received? A failed request is never shown as "none".
    /// emptyReply(n): the provider sent an empty list where the saved copy has n titles — the saved list stays,
    /// marked as not confirmed, until the viewer retries or confirms the list is really empty.
    enum SectionState: Equatable {
        case unknown, received, failed(String), emptyReply(Int)
        var keepsOldList: Bool { switch self { case .failed, .emptyReply: return true; default: return false } }
    }
    enum Section { case movies, shows }
    @Published private(set) var moviesState: SectionState = .unknown
    @Published private(set) var showsState: SectionState = .unknown

    private func successKey(_ id: UUID) -> String { "lib.success." + id.uuidString }

    var hasData: Bool { !(channels.isEmpty && movies.isEmpty && shows.isEmpty) }

    /// Launch / playlist change: show the saved copy of this playlist at once, then refresh it in the background.
    func start() async {
        guard let s = active else { clear(); return }
        lastSuccess = UserDefaults.standard.object(forKey: successKey(s.id)) as? Date
        if dataSource != s.id || !hasData {
            let x = xtream, sid = s.id, ckey = LibraryCache.key(for: s)
            let t0 = Perf.now()
            Perf.shared.memory("قبل قراءة المحفوظ")
            // 1.0.5: each part timed inside the background task; the main thread only publishes the result.
            let loaded = await Task.detached(priority: .userInitiated) { () -> (LibraryCache, [Category], [Category], [Category], [Channel], [Movie], [Show], LibraryIndex)? in
                guard let c = LibraryCache.load(for: ckey) else { return nil }
                let tr = Perf.now()
                let r = c.restore(x)
                Perf.shared.record("المحفوظ: تحويل", since: tr)
                let ti = Perf.now()
                let ix = LibraryIndex.build(channels: r.ch, movies: r.mv, shows: r.sh)
                Perf.shared.record("المحفوظ: فهرسة", since: ti)
                return (c, r.lc, r.vc, r.sc, r.ch, r.mv, r.sh, ix)
            }.value
            if let l = loaded, active?.id == sid, !hasData || dataSource != sid {
                Perf.shared.measure("المحفوظ: نشر القوائم على الواجهة", minMs: 0) {
                    liveCats = l.1; vodCats = l.2; seriesCats = l.3; channels = l.4; movies = l.5; shows = l.6
                    index = l.7; version += 1
                    dataSource = sid; fromCache = true
                    moviesState = l.0.moviesReceived ? .received : .unknown
                    showsState = l.0.showsReceived ? .received : .unknown
                }
                Perf.shared.untilNextFrame("المحفوظ: من بدء القراءة حتى الظهور", since: t0, sizeText)
                Perf.shared.libraryReadyAfterLaunch(sizeText, fromCache: true)
                Perf.shared.memory("بعد عرض المحفوظ")
                Perf.shared.memory("بعد عرض المحفوظ بـ 3 ث", after: 3)
            } else {
                Perf.shared.add("المحفوظ: غير موجود أو غير صالح", ms: 0)
            }
        }
        await reload()
    }

    /// Downloads the whole playlist (lists only; details are read when a title is opened). Manual refresh too.
    /// 1.0.3: a second call for the same playlist while it loads joins the running load (no duplicate download);
    /// a call for another playlist cancels the old load, whose results are then dropped.
    func reload() async {
        let sid = active?.id
        if let t = reloadTask, reloadSource == sid { await t.value; return }
        reloadTask?.cancel()
        reloadGen += 1
        let gen = reloadGen
        reloadSource = sid
        let t = Task { await performReload(gen) }
        reloadTask = t
        await t.value
        if reloadGen == gen { reloadTask = nil; reloadSource = nil }
    }

    private func performReload(_ gen: Int) async {
        guard let s = active else { clear(); return }
        loading = true; error = nil; refreshError = nil
        let t0 = Perf.now()
        Perf.shared.memory("قبل التحميل من المزوّد")
        var failedText: String?
        defer {
            if reloadGen == gen {
                loading = false
                let d = sizeText
                Perf.shared.record("تحميل المكتبة من المزوّد", since: t0, d + (failedText.map { " | فشل: " + $0 } ?? ""), span: true)
                if failedText == nil { Perf.shared.libraryReadyAfterLaunch(d) }
            }
        }
        do {
            var lc: [Category] = [], ch: [Channel] = [], vc: [Category] = [], mv: [Movie] = [], sc: [Category] = [], sh: [Show] = []
            var mState: SectionState = .received, sState: SectionState = .received
            func reason(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
            if let x = xtream {
                async let alc = x.categories("get_live_categories")
                async let ach = x.channels()
                async let avc = x.categories("get_vod_categories")
                async let amv = x.movies()
                async let asc = x.categories("get_series_categories")
                async let ash = x.shows()
                lc = try await alc; ch = try await ach
                vc = (try? await avc) ?? []
                do { mv = try await amv } catch { mState = .failed(reason(error)) }
                sc = (try? await asc) ?? []
                do { sh = try await ash } catch { sState = .failed(reason(error)) }
            } else {
                guard let url = URL(string: s.server) else { throw LoadError.badAddress }
                let tn = Perf.now()
                let (data, _) = try await URLSession.shared.data(from: url)
                Perf.shared.record("شبكة M3U", since: tn, ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                let text = String(decoding: data, as: UTF8.self)
                let r = await Task.detached { () -> (cats: [Category], channels: [Channel], movies: [Movie]) in
                    let tp = Perf.now(); let r = M3U.parse(text); Perf.shared.record("تحليل M3U", since: tp); return r
                }.value
                lc = r.cats; ch = r.channels; mv = r.movies
                vc = r.cats.filter { c in r.movies.contains { $0.categoryId == c.id } }
                sState = .received
            }
            Perf.shared.memory("بعد الشبكة والتحليل والتحويل")
            // 1.0.4: an EMPTY list where this playlist had titles is treated as a failed reply, not as "none":
            // on the owner's phone get_vod_streams once answered "[]" in 0.5 s, and 56,207 movies on the next launch.
            let sameSource = dataSource == s.id
            if mState == .received, mv.isEmpty, sameSource, !movies.isEmpty { mState = .emptyReply(movies.count) }
            if sState == .received, sh.isEmpty, sameSource, !shows.isEmpty { sState = .emptyReply(shows.count) }
            // A failed section keeps what the screen already has for it (saved copy), never an empty "none".
            if mState.keepsOldList, sameSource { mv = movies; vc = vodCats }
            if sState.keepsOldList, sameSource { sh = shows; sc = seriesCats }
            if ch.isEmpty && mv.isEmpty && sh.isEmpty { throw LoadError.empty }
            // 1.0.4: timed inside the background task (1.0.3 timed it from the main thread, which labelled it «واجهة»).
            let ix = await Task.detached(priority: .userInitiated) { () -> LibraryIndex in
                let ti = Perf.now()
                let r = LibraryIndex.build(channels: ch, movies: mv, shows: sh)
                Perf.shared.record("فهرسة المكتبة (بحث وترتيب ونسخ)", since: ti)
                return r
            }.value
            // A newer load (other playlist, or cancelled) must not overwrite what it brought.
            guard reloadGen == gen, !Task.isCancelled, active?.id == s.id else { return }
            // One update for all lists (was six separate redraws).
            liveCats = lc; channels = ch; vodCats = vc; movies = mv; seriesCats = sc; shows = sh
            index = ix; version += 1
            dataSource = s.id; fromCache = false
            Perf.shared.memory("بعد الفهرسة ونشر القوائم")
            Perf.shared.memory("مستقرة بعد التحميل بـ 5 ث", after: 5)
            Perf.shared.memory("مستقرة بعد التحميل بـ 20 ث", after: 20)
            moviesState = mState; showsState = sState
            let now = Date()
            lastSuccess = now
            UserDefaults.standard.set(now, forKey: successKey(s.id))

            // Saved only after a good download: the last good copy stays if a later refresh fails.
            let xt = xtream != nil, ckey = LibraryCache.key(for: s)
            let mOK = !mState.keepsOldList, sOK = !sState.keepsOldList
            Task.detached(priority: .utility) {
                let tw = Perf.now()
                let c = LibraryCache(savedAt: now, xtream: xt, liveCats: lc, vodCats: vc, seriesCats: sc,
                                     channels: ch, movies: mv, shows: sh, moviesReceived: mOK, showsReceived: sOK)
                do { try LibraryCache.save(c, for: ckey); Perf.shared.record("حفظ المكتبة على الجهاز", since: tw) }
                catch { Perf.shared.add("حفظ المكتبة على الجهاز: فشل", ms: 0, (error as NSError).domain) }
            }
        } catch {
            guard reloadGen == gen, !Task.isCancelled, active?.id == s.id else { return }
            let m = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failedText = m
            // Lists on screen (saved copy or the previous download) stay; only "nothing at all" is a full-screen error.
            if hasData && dataSource == s.id { refreshError = m } else { self.error = m }
        }
    }

    /// The viewer confirms that an empty reply is right: the section is emptied and the saved copy updated.
    func confirmEmpty(_ section: Section) async {
        guard let sid = dataSource, let src = active, sid == src.id else { return }
        let ckey = LibraryCache.key(for: src)
        if section == .movies { movies = []; vodCats = []; moviesState = .received }
        else { shows = []; seriesCats = []; showsState = .received }
        let ch = channels, mv = movies, sh = shows, lc = liveCats, vc = vodCats, sc = seriesCats, xt = xtream != nil
        let ix = await Task.detached(priority: .userInitiated) { LibraryIndex.build(channels: ch, movies: mv, shows: sh) }.value
        guard dataSource == sid else { return }
        index = ix; version += 1
        let mOK = !moviesState.keepsOldList, sOK = !showsState.keepsOldList
        Task.detached(priority: .utility) {
            let c = LibraryCache(savedAt: Date(), xtream: xt, liveCats: lc, vodCats: vc, seriesCats: sc,
                                 channels: ch, movies: mv, shows: sh, moviesReceived: mOK, showsReceived: sOK)
            try? LibraryCache.save(c, for: ckey)
        }
    }

    /// Categories hidden or locked right now (for list queries off the main thread).
    func blocked(_ s: GroupSection) -> Set<String> {
        set(s, "hidden").union(isUnlocked ? [] : set(s, "locked"))
    }

    /// Other copies of a title (other provider groups), from the index.
    func copies(of show: Show) -> [Show] {
        guard let i = index.showPos[show.id], i < index.showKey.count else { return [] }
        let k = index.showKey[i]
        guard !k.isEmpty else { return [] }
        let b = blocked(.series)
        return (index.showCopies[k] ?? []).compactMap { $0 < shows.count ? shows[$0] : nil }.filter { $0.id != show.id && !b.contains($0.categoryId) }
    }
    func copies(of movie: Movie) -> [Movie] {
        guard let i = index.moviePos[movie.id], i < index.movieKey.count else { return [] }
        let k = index.movieKey[i]
        guard !k.isEmpty else { return [] }
        let b = blocked(.movies)
        return (index.movieCopies[k] ?? []).compactMap { $0 < movies.count ? movies[$0] : nil }.filter { $0.id != movie.id && !b.contains($0.categoryId) }
    }

    /// Library size for the measurements (counts only).
    var sizeText: String {
        "قنوات \(channels.count) · أفلام \(movies.count) · مسلسلات \(shows.count) · مجموعات \(liveCats.count)/\(vodCats.count)/\(seriesCats.count)"
    }

    private func clear() {
        liveCats = []; channels = []; vodCats = []; movies = []; seriesCats = []; shows = []; index = LibraryIndex(); version += 1
        dataSource = nil; fromCache = false; refreshError = nil; error = nil; moviesState = .unknown; showsState = .unknown
    }

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
