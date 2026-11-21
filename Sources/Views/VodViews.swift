import SwiftUI

private let grid = [GridItem(.adaptive(minimum: 108), spacing: 12)]
/// 1.0.3: posters are added to the grid page by page while scrolling (a 24,000-item grid made every redraw slow).
private let pageSize = 90

/// Inputs of one list request: when any changes, the old request is cancelled and a new one runs.
struct ListKey: Equatable {
    let query: String, cat: String?, sort: String, mine: Bool, version: Int, groups: Int
}

/// Movies: continue watching, category chips, newest first, search.
struct MoviesView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var cat: String?
    @State private var query = ""
    @AppStorage("sort.movies") private var sort: VodSort = .newest
    @State private var mine = false
    @State private var tick = 0
    /// 1.0.3: the list is computed off the main thread when its inputs change, and shown in pages.
    @State private var items: [Movie] = []
    @State private var shown = pageSize

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                let _ = library.groupsTick
                let ok = library.allowedFilter(.movies)
                let _ = tick
                let cont = continueMovies(library, ok)
                if !cont.isEmpty && query.isEmpty && cat == nil {
                    Text("متابعة المشاهدة").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cont.prefix(20)) { m in
                                NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster, progress: progress("movie:" + m.id)).frame(width: 110) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
                SectionNotice(section: .movies)
                Chips(cats: library.cats(.movies), selected: guarded($cat, .movies, library), locked: lockedSet(.movies, library)).padding(.vertical, 6)
                let _ = tick
                if mine && items.isEmpty { Text("قائمتك فارغة — افتح فيلمًا واضغط ☆ لإضافته.").foregroundStyle(.secondary).padding() }
                // 1.0.4: "no movies" only when the provider really sent an empty list; a failed request says so.
                if !mine && query.isEmpty && cat == nil && library.movies.isEmpty && !library.loading {
                    switch library.moviesState {
                    case .failed(let m):
                        VStack(spacing: 10) {
                            Text("تعذّر جلب الأفلام من المزوّد").font(.headline)
                            Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.borderedProminent)
                        }.padding(.top, 40).padding(.horizontal)
                    case .received:
                        VStack(spacing: 8) {
                            Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                            Text("لا توجد أفلام في هذه القائمة").font(.headline)
                            Text("المزوّد ردّ بقائمة أفلام فارغة. أحيانًا يكون هذا مؤقتًا من المزوّد.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.bordered)
                        }.padding(.top, 40)
                    case .unknown, .emptyReply: EmptyView()
                    }
                }
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(items.prefix(shown)) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster) }.buttonStyle(.plain)
                            .onAppear {
                                Perf.shared.mark("تمرير الأفلام")
                                if m.id == items.prefix(shown).last?.id { shown += pageSize; if shown % (pageSize * 5) == 0 { Perf.shared.memory("تمرير الأفلام: \(shown) بوستر") } }
                            }
                    }
                }.padding(.horizontal)
            }
            .searchable(text: $query, prompt: "بحث في الأفلام")
            .onChange(of: query) { _ in Perf.shared.mark("بحث الأفلام") }
            .task(id: ListKey(query: query, cat: cat, sort: sort.rawValue, mine: mine, version: library.version, groups: library.groupsTick)) {
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }   // typing: wait for a pause
                guard !Task.isCancelled else { return }
                let all = library.movies, ix = library.index, q = query, c = cat, so = sort
                let fav: Set<String>? = mine ? Set(Store.favorites) : nil, blocked = library.blocked(.movies)
                let r = await Task.detached(priority: .userInitiated) { () -> [Movie] in
                    let t0 = Perf.now()
                    let r = ListQuery.movies(all, ix, query: q, cat: c, sort: so, favorites: fav, blocked: blocked)
                    Perf.shared.record("قائمة الأفلام (خلفية)", since: t0, "\(r.count) · بحث \(q.count) حرف · \(c == nil ? "الكل" : "مجموعة") · \(so.rawValue)")
                    return r
                }.value
                guard !Task.isCancelled else { return }       // a newer request owns the screen
                items = r; shown = pageSize
            }
            .navigationTitle(mine ? "قائمتي · الأفلام" : "الأفلام")
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { SortMenu(sort: $sort, mine: $mine) } }
            .refreshable { await library.reload() }
            .onAppear { tick += 1 }
            .onChange(of: play?.id) { _ in tick += 1 }   // back from the player: refresh "Continue watching"
        }
    }
}

/// Sort order + "my list only", shared by Movies and Series.
struct SortMenu: View {
    @Binding var sort: VodSort
    @Binding var mine: Bool
    var body: some View {
        Menu {
            Picker("الترتيب", selection: $sort) {
                ForEach(VodSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle(isOn: $mine) { Label("قائمتي فقط", systemImage: "star") }
        } label: {
            Image(systemName: mine ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

/// Star button that adds/removes a title from "my list".
struct FavButton: View {
    let key: String
    @State private var on = false
    var body: some View {
        Button { Store.toggleFavorite(key); on = Store.isFavorite(key) } label: {
            Image(systemName: on ? "star.fill" : "star").foregroundStyle(Theme.accent)
        }
        .accessibilityLabel(on ? "إزالة من قائمتي" : "إضافة إلى قائمتي")
        .onAppear { on = Store.isFavorite(key) }
    }
}

/// Films with a resume point, most recently played first.
@MainActor func continueMovies(_ library: Library, _ ok: (String) -> Bool) -> [Movie] {
    let byId = Dictionary(library.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return Store.recent.compactMap { key -> Movie? in
        guard key.hasPrefix("movie:"), Store.position(key) != nil, let m = byId[String(key.dropFirst(6))], ok(m.categoryId) else { return nil }
        return m
    }.prefix(20).map { $0 }
}

/// Series with a recently played episode (one entry per series), most recent first.
@MainActor func continueShows(_ library: Library, _ ok: (String) -> Bool) -> [(show: Show, episodeKey: String)] {
    let byId = Dictionary(library.shows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    var out: [(show: Show, episodeKey: String)] = []
    for key in Store.recent where key.hasPrefix("ep:") {
        guard let sid = Store.show(forEpisode: key), let s = byId[sid], ok(s.categoryId), seen.insert(sid).inserted else { continue }
        out.append((s, key))
        if out.count >= 20 { break }
    }
    return out
}

/// Chip selection that asks for Face ID / passcode before opening a locked group.
@MainActor func guarded(_ b: Binding<String?>, _ s: GroupSection, _ library: Library) -> Binding<String?> {
    Binding(get: { b.wrappedValue }, set: { id in
        if let id, library.isLocked(id, s), !library.isUnlocked {
            Task { if await library.unlock() { b.wrappedValue = id } }
        } else { b.wrappedValue = id }
    })
}

@MainActor func lockedSet(_ s: GroupSection, _ library: Library) -> Set<String> {
    Set(library.cats(s).map(\.id).filter { library.isLocked($0, s) && !library.isUnlocked })
}

func progress(_ key: String) -> Double? {
    guard let p = Store.position(key), p.dur > 0 else { return nil }
    return min(1, p.pos / p.dur)
}

struct MovieDetail: View {
    @EnvironmentObject var library: Library
    let movie: Movie
    @Binding var play: PlayItem?

    private var otherMovies: [Movie] { library.copies(of: movie) }
    @State private var info = MovieInfo()
    @StateObject private var tmdb = TmdbLoader()
    @Environment(\.openURL) private var openURL

    private var meta: String {
        let t = tmdb.title
        let year = info.year ?? t?.year.map(String.init)
        let genre = info.genre ?? (t?.genres.isEmpty == false ? t!.genres.prefix(3).joined(separator: "، ") : nil)
        let provider: Double? = movie.rating.flatMap { Double($0) }
        let rating: Double? = (provider ?? 0) > 0 ? provider : (t?.rating ?? 0) > 0 ? t?.rating : nil
        return [year, genre, rating.map { String(format: "★ %.1f", $0) }, info.duration].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(backdrop: tmdb.title?.backdrop ?? info.backdrop, poster: movie.poster ?? tmdb.title?.poster,
                             title: TmdbRule.split(movie.name).title, meta: meta)
                let key = "movie:" + movie.id
                let resume = Store.position(key)
                Button {
                    play = .vod(list: [VodPlay(title: movie.name, url: movie.url, key: key, query: SubQuery.clean(movie.name),
                                                  probe: info.probe, container: movie.ext)], index: 0)
                } label: {
                    VStack(spacing: 2) {
                        Label(resume != nil ? "استكمال" : "تشغيل", systemImage: "play.fill").font(.headline)
                        if let r = resume, r.dur > 0 { Text("من \(Clock.text(r.pos)) من أصل \(Clock.text(r.dur))").font(.caption) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).padding(.horizontal)
                if let t = info.trailerURL {
                    Button { openURL(t) } label: { Label("الإعلان", systemImage: "play.rectangle").frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.bordered).padding(.horizontal)
                }
                if CopyRule.isDolbyVision5(info.probe) {
                    Label("هذه النسخة Dolby Vision 5 بدون طبقة HDR10 (حسب بيانات المزوّد). إذا ظهرت الألوان غريبة جرّب نسخة أخرى.",
                          systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                if let p = info.plot ?? tmdb.title?.overview {
                    VStack(alignment: .leading, spacing: 4) {
                        ExpandableText(text: p)
                        if info.plot == nil { Text("الملخص من TMDB").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.horizontal)
                }
                let copies = otherMovies
                if !copies.isEmpty {
                    Text("نسخ أخرى (\(copies.count))").font(.headline).padding(.horizontal)
                    ForEach(copies) { c in
                        NavigationLink { MovieDetail(movie: c, play: $play) } label: { CopyRow(name: c.name, group: library.vodCats.first { $0.id == c.categoryId }?.name) }
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { FavButton(key: "movie:" + movie.id) } }
        .task {
            if let x = library.xtream { info = await x.movieInfo(movie.id) }
            await tmdb.load(.movie, name: movie.name, providerId: info.tmdbId)
        }
    }
}

/// Series: category chips, recently updated first, search → seasons and episodes.
struct SeriesView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var cat: String?
    @State private var query = ""
    @AppStorage("sort.series") private var sort: VodSort = .newest
    @State private var mine = false
    @State private var tick = 0
    @State private var items: [Show] = []
    @State private var shown = pageSize

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                let _ = library.groupsTick
                let ok = library.allowedFilter(.series)
                let _ = tick
                let cont = continueShows(library, ok)
                if !cont.isEmpty && query.isEmpty && cat == nil {
                    Text("متابعة المشاهدة").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cont, id: \.show.id) { c in
                                NavigationLink { SeriesDetail(show: c.show, play: $play) } label: {
                                    PosterCard(title: c.show.name, poster: c.show.poster, progress: progress(c.episodeKey)).frame(width: 110)
                                }
                                .buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
                SectionNotice(section: .shows)
                Chips(cats: library.cats(.series), selected: guarded($cat, .series, library), locked: lockedSet(.series, library)).padding(.vertical, 6)
                let _ = tick
                if mine && items.isEmpty { Text("قائمتك فارغة — افتح مسلسلًا واضغط ☆ لإضافته.").foregroundStyle(.secondary).padding() }
                if !mine && query.isEmpty && cat == nil && library.shows.isEmpty && !library.loading {
                    switch library.showsState {
                    case .failed(let m):
                        VStack(spacing: 10) {
                            Text("تعذّر جلب المسلسلات من المزوّد").font(.headline)
                            Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.borderedProminent)
                        }.padding(.top, 40).padding(.horizontal)
                    case .received:
                        VStack(spacing: 8) {
                            Image(systemName: "play.rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                            Text("لا توجد مسلسلات في هذه القائمة").font(.headline)
                            Text("المزوّد ردّ بقائمة مسلسلات فارغة. أحيانًا يكون هذا مؤقتًا من المزوّد.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.bordered)
                        }.padding(.top, 40)
                    case .unknown, .emptyReply: EmptyView()
                    }
                }
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(items.prefix(shown)) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster) }.buttonStyle(.plain)
                            .onAppear {
                                Perf.shared.mark("تمرير المسلسلات")
                                if s.id == items.prefix(shown).last?.id { shown += pageSize; if shown % (pageSize * 5) == 0 { Perf.shared.memory("تمرير المسلسلات: \(shown) بوستر") } }
                            }
                    }
                }.padding(.horizontal)
            }
            .searchable(text: $query, prompt: "بحث في المسلسلات")
            .onChange(of: query) { _ in Perf.shared.mark("بحث المسلسلات") }
            .task(id: ListKey(query: query, cat: cat, sort: sort.rawValue, mine: mine, version: library.version, groups: library.groupsTick)) {
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard !Task.isCancelled else { return }
                let all = library.shows, ix = library.index, q = query, c = cat, so = sort
                let fav: Set<String>? = mine ? Set(Store.favorites) : nil, blocked = library.blocked(.series)
                let r = await Task.detached(priority: .userInitiated) { () -> [Show] in
                    let t0 = Perf.now()
                    let r = ListQuery.shows(all, ix, query: q, cat: c, sort: so, favorites: fav, blocked: blocked)
                    Perf.shared.record("قائمة المسلسلات (خلفية)", since: t0, "\(r.count) · بحث \(q.count) حرف · \(c == nil ? "الكل" : "مجموعة") · \(so.rawValue)")
                    return r
                }.value
                guard !Task.isCancelled else { return }
                items = r; shown = pageSize
            }
            .navigationTitle(mine ? "قائمتي · المسلسلات" : "المسلسلات")
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { SortMenu(sort: $sort, mine: $mine) } }
            .refreshable { await library.reload() }
            .onAppear { tick += 1 }
            .onChange(of: play?.id) { _ in tick += 1 }   // back from the player: refresh "Continue watching"
        }
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var library: Library
    let show: Show
    @Binding var play: PlayItem?

    /// The same series in other provider groups (4K / FHD / Arabic-subbed copies…). 1.0.3: from the index.
    private var otherShows: [Show] { library.copies(of: show) }
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loading = true
    @State private var loadError = false
    @State private var copiesOpen = false
    @StateObject private var tmdb = TmdbLoader()

    private var meta: String {
        let t = tmdb.title
        var parts: [String] = []
        if let y = t?.year { parts.append(String(y)) }
        if let g = t?.genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: "، ")) }
        let provider: Double? = show.rating.flatMap { Double($0) }
        let r: Double? = (provider ?? 0) > 0 ? provider : t?.rating
        if let r, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        if !episodes.isEmpty {
            let seasons = Set(episodes.map { $0.season }).count
            parts.append("\(seasons) موسم · \(episodes.count) حلقة")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let t = tmdb.title
                DetailHeader(backdrop: t?.backdrop, poster: show.poster ?? t?.poster, title: TmdbRule.split(show.name).title, meta: meta)
                if let next = nextEpisode {
                    Button { open(next) } label: {
                        VStack(spacing: 2) {
                            Label(Store.position(key(next)) != nil ? "استكمال" : "تشغيل", systemImage: "play.fill").font(.headline)
                            Text("الموسم \(next.season) · الحلقة \(next.number)").font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).padding(.horizontal)
                } else if let first = episodes.first {
                    Button { open(first) } label: { Label("تشغيل الحلقة الأولى", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.borderedProminent).padding(.horizontal)
                }
                if let p = show.plot?.nilIfEmpty ?? t?.overview {
                    VStack(alignment: .leading, spacing: 4) {
                        ExpandableText(text: p)
                        if show.plot?.nilIfEmpty == nil { Text("الملخص من TMDB").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.horizontal)
                }
                if episodes.contains(where: { CopyRule.isDolbyVision5($0.probe) }) {
                    Label("بعض الحلقات Dolby Vision 5 بدون طبقة HDR10 (حسب بيانات المزوّد). إذا ظهرت الألوان غريبة جرّب نسخة أخرى.",
                          systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                let copies = otherShows
                if !copies.isEmpty {
                    DisclosureGroup(isExpanded: $copiesOpen) {
                        ForEach(copies) { c in
                            NavigationLink { SeriesDetail(show: c, play: $play) } label: { CopyRow(name: c.name, group: library.seriesCats.first { $0.id == c.categoryId }?.name) }
                        }
                    } label: { Text("نسخ أخرى (\(copies.count))").font(.headline) }
                    .padding(.horizontal)
                }
                let seasons = Array(Set(episodes.map(\.season))).sorted()
                if seasons.count > 1 {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons, id: \.self) { n in
                                    Button { season = n } label: {
                                        Text("الموسم \(n)").font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(season == n ? Theme.accent : Theme.surface, in: Capsule())
                                            .foregroundStyle(season == n ? Color.black : Color.white)
                                    }.id(n)
                                }
                            }.padding(.horizontal)
                        }
                        .onAppear { proxy.scrollTo(season, anchor: .center) }
                    }
                }
                if loading { ProgressView("جارٍ تحميل الحلقات…").frame(maxWidth: .infinity).padding() }
                else if loadError {
                    VStack(spacing: 10) {
                        Text("تعذّر تحميل الحلقات").font(.headline)
                        Button("إعادة المحاولة") { Task { await loadEpisodes() } }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity).padding()
                } else if episodes.isEmpty {
                    Text("لا توجد حلقات لهذا المسلسل عند المزوّد.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                }
                let current = nextEpisode?.id
                let recent = Set(Store.recent)
                ForEach(episodes.filter { $0.season == season }) { e in
                    Button { open(e) } label: {
                        EpisodeRow(episode: e, showName: show.name, progress: progress(key(e)), current: e.id == current,
                                   watched: Store.position(key(e)) == nil && recent.contains(key(e)))
                    }
                    .buttonStyle(.plain).padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle(TmdbRule.split(show.name).title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { FavButton(key: "show:" + show.id) } }
        .task {
            let t0 = Perf.now()
            Perf.shared.mark("تفاصيل مسلسل")
            Perf.shared.memory("فتح تفاصيل مسلسل")
            await loadEpisodes()
            Perf.shared.untilNextFrame("تفاصيل مسلسل: فتح ← الحلقات معروضة", since: t0, "\(episodes.count) حلقة")
            Perf.shared.mark("تفاصيل مسلسل: عرض الحلقات")
            await tmdb.load(.tv, name: show.name)
        }
    }

    private func loadEpisodes() async {
        guard let x = library.xtream else { loading = false; return }
        loading = true; loadError = false
        do {
            episodes = try await x.episodes(seriesId: show.id)
            season = nextEpisode?.season ?? episodes.first?.season ?? 1
        } catch { loadError = true }
        loading = false
    }

    private func key(_ e: Episode) -> String { "ep:" + e.id }

    /// The episode in progress, else the one after the last started, else the first.
    private var nextEpisode: Episode? {
        if let e = episodes.first(where: { Store.position(key($0)) != nil }) { return e }
        let recent = Set(Store.recent)
        if let last = episodes.lastIndex(where: { recent.contains(key($0)) }), last + 1 < episodes.count { return episodes[last + 1] }
        return nil
    }

    private func open(_ e: Episode) {
        guard let x = library.xtream else { return }
        guard let i = episodes.firstIndex(of: e) else { return }
        let base = SubQuery.clean(show.name).name
        let queue = episodes.map { ep in
            VodPlay(title: "\(show.name) · م\(ep.season) ح\(ep.number)", url: x.episodeURL(ep.id, ep.ext), key: key(ep),
                    query: SubQuery(name: base, season: ep.season, episode: ep.number), season: ep.season, number: ep.number,
                    probe: ep.probe, container: ep.ext)
        }
        Store.remember(episodes: queue.map(\.key), show: show.id)
        play = .vod(list: queue, index: i)
    }
}

/// 1.0.5: the list shown is the saved copy and its refresh wasn't confirmed (request failed, or an empty reply
/// replaced a full list). An empty reply can be right, so it can be confirmed.
struct SectionNotice: View {
    @EnvironmentObject var library: Library
    let section: Library.Section
    @State private var confirming = false

    var body: some View {
        let state = section == .movies ? library.moviesState : library.showsState
        let what = section == .movies ? "الأفلام" : "المسلسلات"
        if state.keepsOldList && !library.loading {
            VStack(alignment: .leading, spacing: 8) {
                Label("المعروض نسخة محفوظة لم يتأكد تحديثها", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
                switch state {
                case .failed(let m): Text("تعذّر جلب \(what): \(m)").font(.footnote).foregroundStyle(.secondary)
                case .emptyReply(let n): Text("ردّ المزوّد بقائمة \(what) فارغة، والنسخة المحفوظة فيها \(n). قد يكون الرد مؤقتًا أو صحيحًا.").font(.footnote).foregroundStyle(.secondary)
                default: EmptyView()
                }
                if let t = library.lastSuccess { Text("آخر تحديث ناجح: \(LastUpdate.text(t))").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.borderedProminent)
                    if case .emptyReply = state {
                        Button("القائمة فعلًا فارغة") { confirming = true }.buttonStyle(.bordered)
                    }
                }.font(.footnote)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
            .confirmationDialog("حذف \(what) المحفوظة من هذه القائمة؟", isPresented: $confirming, titleVisibility: .visible) {
                Button("نعم، القائمة فارغة", role: .destructive) { Task { await library.confirmEmpty(section) } }
            } message: { Text("تقدر ترجعها بأي تحديث ناجح لاحقًا.") }
        }
    }
}
