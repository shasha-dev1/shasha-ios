import SwiftUI

/// Home: one search over everything, then Continue watching, favourite channels, my list and what's new.
struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Binding var play: PlayItem?
    @State private var query = ""
    @State private var tick = 0
    /// 1.0.3: search results computed off the main thread; an older search can't overwrite a newer one.
    @State private var found = Found()
    @StateObject private var tmdbRows = TmdbRows()
    /// 1.2.0: titles paused on another device (Trakt) that are in this library.
    @State private var traktHits: [TraktHit] = []
    struct TraktHit { let id: String; let hit: Library.Hit; let progress: Double; let at: Date }
    @State private var tmdbSheet: TmdbTitle?
    struct Found {
        var q = ""; var ch: [Channel] = []; var mv: [Movie] = []; var sh: [Show] = []
        var totals: (ch: Int, mv: Int, sh: Int) = (0, 0, 0)
    }
    /// «40 من 312» when the list is cut, else the count.
    private func countText(_ shown: Int, _ total: Int) -> String { total > shown ? "\(shown) من \(total)" : "\(shown)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                let _ = (tick, library.groupsTick)
                if query.trimmingCharacters(in: .whitespaces).isEmpty { shelves } else { results }
            }
            .searchable(text: $query, prompt: "ابحث في القنوات والأفلام والمسلسلات")
            .navigationTitle("الرئيسية")
            .refreshable { await library.reload() }
            .onAppear { tick += 1; Perf.shared.firstScreen("الرئيسية") }
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncApplied)) { _ in tick += 1 }
            .task(id: library.version) { await tmdbRows.load(library) }
            .task(id: "\(library.version)|\(TraktStore.pulledAt?.timeIntervalSince1970 ?? 0)|\(tick)") { await loadTraktHits() }
            .sheet(item: $tmdbSheet) { TmdbInfoSheet(title: $0) }
            .onChange(of: query) { _ in Perf.shared.mark("بحث الرئيسية") }
            .task(id: "\(query)|\(library.version)|\(library.groupsTick)") {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { found = Found(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)        // wait for a pause in typing
                guard !Task.isCancelled else { return }
                let ch = library.channels, mv = library.movies, sh = library.shows, ix = library.index
                let bl = library.blocked(.live), bm = library.blocked(.movies), bs = library.blocked(.series)
                let t0 = Perf.now()
                let r = await Task.detached(priority: .userInitiated) { () -> Found in
                    let f = SearchRule.fold(q)
                    // 1.6.0: exact name first, then names starting with the query, then a word starting with it,
                    // then the rest; the total is counted so the screen can say "40 of 312".
                    func pick<T>(_ all: [T], _ names: [String], _ cat: (T) -> String, _ blocked: Set<String>) -> (items: [T], total: Int) {
                        var ranked: [(rank: Int, i: Int)] = []
                        for (i, n) in names.enumerated() where i < all.count && n.contains(f) && !blocked.contains(cat(all[i])) {
                            let r = n == f ? 0 : n.hasPrefix(f) ? 1 : n.contains(" " + f) ? 2 : 3
                            ranked.append((r, i))
                        }
                        let top = ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.i < $1.i }.prefix(40)
                        return (top.map { all[$0.i] }, ranked.count)
                    }
                    let c = pick(ch, ix.channelSearch, { $0.categoryId }, bl)
                    let m = pick(mv, ix.movieSearch, { $0.categoryId }, bm)
                    let s = pick(sh, ix.showSearch, { $0.categoryId }, bs)
                    return Found(q: q, ch: c.items, mv: m.items, sh: s.items, totals: (c.total, m.total, s.total))
                }.value
                guard !Task.isCancelled else { return }
                found = r
                Perf.shared.record("بحث الرئيسية: حتى ظهور النتائج", since: t0, "\(q.count) حرف · \(r.ch.count)/\(r.mv.count)/\(r.sh.count)", span: true)
            }
            .onChange(of: play?.id) { _ in tick += 1 }
        }
    }

    // MARK: Shelves

    // MARK: 1.6.0 Home rows (split out so each part type-checks on its own)

    /// 1.7.0: recently watched channels (newest first), without hidden / locked groups.
    @ViewBuilder private var recentChannelsRow: some View {
        let ok = library.allowedFilter(.live)
        let recent = LiveRecent.ids.compactMap { id in library.index.channelPos[id].flatMap { $0 < library.channels.count ? library.channels[$0] : nil } }
            .filter { ok($0.categoryId) }.prefix(15).map { $0 }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "آخر القنوات")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { i, ch in
                            Button { play = .live(list: recent, index: i) } label: {
                                VStack(spacing: 6) {
                                    Art(url: ch.logo, fit: true).frame(width: 84, height: 52).padding(8)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    Text(ch.name).font(.caption).lineLimit(1).frame(width: 100)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("تشغيل \(ch.name)")
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder private func favoritesSection(_ favCh: [Channel], _ myMovies: [Movie], _ myShows: [Show]) -> some View {
        recentChannelsRow
        if !favCh.isEmpty || !myMovies.isEmpty || !myShows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "المفضلة")
                if !favCh.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(favCh.prefix(30).enumerated()), id: \.element.id) { i, ch in
                                Button { play = .live(list: favCh, index: i) } label: {
                                    VStack(spacing: 6) {
                                        Art(url: ch.logo, fit: true).frame(width: 84, height: 52).padding(8)
                                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                        Text(ch.name).font(.caption).lineLimit(1).frame(width: 100)
                                        if let n = epg.now[ch.id] { Text(n.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 100) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .task { epg.load(ch, from: library.xtream) }
                            }
                        }.padding(.horizontal)
                    }
                }
                if !myMovies.isEmpty || !myShows.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(myShows.prefix(20)) { s in
                                NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                            }
                            ForEach(myMovies.prefix(20)) { m in
                                NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
            }
        }
    }

    @ViewBuilder private func recentSection(_ newMovies: [Movie], _ newShows: [Show]) -> some View {
        if !newMovies.isEmpty || !newShows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "أضيف حديثًا")
                if !newMovies.isEmpty {
                    SubTitle(text: "أفلام")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(newMovies) { m in
                                NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
                if !newShows.isEmpty {
                    SubTitle(text: "مسلسلات حُدّثت")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(newShows) { s in
                                NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
            }
        }
    }

    @ViewBuilder private func discoverSection() -> some View {
        // 1.0.9: TMDB rows, each card marked available / not available.
        if TmdbKey.value != nil {
            ForEach(tmdbRows.rows) { row in
                Shelf(title: row.name) {
                    ForEach(row.items) { it in
                        switch it.hit {
                        case .movie(let m):
                            NavigationLink { MovieDetail(movie: m, play: $play) } label: { TmdbCard(item: it).frame(width: 112) }.buttonStyle(.plain)
                        case .show(let s):
                            NavigationLink { SeriesDetail(show: s, play: $play) } label: { TmdbCard(item: it).frame(width: 112) }.buttonStyle(.plain)
                        case nil:
                            Button { tmdbSheet = it.title } label: { TmdbCard(item: it).frame(width: 112) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if tmdbRows.loading && tmdbRows.rows.isEmpty { ProgressView("جارٍ تحميل الرائج من TMDB…").frame(maxWidth: .infinity) }
            if let e = tmdbRows.error {
                VStack(spacing: 8) {
                    Text("تعذّر تحميل الرائج: \(e)").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("إعادة المحاولة") { Task { await tmdbRows.load(library) } }.font(.footnote).buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.horizontal)
            }
        }
    }

    @ViewBuilder private var shelves: some View {
        let okM = library.allowedFilter(.movies)
        let okS = library.allowedFilter(.series)
        let okL = library.allowedFilter(.live)
        VStack(alignment: .leading, spacing: 26) {
            let cont = Perf.shared.measure("الرئيسية: متابعة المشاهدة") { continueItems(okM, okS) }
            if let hero = cont.first {
                NavigationLink { hero.destination } label: { HeroCard(item: hero) }.buttonStyle(.plain).padding(.horizontal)
                    .contextMenu { if let k = hero.storeKey { ContinueMenu(storeKey: k) { tick += 1 } } }
            }
            if cont.count > 1 {
                Shelf(title: "متابعة المشاهدة") {
                    ForEach(cont.dropFirst()) { c in
                        NavigationLink { c.destination } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                PosterCard(title: c.title, poster: c.poster, progress: c.progress)
                                if !c.detail.isEmpty { Text(c.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(width: 112)
                        }
                            .buttonStyle(.plain)
                            .contextMenu { if let k = c.storeKey { ContinueMenu(storeKey: k) { tick += 1 } } }
                    }
                }
            }

            // 1.0.3: favourites looked up by id (was a settings read for each of the 52,989 channels).
            let favCh = Perf.shared.measure("الرئيسية: القنوات المفضلة") {
                Store.favorites.compactMap { id in library.index.channelPos[id].map { library.channels[$0] } }.filter { okL($0.categoryId) }
            }
            let favs = Store.favorites
            let myMovies = Perf.shared.measure("الرئيسية: قائمتي (أفلام)") {
                favs.compactMap { k in k.hasPrefix("movie:") ? library.index.moviePos[String(k.dropFirst(6))].map { library.movies[$0] } : nil }.filter { okM($0.categoryId) }
            }
            let myShows = Perf.shared.measure("الرئيسية: قائمتي (مسلسلات)") {
                favs.compactMap { k in k.hasPrefix("show:") ? library.index.showPos[String(k.dropFirst(5))].map { library.shows[$0] } : nil }.filter { okS($0.categoryId) }
            }
            let newMovies: [Movie] = Perf.shared.measure("الرئيسية: أفلام حديثة") { Array(library.index.moviesNewest.lazy.compactMap { $0 < library.movies.count ? library.movies[$0] : nil }.filter { okM($0.categoryId) }.prefix(20)) }
            let newShows: [Show] = Perf.shared.measure("الرئيسية: مسلسلات حديثة") { Array(library.index.showsNewest.lazy.compactMap { $0 < library.shows.count ? library.shows[$0] : nil }.filter { okS($0.categoryId) }.prefix(20)) }
            // 1.6.0: rows in the order chosen in Settings → Appearance, hidden ones left out (continue stays first).
            ForEach(HomeRowsPrefs.visible(), id: \.self) { row in
                switch row {
                case .favorites: favoritesSection(favCh, myMovies, myShows)
                case .recent: recentSection(newMovies, newShows)
                case .discover: discoverSection()
                }
            }

            if cont.isEmpty && favCh.isEmpty && myMovies.isEmpty && myShows.isEmpty && newMovies.isEmpty && newShows.isEmpty && library.hasData {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(Theme.accent)
                    Text("ابدأ من القنوات أو الأفلام أو المسلسلات").font(.headline)
                    Text("ما تشاهده وتضيفه للمفضلة يظهر هنا.").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(.vertical, 8)
    }

    struct ContinueItem: Identifiable {
        let id: String
        let title: String
        let poster: String?
        let progress: Double?
        var fromTrakt = false
        let destination: AnyView
        /// 1.6.0: «م2 ح5 · بقي 23 د», the played key (for the long-press menu) and the work key (one card per work).
        var detail = ""
        var storeKey: String? = nil
        var work = ""
    }

    /// Recently played films (with a resume point) and series (any episode played), newest first.
    private func loadTraktHits() async {
        let pauses = TraktStore.pauses
        guard TraktKeys.isLinked, !pauses.isEmpty, library.hasData else { traktHits = []; return }
        let l = await library.lookup()
        traktHits = pauses.compactMap { p in
            let t = TmdbTitle(kind: p.kind == "movie" ? .movie : .tv, tmdbId: p.tmdb ?? 0, name: p.title, originalName: p.title, year: p.year,
                              overview: nil, poster: nil, backdrop: nil, rating: nil)
            guard let h = library.hit(t, l) else { return nil }
            switch h {
            case .movie(let m): return TraktHit(id: "movie:" + m.id, hit: h, progress: p.progress / 100, at: p.pausedAt)
            case .show(let s): return TraktHit(id: "show:" + s.id, hit: h, progress: p.progress / 100, at: p.pausedAt)
            }
        }
    }

    private func continueItems(_ okM: (String) -> Bool, _ okS: (String) -> Bool) -> [ContinueItem] {
        let local = localContinueItems(okM, okS)
        guard !traktHits.isEmpty else { return local.map(\.item) }
        // Merge this phone's history with pauses from other devices, newest first, one entry per work.
        var all = local
        var works = Set(local.map { $0.item.work.isEmpty ? $0.item.id : $0.item.work })
        for h in traktHits {
            switch h.hit {
            case .movie(let m) where okM(m.categoryId):
                let w = WorkRule.key(m.name, kind: "movie")
                guard works.insert(w.isEmpty ? h.id : w).inserted, !Store.isHiddenFromContinue("movie:" + m.id) else { continue }
                all.append((ContinueItem(id: h.id, title: m.name, poster: m.poster, progress: h.progress, fromTrakt: true,
                                         destination: AnyView(MovieDetail(movie: m, play: $play)), work: w), h.at))
            case .show(let s) where okS(s.categoryId):
                let w = WorkRule.key(s.name, kind: "show")
                guard works.insert(w.isEmpty ? h.id : w).inserted else { continue }
                all.append((ContinueItem(id: h.id, title: s.name, poster: s.poster, progress: h.progress, fromTrakt: true,
                                         destination: AnyView(SeriesDetail(show: s, play: $play)), work: w), h.at))
            default: break
            }
        }
        return all.sorted { $0.at > $1.at }.prefix(20).map(\.item)
    }

    /// 1.6.0: the shared list from Library (same as the Movies and Series screens).
    private func localContinueItems(_ okM: (String) -> Bool, _ okS: (String) -> Bool) -> [(item: ContinueItem, at: Date)] {
        library.continueEntries(movies: okM, shows: okS).map { e in
            let dest: AnyView
            switch e.item {
            case .movie(let m): dest = AnyView(MovieDetail(movie: m, play: $play))
            case .show(let s, _): dest = AnyView(SeriesDetail(show: s, play: $play))
            }
            return (ContinueItem(id: e.id, title: e.name, poster: e.poster, progress: progress(e.storeKey), destination: dest,
                                 detail: library.continueDetail(e), storeKey: e.storeKey, work: e.work), e.at)
        }
    }

    // MARK: Search

    @ViewBuilder private var results: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let ch = found.ch, mv = found.mv, sh = found.sh
        VStack(alignment: .leading, spacing: 22) {
            if ch.isEmpty && mv.isEmpty && sh.isEmpty && found.q != q {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)    // first results on their way
            } else if ch.isEmpty && mv.isEmpty && sh.isEmpty {
                Text("لا توجد نتائج لـ «\(q)».").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
            }
            if !sh.isEmpty {
                Shelf(title: "مسلسلات (\(countText(sh.count, found.totals.sh)))") {
                    ForEach(sh) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !mv.isEmpty {
                Shelf(title: "أفلام (\(countText(mv.count, found.totals.mv)))") {
                    ForEach(mv) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !ch.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("قنوات (\(countText(ch.count, found.totals.ch)))").font(.title3.bold()).padding(.horizontal)
                    ForEach(Array(ch.enumerated()), id: \.element.id) { i, c in
                        Button { play = .live(list: ch, index: i) } label: {
                            HStack(spacing: 12) {
                                Art(url: c.logo, fit: true).frame(width: 56, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                Text(c.name).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// The first "continue watching" title, large.
struct HeroCard: View {
    let item: HomeView.ContinueItem
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(url: item.poster, title: item.title).frame(width: 104, height: 156)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.fromTrakt ? "تكملة من جهاز آخر (Trakt)" : "تكملة المشاهدة").font(.caption.weight(.semibold)).foregroundStyle(Theme.teal)
                Text(TmdbRule.split(item.title).title).font(.title3.bold()).lineLimit(3).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
                if !item.detail.isEmpty { Text(item.detail).font(.subheadline).foregroundStyle(.secondary) }
                if let p = item.progress {
                    ProgressView(value: p).tint(Theme.accent)
                    if item.detail.isEmpty { Text("شاهدت \(Int(p * 100))٪").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Label("استكمال", systemImage: "play.fill").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.accent, in: Capsule()).foregroundStyle(.black)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 1.6.0: order and visibility of Home rows (after the continue card and row, which always come first).
enum HomeRow: String, CaseIterable, Identifiable {
    case favorites, recent, discover
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: return "المفضلة والقنوات"
        case .recent: return "أضيف حديثًا"
        case .discover: return "اكتشاف من TMDB"
        }
    }
}

enum HomeRowsPrefs {
    static let orderKey = "home.rows.order", hiddenKey = "home.rows.hidden"
    static func order() -> [HomeRow] {
        let saved = (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(HomeRow.init(rawValue:))
        return saved + HomeRow.allCases.filter { !saved.contains($0) }
    }
    static func hidden() -> Set<HomeRow> { Set((UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []).compactMap(HomeRow.init(rawValue:))) }
    static func visible() -> [HomeRow] { let h = hidden(); return order().filter { !h.contains($0) } }
    static func save(order: [HomeRow], hidden: Set<HomeRow>) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: orderKey)
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: hiddenKey)
    }
}
