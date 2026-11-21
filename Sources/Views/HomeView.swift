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
    struct Found { var q = ""; var ch: [Channel] = []; var mv: [Movie] = []; var sh: [Show] = [] }

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
                    func pick<T>(_ all: [T], _ names: [String], _ cat: (T) -> String, _ blocked: Set<String>) -> [T] {
                        var out: [T] = []
                        for (i, n) in names.enumerated() where i < all.count && n.contains(f) && !blocked.contains(cat(all[i])) {
                            out.append(all[i]); if out.count == 40 { break }
                        }
                        return out
                    }
                    return Found(q: q, ch: pick(ch, ix.channelSearch, { $0.categoryId }, bl),
                                 mv: pick(mv, ix.movieSearch, { $0.categoryId }, bm),
                                 sh: pick(sh, ix.showSearch, { $0.categoryId }, bs))
                }.value
                guard !Task.isCancelled else { return }
                found = r
                Perf.shared.record("بحث الرئيسية (خلفية)", since: t0, "\(q.count) حرف · \(r.ch.count)/\(r.mv.count)/\(r.sh.count)")
            }
            .onChange(of: play?.id) { _ in tick += 1 }
        }
    }

    // MARK: Shelves

    @ViewBuilder private var shelves: some View {
        let okM = library.allowedFilter(.movies)
        let okS = library.allowedFilter(.series)
        let okL = library.allowedFilter(.live)
        VStack(alignment: .leading, spacing: 22) {
            let cont = Perf.shared.measure("الرئيسية: متابعة المشاهدة") { continueItems(okM, okS) }
            if !cont.isEmpty {
                Shelf(title: "متابعة المشاهدة") {
                    ForEach(cont) { c in
                        NavigationLink { c.destination } label: { PosterCard(title: c.title, poster: c.poster, progress: c.progress).frame(width: 112) }
                            .buttonStyle(.plain)
                    }
                }
            }

            // 1.0.3: favourites looked up by id (was a settings read for each of the 52,989 channels).
            let favCh = Perf.shared.measure("الرئيسية: القنوات المفضلة") {
                Store.favorites.compactMap { id in library.index.channelPos[id].map { library.channels[$0] } }.filter { okL($0.categoryId) }
            }
            if !favCh.isEmpty {
                Shelf(title: "قنواتي المفضلة") {
                    ForEach(Array(favCh.prefix(30).enumerated()), id: \.element.id) { i, ch in
                        Button { play = .live(list: favCh, index: i) } label: {
                            VStack(spacing: 6) {
                                Art(url: ch.logo, fit: true).frame(width: 96, height: 60).padding(6)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                Text(ch.name).font(.caption).lineLimit(1).frame(width: 108)
                                if let n = epg.now[ch.id] { Text(n.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 108) }
                            }
                        }
                        .buttonStyle(.plain)
                        .task { epg.load(ch, from: library.xtream) }
                    }
                }
            }

            let favs = Store.favorites
            let myMovies = Perf.shared.measure("الرئيسية: قائمتي (أفلام)") {
                favs.compactMap { k in k.hasPrefix("movie:") ? library.index.moviePos[String(k.dropFirst(6))].map { library.movies[$0] } : nil }.filter { okM($0.categoryId) }
            }
            let myShows = Perf.shared.measure("الرئيسية: قائمتي (مسلسلات)") {
                favs.compactMap { k in k.hasPrefix("show:") ? library.index.showPos[String(k.dropFirst(5))].map { library.shows[$0] } : nil }.filter { okS($0.categoryId) }
            }
            if !myMovies.isEmpty || !myShows.isEmpty {
                Shelf(title: "قائمتي") {
                    ForEach(myShows.prefix(20)) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                    ForEach(myMovies.prefix(20)) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }

            let newShows: [Show] = Perf.shared.measure("الرئيسية: مسلسلات حديثة") { Array(library.index.showsNewest.lazy.compactMap { $0 < library.shows.count ? library.shows[$0] : nil }.filter { okS($0.categoryId) }.prefix(20)) }
            if !newShows.isEmpty {
                Shelf(title: "مسلسلات حديثة التحديث") {
                    ForEach(newShows) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }

            let newMovies: [Movie] = Perf.shared.measure("الرئيسية: أفلام حديثة") { Array(library.index.moviesNewest.lazy.compactMap { $0 < library.movies.count ? library.movies[$0] : nil }.filter { okM($0.categoryId) }.prefix(20)) }
            if !newMovies.isEmpty {
                Shelf(title: "أفلام أضيفت حديثًا") {
                    ForEach(newMovies) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    struct ContinueItem: Identifiable {
        let id: String
        let title: String
        let poster: String?
        let progress: Double?
        let destination: AnyView
    }

    /// Recently played films (with a resume point) and series (any episode played), newest first.
    private func continueItems(_ okM: (String) -> Bool, _ okS: (String) -> Bool) -> [ContinueItem] {
        let ix = library.index
        var out: [ContinueItem] = []
        var seenShows = Set<String>()
        for key in Store.recent {
            if key.hasPrefix("movie:") {
                guard let mi = ix.moviePos[String(key.dropFirst(6))], mi < library.movies.count, case let m = library.movies[mi], okM(m.categoryId), Store.position(key) != nil else { continue }
                out.append(ContinueItem(id: key, title: m.name, poster: m.poster, progress: progress(key),
                                        destination: AnyView(MovieDetail(movie: m, play: $play))))
            } else if key.hasPrefix("ep:"), let sid = Store.show(forEpisode: key), let si = ix.showPos[sid], si < library.shows.count, case let s = library.shows[si],
                      okS(s.categoryId), seenShows.insert(sid).inserted {
                out.append(ContinueItem(id: "show:" + sid, title: s.name, poster: s.poster, progress: progress(key),
                                        destination: AnyView(SeriesDetail(show: s, play: $play))))
            }
            if out.count >= 20 { break }
        }
        return out
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
                Shelf(title: "مسلسلات (\(sh.count))") {
                    ForEach(sh) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !mv.isEmpty {
                Shelf(title: "أفلام (\(mv.count))") {
                    ForEach(mv) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster).frame(width: 112) }.buttonStyle(.plain)
                    }
                }
            }
            if !ch.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("قنوات (\(ch.count))").font(.title3.bold()).padding(.horizontal)
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
